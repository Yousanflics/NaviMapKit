//
//  NavMapExampleIdeal.swift
//  NavMapExample
//
//  ❄️ FROZEN IDEAL CODE — the v0 public API acceptance artifact.
//
//  This file is the "few lines of code for a working moving map" the SDK
//  must make real. It was written BEFORE the API existed; the public v0
//  surface is derived FROM this file, not the other way around. Changing
//  this file after freeze requires explicit review confirmation, because
//  every signature here is a v0 API commitment.
//
//  What it exercises (and therefore what v0 must contain — nothing more):
//    - NaviMap view with viewport binding + aviation profile
//    - NavigationBasemap(.operational)
//    - Ownship(source:) fed by an AsyncStream of positions
//    - follow-ownship viewport via EntityID.ownship (no internal types)
//    - viewport persistence: restore-before-GPS, no animation. Flushing is
//      NOT the app's job in the common path: the SDK flushes automatically on
//      didEnterBackground inside a background task. The explicit
//      `flushViewport()` remains public v0 on the handle for apps that need
//      it — deliberately not shown here, and there is no global session
//      singleton (a shape this design explicitly rejects).
//    - OfflineOverlay: locally authoritative GeoJSON content declared by the
//      app with its freshness policy; the app's downloader hands an unpacked
//      generation to `handle.content.stage`, and `activate` validates it and
//      switches rendering only once the new generation is confirmed drawn.
//    - AirspaceVolumes: airspace declared as an ordered collection of
//      navigation volumes. Drawn as footprints with altitude labels on a
//      runtime without volumetric rendering (a reported degradation, never
//      a silent one). A volume with an unknown floor is drawn; one whose
//      effectivity has ended is not; a malformed volume is left out and
//      reported, and the others still render.
//    - TrafficTargets: traffic fed as a stream of whole target sets with the
//      app's own staleness policy (no default: the app states the ages at
//      which a report is shown stale and dropped). A target with an unknown
//      altitude is drawn, labelled as unknown.
//

import NaviAviationMapKit
import SwiftUI

@main
struct NavMapExampleApp: App {
    var body: some Scene {
        WindowGroup {
            NavMapScreen()
        }
    }
}

struct NavMapScreen: View {
    /// The fallback intent: a persisted session replaces it before first
    /// render (`.restore`, without animation, strictly before any default
    /// camera or GPS follow); a `.fit` intent would outrank the session.
    @State private var viewport: NavigationViewport =
        .follow(.ownship, .courseUp)
    @State private var handle = NaviMapHandle()

    private let ownshipFeed = SimulatedOwnshipFeed()
    private let trafficFeed = SimulatedTrafficFeed()
    private let obstacles = BundledObstacleFeed()

    var body: some View {
        NaviMap(
            viewport: $viewport,
            profile: .aviation(.ifr),
            handle: handle
        ) {
            NavigationBasemap(.operational)
            OfflineOverlay(
                .terminalObstacles,
                authority: .localAuthoritative(RefreshPolicy(
                    staleAfter: .seconds(28 * 86_400),
                    expiredAfter: .seconds(56 * 86_400)
                ))
            )
            AirspaceVolumes("terminal-airspace", volumes: BundledAirspace.volumes, appearance: .controlled)
            TrafficTargets(
                "nearby-traffic",
                source: trafficFeed.targets,
                staleness: StalenessPolicy(staleAfter: .seconds(15), dropAfter: .seconds(60))
            )
            Ownship(source: ownshipFeed.positions)
        }
        .task { await obstacles.install(into: handle) }
    }
}

extension ContentID {
    /// Content identities are declared by the application.
    static let terminalObstacles = ContentID("terminal-obstacles")
}

/// Stand-in for the app's real content downloader: a generation directory
/// shipped in the bundle (feature collection plus manifest) is handed to
/// the map exactly as downloaded bytes would be. The SDK never fetches.
struct BundledObstacleFeed {
    func install(into handle: NaviMapHandle) async {
        guard let shipped = Bundle.main.resourceURL?
            .appendingPathComponent("Content", isDirectory: true)
            .appendingPathComponent("terminal-obstacles", isDirectory: true)
        else { return }
        let unpacked = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-obstacles-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: shipped, to: unpacked)
            let staged = try await handle.content.stage(
                .terminalObstacles, generation: GenerationID("2026-09"), directory: unpacked
            )
            try await handle.content.activate(staged)
            // The map may have kept an earlier registration instead of
            // taking this copy; drop the copy if it is still here.
            try? FileManager.default.removeItem(at: unpacked)
        } catch NaviMapContentError.generationAlreadyExists {
            // Installed on an earlier launch: benign, nothing to report.
            try? FileManager.default.removeItem(at: unpacked)
        } catch NaviMapContentError.generationPreviouslyRejected {
            // Rejected on an earlier launch and already reported then; a
            // corrected package would need a new generation identity.
            try? FileManager.default.removeItem(at: unpacked)
        } catch {
            // Rejected or failed: the delegate has received the operational
            // issue where one applies; only the unpacked copy is dropped here.
            try? FileManager.default.removeItem(at: unpacked)
        }
    }
}

