//
//  SceneDeltaStream.swift
//  NaviMapScene
//
//  Delta stream factory: the app owns the
//  continuation; the SDK consumes. The factory pre-sets the buffering policy
//  — `.bufferingNewest` — because an unbounded buffer under 60 fps updates
//  is a memory risk. Dropped intermediate deltas are design-intended: the
//  store's revision-continuity check turns any gap into a full-snapshot
//  self-heal, so apps must not rely on every delta being applied.
//
//  Deviation (listed for review): the spec sketched
//  `make(epoch:)`, but deltas carry no epoch field — the epoch binding is
//  enforced where it is real: the store's consuming task is created per
//  attach and dies with the binding, so a stale stream is structurally
//  ignored. A parameter that implied per-value epoch enforcement here would
//  be decorative.
//

import NaviMapCore

public enum SceneDeltaStream {
    /// Returns a delta stream and its producer continuation. One stream per
    /// attach: on scene detach or epoch change the SDK stops consuming
    /// (observable via `continuation.onTermination`) and the next attach
    /// starts over with `initialScene` + a new stream. Yields to a
    /// terminated stream are harmless no-ops.
    public static func make(
        bufferingNewest limit: Int = 64
    ) -> (stream: AsyncStream<NavigationSceneDelta>, continuation: AsyncStream<NavigationSceneDelta>.Continuation) {
        AsyncStream.makeStream(
            of: NavigationSceneDelta.self,
            bufferingPolicy: .bufferingNewest(limit)
        )
    }
}
