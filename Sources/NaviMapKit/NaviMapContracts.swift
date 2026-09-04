//
//  NaviMapContracts.swift
//  NaviMapKit
//
//  Public v0 DataSource/Delegate contracts: the typed-event
//  replacement for ad-hoc callback wiring. The handle is opaque — a delegate never reaches the view or
//  any internal. All stale-event protection is structural: the SDK's
//  consuming/emitting tasks are created per attach and die with the epoch
//  binding, so a late event from an old scene cannot be delivered.
//

import NaviMapCore
import NaviMapScene

/// How the viewport last changed — the user-versus-program distinction apps
/// need for "don't fight the user" logic.
public enum ViewportChangeSource: Sendable, Equatable {
    case user
    case program(animated: Bool)
    case restore
}

/// The camera's actual state, as delivered to the delegate. During
/// `.follow`, per-frame camera motion does NOT write back to the viewport
/// binding (the binding is intent); this state output is where the actual
/// camera is observable.
public struct NavigationViewportState: Sendable, Equatable {
    public var camera: CameraPose
    public var source: ViewportChangeSource
    /// Whether a follow intent is currently driving the camera.
    public var isFollowing: Bool

    public init(camera: CameraPose, source: ViewportChangeSource, isFollowing: Bool) {
        self.camera = camera
        self.source = source
        self.isFollowing = isFollowing
    }
}

/// Imperative scene feed — the alternative to the declarative builder
/// (mutually exclusive per map). The app produces immutable
/// snapshots/deltas; both roads meet in the same scene store.
@MainActor
public protocol NaviMapDataSource: AnyObject {
    /// Full desired scene at (re)attach. Also re-requested whenever delta
    /// continuity breaks (self-heal) — must be answerable at any time.
    func initialScene(for map: NaviMapHandle) async throws -> NavigationSceneSnapshot
    /// Incremental changes. Build the stream with `SceneDeltaStream.make`
    /// (bounded buffer); dropped intermediate deltas are recovered by the
    /// self-heal, never accumulated as drift.
    func updates(for map: NaviMapHandle) -> AsyncStream<NavigationSceneDelta>
}

@MainActor
public protocol NaviMapDelegate: AnyObject {
    func map(_ map: NaviMapHandle, didChange viewport: NavigationViewportState)
    func map(_ map: NaviMapHandle, didSelect feature: NavigationFeature)
    func map(_ map: NaviMapHandle, didChange health: OperationalMapHealth)
    func map(_ map: NaviMapHandle, didFail issue: MapOperationalIssue)
}

/// Default empty implementations: delegates opt into the events they need.
public extension NaviMapDelegate {
    func map(_ map: NaviMapHandle, didChange viewport: NavigationViewportState) {}
    func map(_ map: NaviMapHandle, didSelect feature: NavigationFeature) {}
    func map(_ map: NaviMapHandle, didChange health: OperationalMapHealth) {}
    func map(_ map: NaviMapHandle, didFail issue: MapOperationalIssue) {}
}