/// Stand-in for the app's aeronautical data: two class B shelves around the
/// terminal area, one with an unknown floor; a temporary restriction that
/// ended yesterday, which the map does not draw; and a malformed volume the
/// map leaves out and reports. Airspace data in a real app comes from its
/// own database; the SDK never fetches.
enum BundledAirspace {
    static let volumes: [AirspaceVolume] = [
        AirspaceVolume(address: "tfr-ended", volume: NavigationVolume(
            footprint: .polygon(PolygonGeometry(outer: HorizontalRing([
                HorizontalCoordinate(latitude: 37.80, longitude: -122.45),
                HorizontalCoordinate(latitude: 37.80, longitude: -122.38),
                HorizontalCoordinate(latitude: 37.75, longitude: -122.38),
                HorizontalCoordinate(latitude: 37.75, longitude: -122.45),
            ]))),
            lower: .msl(.init(value: 0, unit: .feet)),
            upper: .msl(.init(value: 5_000, unit: .feet)),
            effectivity: TemporalExtent(validity: .interval(DateInterval(
                start: Date().addingTimeInterval(-2 * 86_400),
                end: Date().addingTimeInterval(-86_400)
            ))),
            mode: .exclusion,
            quality: .authoritative
        )),
        AirspaceVolume(address: "core", volume: NavigationVolume(
            footprint: .polygon(PolygonGeometry(outer: HorizontalRing([
                HorizontalCoordinate(latitude: 37.70, longitude: -122.50),
                HorizontalCoordinate(latitude: 37.70, longitude: -122.27),
                HorizontalCoordinate(latitude: 37.54, longitude: -122.27),
                HorizontalCoordinate(latitude: 37.54, longitude: -122.50),
            ]))),
            lower: .msl(.init(value: 0, unit: .feet)),
            upper: .flightLevel(100),
            effectivity: TemporalExtent(validity: .permanent),
            mode: .exclusion,
            quality: .authoritative
        )),
        AirspaceVolume(address: "shelf-east", volume: NavigationVolume(
            footprint: .polygon(PolygonGeometry(outer: HorizontalRing([
                HorizontalCoordinate(latitude: 37.72, longitude: -122.27),
                HorizontalCoordinate(latitude: 37.72, longitude: -122.05),
                HorizontalCoordinate(latitude: 37.52, longitude: -122.05),
                HorizontalCoordinate(latitude: 37.52, longitude: -122.27),
            ]))),
            lower: .unknown,
            upper: .flightLevel(100),
            effectivity: TemporalExtent(validity: .permanent),
            mode: .exclusion,
            quality: .authoritative
        )),
        // Two vertices enclose no area: left out and reported as a rejected
        // declaration; the two volumes above render regardless.
        AirspaceVolume(address: "malformed", volume: NavigationVolume(
            footprint: .polygon(PolygonGeometry(outer: HorizontalRing([
                HorizontalCoordinate(latitude: 37.60, longitude: -122.60),
                HorizontalCoordinate(latitude: 37.60, longitude: -122.55),
            ]))),
            lower: .msl(.init(value: 0, unit: .feet)),
            upper: .msl(.init(value: 3_000, unit: .feet)),
            effectivity: TemporalExtent(validity: .permanent),
            mode: .exclusion,
            quality: .advisory
        )),
    ]
}

/// Stand-in for the app's traffic receiver: two targets reported once a
/// second as whole sets, one of them with an unknown altitude. Real traffic
/// comes from the app's own receiver; the SDK never fetches.
struct SimulatedTrafficFeed {
    var targets: AsyncStream<[TrafficTarget]> {
        AsyncStream { continuation in
            let task = Task {
                var tick = 0
                while !Task.isCancelled {
                    let now = ObservedAt(instant: Date())
                    let drift = Double(tick) * 0.0004
                    continuation.yield([
                        TrafficTarget(address: "N4521B", entity: MovingEntity(
                            id: EntityID("traffic.N4521B"), kind: .airTraffic,
                            state: KinematicState(
                                position: NavigationPosition(latitude: 37.66 + drift, longitude: -122.30, vertical: .msl(.init(value: 4_500, unit: .feet))),
                                heading: .degreesTrue(10), course: .degreesTrue(12),
                                groundSpeed: .knots(140), verticalRate: .feetPerMinute(0), turnRate: .unknown,
                                observedAt: now
                            )
                        )),
                        TrafficTarget(address: "N88TW", entity: MovingEntity(
                            id: EntityID("traffic.N88TW"), kind: .airTraffic,
                            state: KinematicState(
                                position: NavigationPosition(latitude: 37.58, longitude: -122.42 - drift, vertical: .unknown),
                                heading: .unknown, course: .degreesTrue(250),
                                groundSpeed: .knots(95), verticalRate: .unknown, turnRate: .unknown,
                                observedAt: now
                            )
                        )),
                    ])
                    tick += 1
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Stand-in for the app's real position source: any AsyncStream of
/// NavigationPosition works; the SDK never talks to CoreLocation itself.
struct SimulatedOwnshipFeed {
    var positions: AsyncStream<NavigationPosition> {
        AsyncStream { continuation in
            // Convenience init semantics (frozen with this file): CRS
            // defaults to WGS84 and uncertainty defaults to the explicit
            // `.unknown` case — defaulted, never silently omitted.
            continuation.yield(NavigationPosition(
                latitude: 37.6191,
                longitude: -122.3816,
                vertical: .msl(.init(value: 1200, unit: .feet))
            ))
            continuation.finish()
        }
    }
}
