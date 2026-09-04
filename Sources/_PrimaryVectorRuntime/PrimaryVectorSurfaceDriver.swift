//
//  PrimaryVectorSurfaceDriver.swift
//  _PrimaryVectorRuntime
//
//  The Mapbox-backed surface driver — the ONLY code in the repository that
//  touches MapboxMaps, behind an access-level import so no Mapbox type can
//  leak into any public signature.
//
//  Ack semantics: apply returns after the plan's sources/layers
//  are installed in the style AND a render frame has been scheduled — bound
//  to observable Mapbox events, not internal timing guesses.
//

internal import MapboxMaps
import _TileRuntimeBridge
import NaviMapCore
import NaviMapRuntime
import NaviMapScene
import UIKit

/// UIKit host container the SwiftUI/UIKit entry views own. The driver adds
/// its map view as a subview; nothing else ever touches the map view.
@MainActor
package final class PrimaryVectorSurfaceHost: UIView, SurfaceHosting {}

@MainActor
package final class PrimaryVectorSurfaceDriver: MapSurfaceDriving {
    package let manifest = CapabilityManifest(supported: .basePrimitives)

    package var surfaceEvents: AsyncStream<SurfaceEvent> {
        eventStream
    }

    private var eventStream: AsyncStream<SurfaceEvent>
    private var eventContinuation: AsyncStream<SurfaceEvent>.Continuation
    private var mapView: MapView?
    private var attachedEpoch: SceneEpoch?
    private var surfaceGeneration: UInt64 = 0
    private var observers: [AnyCancelable] = []
    /// Pending frame-wait continuations, keyed so detach/timeout can resume
    /// them exactly once (an untracked continuation would make detach hang
    /// a pending apply forever).
    private var pendingFrameWaits: [UUID: CheckedContinuation<FrameWaitOutcome, Never>] = [:]
    /// Pending point-query continuations, same ledger discipline as frame
    /// waits (bounded wait + exactly-once resume via removal-as-claim).
    private var pendingQueryWaits: [UUID: CheckedContinuation<[String], Never>] = [:]
    /// Entity marker state (entity id → point annotation id).
    private var entityAnnotations: [EntityID: String] = [:]
    private var annotationManager: PointAnnotationManager?
    /// Route/track polylines by owning component.
    private var pathAnnotations: [ComponentID: String] = [:]
    private var polylineManager: PolylineAnnotationManager?
    private var areaAnnotations: [AreaID: String] = [:]
    private var polygonManager: PolygonAnnotationManager?

    package init() {
        (eventStream, eventContinuation) = AsyncStream.makeStream(of: SurfaceEvent.self)
    }

    package func attach(to host: any SurfaceHosting, epoch: SceneEpoch) async throws {
        guard let hostView = host as? PrimaryVectorSurfaceHost else {
            throw SurfaceDriverFailure.attachRejected
        }
        // Re-attach replaces the previous surface wholesale.
        await detach()
        (eventStream, eventContinuation) = AsyncStream.makeStream(of: SurfaceEvent.self)

        let view = MapView(frame: hostView.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // The SDK owns ornaments/attribution placement later; defaults
        // are fine for the vertical slice.
        hostView.addSubview(view)
        mapView = view
        attachedEpoch = epoch
        annotationManager = view.annotations.makePointAnnotationManager()
        polylineManager = view.annotations.makePolylineAnnotationManager()
        polygonManager = view.annotations.makePolygonAnnotationManager()

        surfaceGeneration &+= 1
        let generation = surfaceGeneration
        eventContinuation.yield(.loadStarted(surfaceGeneration: generation))

        // MapView starts loading its default
        // style on init, so a bare observeNext could report readiness for the
        // WRONG style. Keep observing and emit becameReady only once the
        // loaded style is the target one.
        let targetStyle = Self.styleURI(for: .operational)
        observers.append(view.mapboxMap.onStyleLoaded.observe { [weak self, weak view] _ in
            guard let self, let view, view.mapboxMap.styleURI == targetStyle else { return }
            eventContinuation.yield(.becameReady(surfaceGeneration: generation))
        })

        view.mapboxMap.styleURI = targetStyle

        // Interaction/camera facts for the viewport layer:
        // any gesture begin breaks follow upstream; idle reports the settled
        // pose with provider zoom mapped back to meters/point.
        view.gestures.delegate = self
        observers.append(view.mapboxMap.onMapIdle.observe { [weak self, weak view] _ in
            guard let self, let view else { return }
            eventContinuation.yield(.cameraIdle(Self.pose(of: view.mapboxMap.cameraState)))
        })
    }

    package func apply(_ plan: RenderPlan) async throws -> ApplyAcknowledgement {
        guard let mapView, let attachedEpoch else {
            throw SurfaceDriverFailure.notAttached
        }
        guard plan.epoch == attachedEpoch else {
            throw SurfaceDriverFailure.applyRejected(plan.revision)
        }

        for operation in plan.operations {
            switch operation {
            case .setBasemap(let style):
                let target = Self.styleURI(for: style)
                if mapView.mapboxMap.styleURI != target {
                    mapView.mapboxMap.styleURI = target
                }
            case .upsertEntityMarker(let entityID, let position, let label):
                upsertMarker(entityID: entityID, position: position, label: label)
            case .removeEntityMarker(let entityID):
                removeMarker(entityID: entityID)
            case .upsertPath(let componentID, let positions):
                upsertPath(componentID: componentID, positions: positions)
            case .removePath(let componentID):
                removePath(componentID: componentID)
            case .upsertArea(let areaID, let geometry, let style):
                upsertArea(areaID: areaID, geometry: geometry, style: style)
            case .removeArea(let areaID):
                removeArea(areaID: areaID)
            case .setContentSource(let contentID, let location):
                do {
                    try bindContentSource(contentID: contentID, location: location)
                } catch {
                    // A binding that did not take effect must not be
                    // acknowledged: the activation rolls back instead of
                    // confirming content that is not on screen.
                    throw SurfaceDriverFailure.applyRejected(plan.revision)
                }
            }
        }

        // Ack after a frame is actually scheduled for the new state: bind to
        // the next rendered-frame event rather than returning optimistically.
        // Bounded wait: detach resumes as .detached, and the
        // 8s ceiling mirrors the offline ack timeout upstream.
        switch await nextRenderedFrame(of: mapView) {
        case .rendered:
            return ApplyAcknowledgement(epoch: plan.epoch, appliedRevision: plan.revision)
        case .detached:
            throw SurfaceDriverFailure.notAttached
        case .timedOut:
            throw SurfaceDriverFailure.acknowledgementTimedOut(plan.revision)
        }
    }

    /// Content bindings in effect for this surface, as provider source and
    /// layer ids. Binding loads the prepared mount through the provider's
    /// asynchronous URL loader (no file is read here); unbinding removes
    /// exactly the layers and source the binding created. A style reload
    /// clears provider state, and the replayed binding plan rebuilds it.
    private var boundContentSources: [ContentID: ContentLayerPlan] = [:]

    private func bindContentSource(contentID: ContentID, location: ContentSourceLocation) throws {
        guard let mapView else { return }
        if let previous = boundContentSources[contentID] {
            removeContentLayers(previous, from: mapView)
            boundContentSources[contentID] = nil
        }
        guard case .prepared(let mount) = location else { return }
        let plan = ContentLayerPlan.plan(for: contentID, mount: mount)
        do {
            var source = GeoJSONSource(id: plan.sourceID)
            source.data = .url(plan.sourceURL)
            try mapView.mapboxMap.addSource(source)
            for layer in plan.layers {
                try mapView.mapboxMap.addLayer(Self.styleLayer(for: layer, source: plan.sourceID))
            }
            boundContentSources[contentID] = plan
        } catch {
            // No partial state survives a failed mount; the caller fails
            // the apply so the activation is rolled back, not confirmed.
            removeContentLayers(plan, from: mapView)
            throw error
        }
    }

    private func removeContentLayers(_ plan: ContentLayerPlan, from mapView: MapView) {
        for layer in plan.layers where mapView.mapboxMap.layerExists(withId: layer.id) {
            try? mapView.mapboxMap.removeLayer(withId: layer.id)
        }
        if mapView.mapboxMap.sourceExists(withId: plan.sourceID) {
            try? mapView.mapboxMap.removeSource(withId: plan.sourceID)
        }
    }

    private static func styleLayer(for layer: ContentLayerPlan.Layer, source: String) -> any Layer {
        let (r, g, b, a) = layer.style.color
        let color = StyleColor(UIColor(red: r, green: g, blue: b, alpha: a))
        switch layer.geometry {
        case .fill:
            var fill = FillLayer(id: layer.id, source: source)
            fill.filter = Exp(.eq) { Exp(.geometryType); "Polygon" }
            fill.fillColor = .constant(color)
            return fill
        case .line:
            var line = LineLayer(id: layer.id, source: source)
            line.filter = Exp(.eq) { Exp(.geometryType); "LineString" }
            line.lineColor = .constant(color)
            line.lineWidth = .constant(layer.style.width)
            return line
        case .circle:
            var circle = CircleLayer(id: layer.id, source: source)
            circle.filter = Exp(.eq) { Exp(.geometryType); "Point" }
            circle.circleColor = .constant(color)
            circle.circleRadius = .constant(layer.style.width)
            return circle
        }
    }

    package func updateCamera(_ pose: CameraPose, animated: Bool) {
        guard let mapView else { return }
        let center = CLLocationCoordinate2D(
            latitude: pose.center.horizontal.latitude,
            longitude: pose.center.horizontal.longitude
        )
        let options = CameraOptions(
            center: center,
            padding: UIEdgeInsets(
                top: pose.padding.top,
                left: pose.padding.leading,
                bottom: pose.padding.bottom,
                right: pose.padding.trailing
            ),
            zoom: Self.zoom(for: pose.scale, atLatitude: center.latitude),
            bearing: pose.bearing.degreesTrue.truncatingRemainder(dividingBy: 360),
            pitch: pose.pitchDegrees
        )
        if animated {
            mapView.camera.ease(to: options, duration: 0.3)
        } else {
            mapView.mapboxMap.setCamera(to: options)
        }
    }

    private static func pose(of camera: CameraState) -> CameraPose {
        CameraPose(
            center: NavigationPosition(
                latitude: camera.center.latitude,
                longitude: camera.center.longitude,
                vertical: .unknown
            ),
            scale: scale(forZoom: camera.zoom, atLatitude: camera.center.latitude),
            bearing: Bearing(degreesTrue: camera.bearing),
            pitchDegrees: Double(camera.pitch),
            padding: ViewportPadding(
                top: camera.padding.top,
                leading: camera.padding.left,
                bottom: camera.padding.bottom,
                trailing: camera.padding.right
            )
        )
    }

    /// Inverse of `zoom(for:atLatitude:)`.
    private static func scale(forZoom zoom: Double, atLatitude latitude: Double) -> MapScale {
        let earthCircumference = 40_075_016.686
        let metersPerPointAtZoom0 = earthCircumference * cos(latitude * .pi / 180) / 512
        return MapScale(metersPerPoint: metersPerPointAtZoom0 / pow(2, zoom))
    }

    /// MapScale (meters/point) → Mapbox zoom at a latitude. Provider zoom
    /// exists only here.
    private static func zoom(for scale: MapScale, atLatitude latitude: Double) -> Double {
        let earthCircumference = 40_075_016.686
        let metersPerPointAtZoom0 = earthCircumference * cos(latitude * .pi / 180) / 512
        return max(0, log2(metersPerPointAtZoom0 / max(scale.metersPerPoint, 0.0001)))
    }

    package func currentCamera() -> CameraPose? {
        guard let mapView else { return nil }
        return Self.pose(of: mapView.mapboxMap.cameraState)
    }

    package func entityHits(at point: ScreenPoint) async -> [EntityID] {
        guard let mapView, let annotationManager else { return [] }
        let queryPoint = CGPoint(x: point.x, y: point.y)
        let options = RenderedQueryOptions(layerIds: [annotationManager.layerId], filter: nil)
        // Identifiers are extracted inside the callback so only Sendable
        // strings cross the continuation (queried features are not Sendable).
        // Bounded wait, same rhythm as the frame waits: the ledger's
        // removal-as-claim gives exactly-once
        // resume across callback/timeout/detach; timeout resolves to no hits.
        let queryID = UUID()
        let identifiers: [String] = await withCheckedContinuation { continuation in
            pendingQueryWaits[queryID] = continuation
            mapView.mapboxMap.queryRenderedFeatures(with: queryPoint, options: options) { [weak self] result in
                let ids = ((try? result.get()) ?? []).compactMap { queried -> String? in
                    guard case .string(let value)? = queried.queriedFeature.feature.identifier
                    else { return nil }
                    return value
                }
                self?.resumeQueryWait(id: queryID, identifiers: ids)
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.resumeQueryWait(id: queryID, identifiers: [])
            }
        }
        // Feature identifiers are the annotation ids we minted at upsert;
        // reverse-map them to entity ids.
        let annotationToEntity = Dictionary(
            uniqueKeysWithValues: entityAnnotations.map { ($0.value, $0.key) }
        )
        var hits: [EntityID] = []
        for identifier in identifiers {
            guard let entityID = annotationToEntity[identifier], !hits.contains(entityID)
            else { continue }
            hits.append(entityID)
        }
        return hits
    }

    package func detach() async {
        // Resume every pending frame wait before tearing the surface down
        // (they are unreachable through `observers`).
        let waits = pendingFrameWaits
        pendingFrameWaits = [:]
        for continuation in waits.values {
            continuation.resume(returning: .detached)
        }
        let queryWaits = pendingQueryWaits
        pendingQueryWaits = [:]
        for continuation in queryWaits.values {
            continuation.resume(returning: [])
        }
        observers.removeAll()
        eventContinuation.finish()
        entityAnnotations.removeAll()
        annotationManager = nil
        pathAnnotations.removeAll()
        polylineManager = nil
        areaAnnotations.removeAll()
        polygonManager = nil
        mapView?.removeFromSuperview()
        mapView = nil
        attachedEpoch = nil
    }

    // MARK: - Internals

    private static func styleURI(for style: BasemapStyle) -> StyleURI {
        switch style {
        case .operational:
            .outdoors
        }
    }

    private func upsertMarker(entityID: EntityID, position: NavigationPosition, label: String?) {
        guard let annotationManager else { return }
        let coordinate = CLLocationCoordinate2D(
            latitude: position.horizontal.latitude,
            longitude: position.horizontal.longitude
        )
        var annotations = annotationManager.annotations
        if let existingID = entityAnnotations[entityID],
           let index = annotations.firstIndex(where: { $0.id == existingID }) {
            annotations[index].point = Point(coordinate)
            annotations[index].textField = label
            annotationManager.annotations = annotations
        } else {
            var annotation = PointAnnotation(point: Point(coordinate))
            if let label {
                // Labeled place marker (v0 runtime-default styling): small
                // dot + haloed text above, legible on light and dark tiles.
                annotation.image = .init(
                    image: Self.endpointMarkerImage(), name: "navimap.entity.marker.labeled"
                )
                annotation.textField = label
                annotation.textOffset = [0, -1.4]
                annotation.textSize = 13
                annotation.textColor = StyleColor(UIColor.label)
                annotation.textHaloColor = StyleColor(UIColor.systemBackground)
                annotation.textHaloWidth = 1.5
            } else {
                annotation.image = .init(
                    image: Self.ownshipMarkerImage(), name: "navimap.entity.marker"
                )
            }
            annotations.append(annotation)
            annotationManager.annotations = annotations
            entityAnnotations[entityID] = annotation.id
        }
    }

    private static func endpointMarkerImage() -> UIImage {
        let size = CGSize(width: 14, height: 14)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemOrange.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
            UIColor.white.setStroke()
            context.cgContext.setLineWidth(1.5)
            context.cgContext.strokeEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2))
        }
    }

    private func upsertPath(componentID: ComponentID, positions: [NavigationPosition]) {
        guard let polylineManager else { return }
        let coordinates = positions.map {
            CLLocationCoordinate2D(
                latitude: $0.horizontal.latitude,
                longitude: $0.horizontal.longitude
            )
        }
        guard coordinates.count >= 2 else {
            removePath(componentID: componentID)
            return
        }
        var annotations = polylineManager.annotations
        if let existingID = pathAnnotations[componentID],
           let index = annotations.firstIndex(where: { $0.id == existingID }) {
            annotations[index].lineString = LineString(coordinates)
            polylineManager.annotations = annotations
        } else {
            // v0 styling is runtime-default (a styling face decides theming later):
            // a readable route blue with white-ish casing via width.
            var annotation = PolylineAnnotation(lineCoordinates: coordinates)
            annotation.lineColor = StyleColor(UIColor.systemBlue)
            annotation.lineWidth = 3
            annotation.lineOpacity = 0.9
            annotations.append(annotation)
            polylineManager.annotations = annotations
            pathAnnotations[componentID] = annotation.id
        }
    }

    private func removePath(componentID: ComponentID) {
        guard let polylineManager, let existingID = pathAnnotations[componentID] else { return }
        polylineManager.annotations = polylineManager.annotations.filter { $0.id != existingID }
        pathAnnotations[componentID] = nil
    }

    private func upsertArea(areaID: AreaID, geometry: PolygonGeometry, style: AreaStyle) {
        guard let polygonManager else { return }
        // A ring that encloses no area is not drawable; the area is removed
        // rather than left as a stale shape.
        guard !geometry.isDegenerate else {
            removeArea(areaID: areaID)
            return
        }
        let polygon = Polygon(
            outerRing: Ring(coordinates: Self.coordinates(of: geometry.outer)),
            innerRings: geometry.holes.map { Ring(coordinates: Self.coordinates(of: $0)) }
        )
        var annotations = polygonManager.annotations
        if let existingID = areaAnnotations[areaID],
           let index = annotations.firstIndex(where: { $0.id == existingID }) {
            annotations[index].polygon = polygon
            Self.applyStyle(style, to: &annotations[index])
            polygonManager.annotations = annotations
        } else {
            var annotation = PolygonAnnotation(polygon: polygon)
            Self.applyStyle(style, to: &annotation)
            annotations.append(annotation)
            polygonManager.annotations = annotations
            areaAnnotations[areaID] = annotation.id
        }
    }

    private func removeArea(areaID: AreaID) {
        guard let polygonManager, let existingID = areaAnnotations[areaID] else { return }
        polygonManager.annotations = polygonManager.annotations.filter { $0.id != existingID }
        areaAnnotations[areaID] = nil
    }

    private static func coordinates(of ring: HorizontalRing) -> [CLLocationCoordinate2D] {
        ring.vertices.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private static func applyStyle(_ style: AreaStyle, to annotation: inout PolygonAnnotation) {
        annotation.fillColor = StyleColor(color(style.fill))
        annotation.fillOpacity = style.fill.alpha
        annotation.fillOutlineColor = StyleColor(color(style.outline))
    }

    private static func color(_ color: RenderColor) -> UIColor {
        UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    private func removeMarker(entityID: EntityID) {
        guard let annotationManager, let existingID = entityAnnotations[entityID] else { return }
        annotationManager.annotations = annotationManager.annotations.filter { $0.id != existingID }
        entityAnnotations[entityID] = nil
    }

    private enum FrameWaitOutcome: Sendable {
        case rendered
        case detached
        case timedOut
    }

    private func nextRenderedFrame(
        of mapView: MapView,
        timeout: Duration = .seconds(8)
    ) async -> FrameWaitOutcome {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            pendingFrameWaits[id] = continuation
            var token: AnyCancelable?
            token = mapView.mapboxMap.onRenderFrameFinished.observeNext { [weak self] _ in
                _ = token // keep the observer alive until it fires
                self?.resumeFrameWait(id: id, outcome: .rendered)
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeFrameWait(id: id, outcome: .timedOut)
            }
        }
    }

    /// Exactly-once resume: removal from the ledger is the claim.
    private func resumeFrameWait(id: UUID, outcome: FrameWaitOutcome) {
        guard let continuation = pendingFrameWaits.removeValue(forKey: id) else { return }
        continuation.resume(returning: outcome)
    }

    private func resumeQueryWait(id: UUID, identifiers: [String]) {
        guard let continuation = pendingQueryWaits.removeValue(forKey: id) else { return }
        continuation.resume(returning: identifiers)
    }

    private static func ownshipMarkerImage() -> UIImage {
        let size = CGSize(width: 24, height: 24)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2))
            UIColor.white.setStroke()
            context.cgContext.setLineWidth(2)
            context.cgContext.strokeEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3))
        }
    }
}

// Gesture types are Provider types (internal import): the conformance stays
// internal, only the emitted SurfaceEvent crosses the boundary.
extension PrimaryVectorSurfaceDriver: @preconcurrency GestureManagerDelegate {
    func gestureManager(
        _ gestureManager: GestureManager, didBegin gestureType: GestureType
    ) {
        eventContinuation.yield(.userInteractionBegan)
    }

    func gestureManager(
        _ gestureManager: GestureManager, didEnd gestureType: GestureType, willAnimate: Bool
    ) {}

    func gestureManager(
        _ gestureManager: GestureManager, didEndAnimatingFor gestureType: GestureType
    ) {}
}
