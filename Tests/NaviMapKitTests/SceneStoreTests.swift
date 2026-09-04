//
//  SceneStoreTests.swift
//  NaviMapKitTests
//
//  The store's two core invariants: revision
//  monotonicity is owned and provable HERE, and the SceneEpoch ↔ driver
//  surfaceGeneration binding is exercised end-to-end against the fake driver
//  — including the stale-binding rejection paths.
//

import NaviMapCore
import NaviMapKit
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing

@MainActor
struct SceneStoreTests {
    private func makeComponent(_ id: String, _ signature: String) -> AnySceneComponent {
        AnySceneComponent(
            componentID: ComponentID(id),
            definitionSignature: DefinitionSignature(signature)
        )
    }

    /// Deterministic wait: the store's event/pump tasks run on the main
    /// actor, so yielding drains them; the bound is a hang backstop only.
    private func drain(until condition: () -> Bool) async throws {
        for _ in 0 ..< 10_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "condition not reached after bounded drain")
    }

    private func makeReadyStore(
        script: [FakeSurfaceDriver.ScriptStep] = []
    ) async throws -> (NaviMapSceneStore, FakeSurfaceDriver) {
        let store = NaviMapSceneStore()
        let driver = FakeSurfaceDriver(script: script)
        try await store.attach(driver: driver, host: FakeSurfaceHost())
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { store.reconciler.actual.isSurfaceReady }
        return (store, driver)
    }

    // MARK: Revision monotonicity ownership

    @Test func revisionsAreStrictlyMonotonicAcrossUpdates() async throws {
        let (store, _) = try await makeReadyStore()
        var seen: [SceneRevision] = []
        for index in 0 ..< 5 {
            store.setComponents([makeComponent("a", "s\(index)")])
            try seen.append(#require(store.lastPublishedRevision))
        }
        #expect(seen == seen.sorted())
        #expect(Set(seen).count == seen.count)
    }

    @Test func revisionsDoNotResetAcrossReattach() async throws {
        let store = NaviMapSceneStore()
        let firstDriver = FakeSurfaceDriver()
        try await store.attach(driver: firstDriver, host: FakeSurfaceHost())
        store.setComponents([makeComponent("a", "s1")])
        let beforeReattach = try #require(store.lastPublishedRevision)

        // Re-attach mints a NEW epoch but revisions keep counting: "newer
        // revision" stays a total order for the store's whole lifetime.
        let secondDriver = FakeSurfaceDriver()
        try await store.attach(driver: secondDriver, host: FakeSurfaceHost())
        let afterReattach = try #require(store.lastPublishedRevision)
        #expect(afterReattach > beforeReattach)
    }

    // MARK: Epoch ↔ surfaceGeneration binding

    @Test func attachHandsTheBoundEpochToTheDriver() async throws {
        let store = NaviMapSceneStore()
        let driver = FakeSurfaceDriver()
        try await store.attach(driver: driver, host: FakeSurfaceHost())
        // The epoch the driver received IS the store's bound epoch — one
        // minting site, no reconstruction on either side.
        #expect(try driver.attachedEpochs == [#require(store.boundEpoch)])
    }

    @Test func reattachAdvancesBothEpochComponents() async throws {
        let store = NaviMapSceneStore()
        try await store.attach(driver: FakeSurfaceDriver(), host: FakeSurfaceHost())
        let first = try #require(store.boundEpoch)
        try await store.attach(driver: FakeSurfaceDriver(), host: FakeSurfaceHost())
        let second = try #require(store.boundEpoch)
        #expect(second.attachGeneration > first.attachGeneration)
        #expect(second.scopeGeneration > first.scopeGeneration)
    }

    @Test func staleDriverEventsAfterReattachAreRejected() async throws {
        let store = NaviMapSceneStore()
        let staleDriver = FakeSurfaceDriver()
        try await store.attach(driver: staleDriver, host: FakeSurfaceHost())

        let liveDriver = FakeSurfaceDriver()
        try await store.attach(driver: liveDriver, host: FakeSurfaceHost())

        // The stale driver's binding task was cancelled with its binding;
        // its events must not flip readiness under the new attach.
        staleDriver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        staleDriver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        for _ in 0 ..< 200 { await Task.yield() }
        #expect(!store.reconciler.actual.isSurfaceReady)

        liveDriver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        liveDriver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { store.reconciler.actual.isSurfaceReady }
    }

    @Test func surfaceGenerationsFlowThroughTheBinding() async throws {
        let (store, driver) = try await makeReadyStore()
        #expect(store.reconciler.actual.surfaceGeneration == 1)

        // A surface rebuild (new generation) voids readiness until the SAME
        // generation reports ready; the old generation's ready is stale.
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 2))
        try await drain { !store.reconciler.actual.isSurfaceReady }
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        for _ in 0 ..< 200 { await Task.yield() }
        #expect(!store.reconciler.actual.isSurfaceReady)
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 2))
        try await drain { store.reconciler.actual.isSurfaceReady }
    }

    // MARK: Pump: desired scene reaches the driver

    @Test func desiredComponentsApplyOnceSurfaceIsReady() async throws {
        let (store, driver) = try await makeReadyStore()
        store.setComponents([makeComponent("a", "s1")])
        // Whether the attach-time empty snapshot's (empty) plan reaches the
        // driver before this update is scheduling-dependent; assert on the
        // settled state, not on plan ordering.
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
        let plan = try #require(driver.appliedPlans.last)
        #expect(plan.epoch == store.boundEpoch)
        #expect(plan.revision == store.lastPublishedRevision)
    }

    @Test func surfaceRebuildTriggersFullReplay() async throws {
        let (store, driver) = try await makeReadyStore()
        store.setComponents([makeComponent("a", "s1")])
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }

        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 2))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 2))
        // Same desired revision, rebuilt surface: the whole tree replays.
        try await drain { driver.appliedPlans.count >= 2 }
        let replay = try #require(driver.appliedPlans.last)
        #expect(replay.revision == store.lastPublishedRevision)
    }

    @Test func applyFailureStopsThePumpAndIsObservable() async throws {
        let (store, _) = try await makeReadyStore(script: [.fail])
        store.setComponents([makeComponent("a", "s1")])
        try await drain { store.lastFailure != nil }
        #expect(store.reconciler.actual.appliedRevision == nil)

        // The next desired update re-pumps and succeeds (script exhausted →
        // acknowledge).
        store.setComponents([makeComponent("a", "s2")])
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
    }

    @Test func updatesDuringInFlightApplyAreAppliedNext() async throws {
        let (store, driver) = try await makeReadyStore(
            script: [.acknowledgeWhenResumed, .acknowledge]
        )
        store.setComponents([makeComponent("a", "s1")])
        try await drain { driver.appliedPlans.count == 1 }

        // Desired moves while the first apply is suspended; on resume the
        // first plan's markApplied is revision-guarded away and the pump
        // drains the newer revision.
        store.setComponents([makeComponent("a", "s2")])
        driver.resumePending()
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
        #expect(driver.appliedPlans.count == 2)
    }

    // MARK: Snapshot-rebuild frequency

    @Test func exactlyOneSnapshotPerDesiredUpdate() async throws {
        // No amplification: N desired updates publish exactly N snapshots
        // (revision delta == N). A position tick at 60fps must cost one
        // snapshot, never a cascade.
        let (store, _) = try await makeReadyStore()
        let before = try #require(store.lastPublishedRevision)
        let ticks: UInt64 = 120
        for index in 0 ..< ticks {
            store.setComponents([makeComponent("ownship", "pos-\(index)")])
        }
        let after = try #require(store.lastPublishedRevision)
        #expect(after.rawValue - before.rawValue == ticks)
    }

    @Test func surfaceEventsDoNotMintRevisions() async throws {
        // Readiness/rebuild events touch actual state, never desired state:
        // no snapshot is rebuilt because the surface reloaded.
        let (store, driver) = try await makeReadyStore()
        store.setComponents([makeComponent("a", "s1")])
        let before = try #require(store.lastPublishedRevision)
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 2))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 2))
        try await drain { store.reconciler.actual.appliedRevision == before }
        #expect(store.lastPublishedRevision == before)
    }

    @Test func detachStopsEventConsumption() async throws {
        let (store, driver) = try await makeReadyStore()
        await store.detach()
        #expect(driver.detachCount == 1)
        #expect(store.boundEpoch == nil)
    }
}
