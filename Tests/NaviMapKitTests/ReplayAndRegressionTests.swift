//
//  ReplayAndRegressionTests.swift
//  NaviMapKitTests
//
//  Surface-rebuild replay hardening plus the generalized regression suite
//  for three failure classes this architecture exists to make impossible.
//  Phrased as self-contained map scenarios; each pins a concrete failure
//  mode: a definition change that is detected but never re-rendered; a
//  teardown that leaves render artifacts behind; and a stale bookkeeping
//  cache that suppresses re-emission after the surface was rebuilt.
//

import Foundation
import NaviMapCore
@testable import NaviMapKit
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing

@MainActor
struct ReplayAndRegressionTests {
    private func position(_ lat: Double, _ lon: Double) -> NavigationPosition {
        NavigationPosition(latitude: lat, longitude: lon, vertical: .unknown)
    }

    private func drain(until condition: () -> Bool) async throws {
        for _ in 0 ..< 10_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "condition not reached after bounded drain")
    }

    private func makeReadyStore() async throws -> (NaviMapSceneStore, FakeSurfaceDriver) {
        let store = NaviMapSceneStore()
        let driver = FakeSurfaceDriver()
        try await store.attach(driver: driver, host: FakeSurfaceHost())
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { store.reconciler.actual.isSurfaceReady }
        return (store, driver)
    }

    private func settle(_ store: NaviMapSceneStore) async throws {
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
    }

    private func ops(_ driver: FakeSurfaceDriver, after index: Int = 0) -> [RenderOp] {
        driver.appliedPlans.dropFirst(index).flatMap(\.operations)
    }

    // MARK: - Regression class 1: definition change must re-render

    /// Failure mode pinned: an update is DETECTED (signature differs) but
    /// the render state is never rebuilt — the surface keeps showing the
    /// old definition. Here: every definition change must reach the driver
    /// as a fresh upsert carrying the NEW payload.
    @Test func sameIdentityDefinitionChangeReachesTheDriverWithNewPayload() async throws {
        let (store, driver) = try await makeReadyStore()
        let route = [position(37, -122), position(34, -118)]
        store.setComponents([AnySceneComponent(RoutePathComponent(
            positions: route, startLabel: "AAA", endLabel: "BBB"
        ))])
        try await settle(store)
        let planCountAfterMount = driver.appliedPlans.count

        // Same identity, changed definition (a label edit).
        store.setComponents([AnySceneComponent(RoutePathComponent(
            positions: route, startLabel: "AAA", endLabel: "CCC"
        ))])
        try await settle(store)

        let updateOps = ops(driver, after: planCountAfterMount)
        // The new payload must be present — not merely a detected diff.
        #expect(updateOps.contains(.upsertEntityMarker(
            EntityID("navimap.entity.routepath.end"), route[1], label: "CCC"
        )))
        #expect(updateOps.contains(.upsertPath(
            ComponentID("navimap.component.routepath"), route
        )))
    }

    // MARK: - Regression class 2: teardown completeness

    /// Failure mode pinned: removing a component leaves orphaned render
    /// artifacts (markers/paths) on the surface. Here: unmount must emit
    /// removals for EVERY artifact the component ever installed — the line
    /// and both labeled endpoints.
    @Test func unmountRemovesEveryInstalledArtifact() async throws {
        let (store, driver) = try await makeReadyStore()
        let route = [position(37, -122), position(34, -118)]
        store.setComponents([AnySceneComponent(RoutePathComponent(
            positions: route, startLabel: "AAA", endLabel: "BBB"
        ))])
        try await settle(store)
        let planCountBeforeUnmount = driver.appliedPlans.count

        store.setComponents([])
        try await settle(store)

        let removalOps = ops(driver, after: planCountBeforeUnmount)
        #expect(removalOps.contains(.removePath(ComponentID("navimap.component.routepath"))))
        #expect(removalOps.contains(.removeEntityMarker(EntityID("navimap.entity.routepath.start"))))
        #expect(removalOps.contains(.removeEntityMarker(EntityID("navimap.entity.routepath.end"))))
    }

    /// The update-path variant: a definition change that DROPS artifacts
    /// (labels removed) must remove exactly those artifacts while keeping
    /// the component mounted.
    @Test func updateThatDropsArtifactsRemovesExactlyThose() async throws {
        let (store, driver) = try await makeReadyStore()
        let route = [position(37, -122), position(34, -118)]
        store.setComponents([AnySceneComponent(RoutePathComponent(
            positions: route, startLabel: "AAA", endLabel: "BBB"
        ))])
        try await settle(store)
        let planCountBefore = driver.appliedPlans.count

        store.setComponents([AnySceneComponent(RoutePathComponent(positions: route))])
        try await settle(store)

        let afterOps = ops(driver, after: planCountBefore)
        #expect(afterOps.contains(.removeEntityMarker(EntityID("navimap.entity.routepath.start"))))
        #expect(afterOps.contains(.removeEntityMarker(EntityID("navimap.entity.routepath.end"))))
        // The line itself stays: the path re-upserts, no path removal.
        #expect(!afterOps.contains(.removePath(ComponentID("navimap.component.routepath"))))
    }

    // MARK: - Regression class 3: stale bookkeeping across rebuilds

    /// Failure mode pinned: bookkeeping caches surviving a surface rebuild
    /// suppress re-emission ("already installed"), leaving the rebuilt
    /// surface empty. Here: after a rebuild, the FULL artifact set must
    /// re-emit even though the executor's inversion ledger had recorded
    /// everything as installed.
    @Test func rebuildReplaysFullArtifactSetDespitePriorLedgerState() async throws {
        let (store, driver) = try await makeReadyStore()
        let route = [position(37, -122), position(34, -118)]
        store.setComponents([
            AnySceneComponent(BasemapComponent(style: .operational)),
            AnySceneComponent(RoutePathComponent(
                positions: route, startLabel: "AAA", endLabel: "BBB"
            )),
        ])
        try await settle(store)
        let planCountBeforeRebuild = driver.appliedPlans.count

        // Surface rebuild (style reload): actual state zeroed, full replay.
        // Wait on the GENERATION first — settling on revision equality alone
        // returns before the async event task even runs.
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 2))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 2))
        try await drain { store.reconciler.actual.surfaceGeneration == 2 }
        try await settle(store)

        let replayOps = ops(driver, after: planCountBeforeRebuild)
        #expect(replayOps.contains(.setBasemap(.operational)))
        #expect(replayOps.contains(.upsertPath(
            ComponentID("navimap.component.routepath"), route
        )))
        #expect(replayOps.contains(.upsertEntityMarker(
            EntityID("navimap.entity.routepath.start"), route[0], label: "AAA"
        )))
        #expect(replayOps.contains(.upsertEntityMarker(
            EntityID("navimap.entity.routepath.end"), route[1], label: "BBB"
        )))
    }

    /// Consecutive rebuilds each replay in full — no decay of the replay
    /// guarantee across repeated style reloads.
    @Test func consecutiveRebuildsEachReplayInFull() async throws {
        let (store, driver) = try await makeReadyStore()
        let route = [position(37, -122), position(34, -118)]
        store.setComponents([AnySceneComponent(RoutePathComponent(positions: route))])
        try await settle(store)

        for generation: UInt64 in 2 ... 4 {
            let before = driver.appliedPlans.count
            driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: generation))
            driver.emitSurfaceEvent(.becameReady(surfaceGeneration: generation))
            try await drain { store.reconciler.actual.surfaceGeneration == generation }
            try await settle(store)
            #expect(ops(driver, after: before).contains(.upsertPath(
                ComponentID("navimap.component.routepath"), route
            )), "rebuild generation \(generation) did not replay the path")
        }
    }

    /// A rebuild while the timeline cursor is off-realtime replays the
    /// scene evaluated AT that cursor — replay and temporal evaluation
    /// compose rather than conflict.
    @Test func rebuildReplaysAtTheCurrentCursor() async throws {
        let (store, driver) = try await makeReadyStore()
        store.setComponents([AnySceneComponent(RoutePathComponent(
            positions: [position(37, -122), position(34, -118)],
            startLabel: "AAA", endLabel: "BBB"
        ))])
        store.setTimeline(SceneTimeline(cursor: RepresentedTime(
            instant: Date(timeIntervalSince1970: 42)
        )))
        try await settle(store)
        let before = driver.appliedPlans.count

        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 2))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 2))
        try await drain { store.reconciler.actual.surfaceGeneration == 2 }
        try await settle(store)

        // The atemporal route replays unchanged; the applied revision equals
        // the cursor-bearing published revision (replay did not regress the
        // timeline state).
        #expect(ops(driver, after: before).contains(.upsertPath(
            ComponentID("navimap.component.routepath"),
            [position(37, -122), position(34, -118)]
        )))
        #expect(store.reconciler.desired?.timeline.cursor
            == RepresentedTime(instant: Date(timeIntervalSince1970: 42)))
    }
}
