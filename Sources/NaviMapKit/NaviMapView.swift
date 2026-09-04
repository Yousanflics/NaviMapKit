//
//  NaviMapView.swift
//  NaviMapKit
//
//  Public v0 entry point: the SwiftUI view that turns a
//  declared scene + viewport intent into a live surface. All engine work is
//  delegated to NaviMapSceneStore; this layer owns only SwiftUI/UIKit
//  concerns — hosting, stream pumping, viewport/camera policy, persistence
//  moments, delegate emission. UIKit-gated: the portable graph never
//  compiles this file.
//
//  Scene feed roads: the
//  declarative content builder, or a NaviMapDataSource. Both meet in the
//  same scene store.
//

#if canImport(UIKit) && canImport(SwiftUI)

import NaviMapCore
import NaviMapOffline
import NaviMapRuntime
import NaviMapScene
import SwiftUI
import UIKit

public struct NaviMap: View {
    @Binding private var viewport: NavigationViewport
    private let profile: MapProfile
    private let handle: NaviMapHandle?
    private let elements: [NavigationSceneElement]
    private let dataSource: (any NaviMapDataSource)?

    public init(
        viewport: Binding<NavigationViewport>,
        profile: MapProfile,
        handle: NaviMapHandle? = nil,
        @NavigationSceneBuilder content: () -> [NavigationSceneElement]
    ) {
        _viewport = viewport
        self.profile = profile
        self.handle = handle
        elements = content()
        dataSource = nil
    }

    /// The imperative road: the app supplies snapshots/deltas instead of
    /// declared content. The handle is REQUIRED here — the
    /// DataSource contract is handle-centric (initialScene(for:)/updates(for:)
    /// take it; events and queries flow through it), so the type states it
    /// (a runtime assertion would evaporate in release builds and
    /// leave a silently unrendered map).
    public init(
        viewport: Binding<NavigationViewport>,
        profile: MapProfile,
        handle: NaviMapHandle,
        dataSource: any NaviMapDataSource
    ) {
        _viewport = viewport
        self.profile = profile
        self.handle = handle
        elements = []
        self.dataSource = dataSource
    }

    public var body: some View {
        NaviMapSurface(
            viewport: $viewport,
            profile: profile,
            handle: handle,
            elements: elements,
            dataSource: dataSource
        )
    }
}

// MARK: - Representable

private struct NaviMapSurface: UIViewRepresentable {
    @Binding var viewport: NavigationViewport
    let profile: MapProfile
    let handle: NaviMapHandle?
    let elements: [NavigationSceneElement]
    let dataSource: (any NaviMapDataSource)?

    func makeCoordinator() -> NaviMapCoordinator {
        NaviMapCoordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let hosting = profile.makeHost()
        guard let view = hosting as? UIView else {
            // Fail fast at scene construction: a profile whose
            // host cannot be embedded is a wiring bug, not a runtime state.
            preconditionFailure(
                "MapProfile \(profile.identifier) produced a non-UIView surface host"
            )
        }
        context.coordinator.start(
            profile: profile,
            hosting: hosting,
            hostView: view,
            handle: handle,
            elements: elements,
            dataSource: dataSource,
            viewport: viewport,
            setViewport: { viewport = $0 }
        )
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.viewportChanged(to: viewport)
        context.coordinator.elementsChanged(to: elements)
    }

    static func dismantleUIView(_ view: UIView, coordinator: NaviMapCoordinator) {
        coordinator.stop()
    }
}

// MARK: - Coordinator

@MainActor
final class NaviMapCoordinator: NSObject {
    private let store = NaviMapSceneStore()
    private let sessionStore: ViewportSessionStore
    /// Offline content for this map: created with the coordinator so the
    /// registry is reconciled once per map lifetime, never per attach.
    private let contentPipeline: ContentPipeline
    /// The restore read resolves off the main thread before attach. Until
    /// it has, there is nothing true to persist — a flush would overwrite
    /// the previous session with an empty pose — so flushes are skipped.
    private var restoreResolved = false

    private var handle: NaviMapHandle?
    private var viewport: NavigationViewport = .follow(.ownship, .courseUp)
    /// Writes the SwiftUI binding (intent). Only discrete transitions go
    /// through here — never per-frame follow motion.
    private var setViewportBinding: ((NavigationViewport) -> Void)?
    private var lastChangeSource: ViewportChangeSource = .restore

    /// Static components by id, plus the latest stream-derived components.
    private var staticComponents: [AnySceneComponent] = []
    private var entityComponents: [ComponentID: AnySceneComponent] = [:]
    /// The latest complete group of each streamed collection.
    private var collectionComponents: [String: [AnySceneComponent]] = [:]

    private weak var hostView: UIView?
    /// Deferred fit intent: the size gate holds it until the view has a real
    /// layout; arrival of a new `.fit` binding always replaces it (fit is a
    /// binding intent, recomputed on every arrival).
    private var pendingFit: ViewportFit?

    private var streamTasks: [Task<Void, Never>] = []
    private var attachTask: Task<Void, Never>?
    private var dataSourceTask: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?

    /// Last pose the camera actually held (for session persistence and
    /// course derivation between follow ticks).
    private var lastCameraPose: CameraPose?
    private var lastFollowPosition: NavigationPosition?
    private var lastCourseDegrees: Double?
    /// Latest position per entity — follow ticks that arrive before attach
    /// completes (short/finished streams) replay from here once the driver
    /// can accept camera sets.
    private var lastEntityPositions: [EntityID: NavigationPosition] = [:]

    init(
        sessionStore: ViewportSessionStore = .default,
        contentRootPath: String? = nil,
        contentFileSystem: (any ContentFileSystem)? = nil,
        contentAcknowledgementTimeout: Duration? = nil
    ) {
        self.sessionStore = sessionStore
        contentPipeline = ContentPipeline(
            store: store,
            rootPath: contentRootPath,
            fileSystem: contentFileSystem ?? LocalContentFileSystem(),
            acknowledgementTimeout: contentAcknowledgementTimeout ?? .seconds(8)
        )
        super.init()
    }

    func start(
        profile: MapProfile,
        hosting: any SurfaceHosting,
        hostView: UIView,
        handle: NaviMapHandle?,
        elements: [NavigationSceneElement],
        dataSource: (any NaviMapDataSource)?,
        viewport: NavigationViewport,
        setViewport: @escaping (NavigationViewport) -> Void
    ) {
        self.viewport = viewport
        self.handle = handle
        self.hostView = hostView
        setViewportBinding = setViewport
        handle?.onFlushViewport = { [weak self] in self?.flushViewportSession() }
        handle?.onFeatureQuery = { [weak self] point in
            await self?.queryFeatures(at: point) ?? []
        }
        handle?.content.onStage = { [weak self] contentID, generation, directory in
            guard let self else { throw NaviMapContentError.mapNotAttached }
            return try await contentPipeline.stage(contentID, generation: generation, directory: directory)
        }
        handle?.content.onActivate = { [weak self] staged in
            guard let self else { throw NaviMapContentError.mapNotAttached }
            try await contentPipeline.activate(staged)
        }
        contentPipeline.onIssue = { [weak self] issue in
            guard let self, let handle = self.handle else { return }
            handle.delegate?.map(handle, didFail: issue)
        }
        contentPipeline.onHealthChanged = { [weak self] in self?.emitHealth() }

        store.onSurfaceSignal = { [weak self] signal in
            self?.handleSurfaceSignal(signal)
        }
        store.onDegradationChanged = { [weak self] in self?.emitHealth() }
        store.onDuplicateComponent = { [weak self] componentID in
            guard let self, let handle = self.handle else { return }
            handle.delegate?.map(handle, didFail: .duplicateComponent(componentID))
        }
        store.onUnexpectedFallback = { [weak self] componentID, fallback in
            guard let self, let handle = self.handle else { return }
            handle.delegate?.map(handle, didFail: .unexpectedFallback(component: componentID, fallback))
        }
        store.onDeclarationRejected = { [weak self] componentID, address, defect in
            guard let self, let handle = self.handle else { return }
            handle.delegate?.map(handle, didFail: .declarationRejected(
                component: componentID, address: address, defect
            ))
        }
        store.onCapabilityRefusal = { [weak self] componentID, missing in
            guard let self, let handle = self.handle else { return }
            handle.delegate?.map(handle, didFail: .capabilityIncompatible(
                component: componentID, missing: missing
            ))
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        hostView.addGestureRecognizer(tap)

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushViewportSessionInBackgroundTask() }
        }

        for element in elements {
            switch element.kind {
            case .component(let component):
                staticComponents.append(component)
            case .entityStream(let entityID, let positions, let makeComponent):
                streamTasks.append(Task { [weak self] in
                    for await position in positions {
                        guard !Task.isCancelled else { return }
                        self?.entityPositionChanged(
                            entityID: entityID,
                            position: position,
                            component: makeComponent(position)
                        )
                    }
                })
            case .offlineContent:
                break
            case .collectionStream(let collectionID, let groups):
                streamTasks.append(Task { [weak self] in
                    for await group in groups {
                        guard !Task.isCancelled else { return }
                        self?.collectionChanged(collectionID: collectionID, group: group)
                    }
                })
            }
        }
        contentPipeline.declare(Self.declarations(in: elements))
        contentPipeline.start()

        let driver = profile.makeDriver()
        attachTask = Task { [weak self] in
            guard let self else { return }
            // Restore-before-GPS: the last session is read
            // off the main thread (main-thread I/O contract) and is known
            // BEFORE the surface attaches — so it still precedes readiness,
            // any default camera, and the first follow tick. The binding's
            // initial value is the fallback intent: a persisted free/follow
            // intent replaces it with one discrete `.restore` write-back,
            // while a `.fit` intent outranks restoration (fit wins). A pose
            // the camera already holds is never overwritten.
            let restored = await sessionStore.loadOffMain()
            guard !Task.isCancelled else { return }
            if let restoredPose = restored?.lastCameraPose, lastCameraPose == nil {
                lastCameraPose = restoredPose
            }
            // `self.` on purpose: the closure sees `start`'s parameter too.
            if let restoredIntent = restored?.viewport, restoresIntent(over: self.viewport) {
                self.viewport = restoredIntent
                lastChangeSource = .restore
                setViewportBinding?(restoredIntent)
            }
            restoreResolved = true
            do {
                try await store.attach(driver: driver, host: hosting)
            } catch {
                // Attach failure leaves an inert surface; the failure is
                // observable on the store. v0 has no retry policy.
                return
            }
            applyInitialCamera()
            if let dataSource {
                startDataSourceFeed(dataSource)
            } else {
                pushComponents()
            }
            emitHealth()
        }
    }

    /// The coordinator is single-use: it starts once with the view and stops
    /// once with it. A restart path would have to clear both the entity and
    /// the collection component maps, which this method leaves in place.
    func stop() {
        flushViewportSession()
        streamTasks.forEach { $0.cancel() }
        streamTasks = []
        attachTask?.cancel()
        attachTask = nil
        dataSourceTask?.cancel()
        dataSourceTask = nil
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
            self.backgroundObserver = nil
        }
        handle?.onFlushViewport = nil
        handle?.onFeatureQuery = nil
        handle?.content.onStage = nil
        handle?.content.onActivate = nil
        contentPipeline.stop()
        let store = store
        Task { await store.detach() }
    }

    private static func declarations(in elements: [NavigationSceneElement]) -> [ContentPipeline.Declaration] {
        elements.compactMap { element in
            if case .offlineContent(let contentID, let authority) = element.kind {
                return ContentPipeline.Declaration(contentID: contentID, authority: authority)
            }
            return nil
        }
    }

    // MARK: DataSource road

    private func startDataSourceFeed(_ dataSource: any NaviMapDataSource) {
        // Unreachable-nil by construction: the dataSource init requires a
        // handle at the type level.
        guard let handle else { return }
        dataSourceTask = Task { [weak self] in
            guard let self else { return }
            guard let initial = try? await dataSource.initialScene(for: handle) else { return }
            guard !Task.isCancelled else { return }
            store.applyExternalSnapshot(initial)
            var healedRevision: SceneRevision?
            let updates = dataSource.updates(for: handle)
            for await delta in updates {
                guard !Task.isCancelled else { return }
                // Pre-heal stragglers still buffered in the stream would
                // each trigger another gap→heal round trip (bounded but
                // wasteful ping-pong); anything at or before the healed
                // revision is already superseded by that snapshot.
                if let healedRevision, delta.revision <= healedRevision { continue }
                if !store.applyExternalDelta(delta) {
                    // Revision-chain gap: self-heal with a fresh full
                    // snapshot — drift never accumulates.
                    guard let healed = try? await dataSource.initialScene(for: handle),
                          !Task.isCancelled
                    else { return }
                    healedRevision = healed.revision
                    store.applyExternalSnapshot(healed)
                }
            }
        }
    }

    // MARK: Surface signals → viewport policy + delegate

    private func handleSurfaceSignal(_ signal: SurfaceSignal) {
        switch signal {
        case .becameReady:
            emitHealth()
            attemptPendingFit()
        case .userInteractionBegan:
            breakFollowForUserGesture()
        case .cameraIdle(let pose):
            lastCameraPose = pose
            emitViewportState(camera: pose)
            attemptPendingFit()
        }
    }

    /// A user gesture takes the camera: `.follow` breaks ONCE into
    /// `.free(current pose)` with source `.user` (the
    /// binding expresses intent, so this is a discrete transition, not
    /// per-frame write-back).
    private func breakFollowForUserGesture() {
        lastChangeSource = .user
        guard case .follow = viewport else { return }
        let pose = store.currentCamera() ?? lastCameraPose
        guard let pose else { return }
        viewport = .free(pose)
        setViewportBinding?(viewport)
        emitViewportState(camera: pose)
    }

    private func emitViewportState(camera: CameraPose) {
        guard let handle else { return }
        var isFollowing = false
        if case .follow = viewport { isFollowing = true }
        handle.delegate?.map(handle, didChange: NavigationViewportState(
            camera: camera,
            source: lastChangeSource,
            isFollowing: isFollowing
        ))
    }

    private func emitHealth() {
        guard let handle, let report = store.capabilityReport else { return }
        let surface: SurfaceHealth = switch store.lastFailure {
        case .acknowledgementTimedOut: .degraded(.acknowledgementTimeout)
        default: .running
        }
        handle.delegate?.map(handle, didChange: OperationalMapHealth(
            surface: surface,
            content: contentPipeline.contentHealth,
            capabilities: report
        ))
    }

    // MARK: Selection / query

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let handle, handle.delegate != nil else { return }
        let location = recognizer.location(in: recognizer.view)
        let point = ScreenPoint(x: location.x, y: location.y)
        Task { [weak self] in
            guard let self, let handle = self.handle else { return }
            guard let feature = await queryFeatures(at: point).first else { return }
            handle.delegate?.map(handle, didSelect: feature)
        }
    }

    private func queryFeatures(at point: ScreenPoint) async -> [NavigationFeature] {
        await store.entityHits(at: point).map { NavigationFeature.entity($0) }
    }

    // MARK: Viewport

    func viewportChanged(to next: NavigationViewport) {
        guard next != viewport else { return }
        viewport = next
        switch next {
        case .free(let pose):
            lastChangeSource = .program(animated: true)
            setCamera(pose, animated: true)
        case .follow(let entityID, _):
            // Take effect immediately from the last known position; later
            // ticks keep following.
            lastChangeSource = .program(animated: false)
            if let position = lastEntityPositions[entityID] {
                followTick(entityID: entityID, position: position)
            }
        case .fit(let fit):
            // Every arrival recomputes (binding intent); the size gate only
            // defers, never consumes.
            lastChangeSource = .program(animated: true)
            pendingFit = fit
            attemptPendingFit()
        }
    }

    /// Only free/follow initial intents are fallbacks; `.fit` is an explicit
    /// action for this session and outranks the persisted intent.
    private func restoresIntent(over initial: NavigationViewport) -> Bool {
        if case .fit = initial { return false }
        return true
    }

    private func applyInitialCamera() {
        switch viewport {
        case .free(let pose):
            lastChangeSource = .restore
            setCamera(pose, animated: false)
        case .fit(let fit):
            // Priority rule: restore applies first, without
            // animation; the explicit fit intent then recomputes and takes
            // over — net effect, fit wins. Changing this order is a
            // violation by definition.
            lastChangeSource = .restore
            if let lastCameraPose {
                setCamera(lastCameraPose, animated: false)
            }
            pendingFit = fit
            attemptPendingFit()
        case .follow(let entityID, _):
            // Restored last pose (if any) holds the previous region until
            // the first fix; otherwise the surface's default stands.
            lastChangeSource = .restore
            if let lastCameraPose {
                setCamera(lastCameraPose, animated: false)
            }
            // Replay a fix that arrived before the driver could take camera
            // sets — strictly AFTER the restore, so live position wins.
            if let position = lastEntityPositions[entityID] {
                followTick(entityID: entityID, position: position)
            }
        }
    }

    private func setCamera(_ pose: CameraPose, animated: Bool) {
        lastCameraPose = pose
        store.updateCamera(pose, animated: animated)
    }

    /// The size gate: commit the held fit once the view has a real layout.
    /// Ready/idle surface signals re-trigger the attempt.
    private func attemptPendingFit() {
        guard let fit = pendingFit, let hostView else { return }
        let bounds = hostView.bounds
        guard let pose = ViewportFitSolver.pose(
            for: fit,
            viewWidth: bounds.width,
            viewHeight: bounds.height
        ) else { return }
        pendingFit = nil
        lastChangeSource = .program(animated: true)
        setCamera(pose, animated: true)
        emitViewportState(camera: pose)
    }

    // MARK: Scene updates (declarative road)

    /// Declared content is live: a re-evaluated body (e.g. a route that
    /// resolved late) re-declares components and the reconciler diffs them.
    /// v0 rule: STATIC components update across body evaluations; entity
    /// STREAMS stay bound to the streams captured at creation (re-binding
    /// per body evaluation would double-subscribe — a stream identity story
    /// is deferred).
    func elementsChanged(to elements: [NavigationSceneElement]) {
        let next = elements.compactMap { element -> AnySceneComponent? in
            if case .component(let component) = element.kind { return component }
            return nil
        }
        contentPipeline.declare(Self.declarations(in: elements))
        guard next != staticComponents else { return }
        staticComponents = next
        pushComponents()
    }

    private func entityPositionChanged(
        entityID: EntityID,
        position: NavigationPosition,
        component: AnySceneComponent
    ) {
        entityComponents[component.componentID] = component
        lastEntityPositions[entityID] = position
        pushComponents()
        followTick(entityID: entityID, position: position)
    }

    /// Replaces the collection's whole group; members absent from the new
    /// group leave the desired scene and are unmounted by the reconciler.
    private func collectionChanged(collectionID: String, group: [AnySceneComponent]) {
        collectionComponents[collectionID] = group
        pushComponents()
    }

    private func pushComponents() {
        let entities = entityComponents.values
            .sorted { $0.componentID.rawValue < $1.componentID.rawValue }
        let collections = collectionComponents
            .sorted { $0.key < $1.key }
            .flatMap(\.value)
        store.setComponents(staticComponents + entities + collections)
    }

    private func followTick(entityID: EntityID, position: NavigationPosition) {
        guard case .follow(let followed, let configuration) = viewport,
              followed == entityID
        else {
            if case .follow = viewport {} else { lastFollowPosition = nil }
            return
        }

        let bearing: Bearing
        switch configuration.orientation {
        case .northUp:
            bearing = .north
        case .courseUp:
            if let previous = lastFollowPosition,
               let course = Self.courseDegrees(
                   from: previous.horizontal, to: position.horizontal
               ) {
                lastCourseDegrees = course
            }
            bearing = Bearing(degreesTrue: lastCourseDegrees ?? 0)
        }
        lastFollowPosition = position

        // Follow ticks are hard camera sets: animating toward a moving
        // target lags it; smoothing is the position source's concern.
        setCamera(
            CameraPose(center: position, scale: configuration.scale, bearing: bearing),
            animated: false
        )
    }

    /// Great-circle initial course; nil when the points coincide (no motion,
    /// no course — keep the last known one rather than snapping north).
    private static func courseDegrees(
        from a: HorizontalCoordinate, to b: HorizontalCoordinate
    ) -> Double? {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        guard abs(y) > 1e-12 || abs(x) > 1e-12 else { return nil }
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    // MARK: Persistence moments

    /// Nil until the restore read has resolved (see `restoreResolved`).
    private func sessionToPersist() -> ViewportSession? {
        guard restoreResolved else { return nil }
        return ViewportSession(viewport: viewport, lastCameraPose: lastCameraPose)
    }

    /// Enqueued on the session store's serial I/O queue; the main thread
    /// never performs the write.
    private func flushViewportSession() {
        guard let session = sessionToPersist() else { return }
        sessionStore.scheduleSave(session)
    }

    /// The automatic flush: inside a background task so the
    /// atomic write completes even when the app is being suspended. The
    /// lease ends only after the off-main write has finished.
    private func flushViewportSessionInBackgroundTask() {
        guard let session = sessionToPersist() else { return }
        let lease = BackgroundTaskLease()
        let sessionStore = sessionStore
        Task {
            await sessionStore.saveOffMain(session)
            lease.end()
        }
    }
}

/// One `beginBackgroundTask` lease that ends exactly once — on completion
/// or on system expiry, whichever comes first.
@MainActor
private final class BackgroundTaskLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

#endif
