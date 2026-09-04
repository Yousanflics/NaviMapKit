//
//  ExternalSceneFeedTests.swift
//  NaviMapKitTests
//
//  DataSource-road semantics: snapshot authority,
//  delta coalescing at the drain boundary, revision-chain continuity with
//  self-heal signaling, and mint preservation — app revisions never become
//  published revisions.
//

import NaviMapCore
import NaviMapKit
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing

@MainActor
struct ExternalSceneFeedTests {
    private func makeComponent(_ id: String, _ signature: String) -> AnySceneComponent {
        AnySceneComponent(
            componentID: ComponentID(id),
            definitionSignature: DefinitionSignature(signature)
        )
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

    private func externalSnapshot(
        revision: UInt64, _ components: [AnySceneComponent]
    ) -> NavigationSceneSnapshot {
        // The app's own epoch/revision universe — deliberately unrelated to
        // the store's (authority test below).
        NavigationSceneSnapshot(
            epoch: SceneEpoch(attachGeneration: 999, scopeGeneration: 999),
            revision: SceneRevision(revision),
            components: components
        )
    }

    @Test func snapshotFeedsDesiredScene() async throws {
        let (store, driver) = try await makeReadyStore()
        store.applyExternalSnapshot(externalSnapshot(revision: 10, [
            makeComponent("a", "s1"), makeComponent("b", "s1"),
        ]))
        // The attach-time empty snapshot may or may not reach the driver
        // first (scheduling); assert on the settled state.
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
        let plan = try #require(driver.appliedPlans.last)
        // The published revision is store-minted, not the app's 10; the
        // epoch is the bound one, not the app's 999.
        #expect(plan.epoch == store.boundEpoch)
        #expect(plan.revision == store.lastPublishedRevision)
        #expect(plan.revision != SceneRevision(10))
    }

    @Test func continuousDeltasApplyAndCoalesce() async throws {
        let (store, _) = try await makeReadyStore()
        store.applyExternalSnapshot(externalSnapshot(revision: 1, [makeComponent("a", "s1")]))
        let afterSnapshot = try #require(store.lastPublishedRevision)

        // A burst of chained deltas upserting the same component: all accept,
        // and the drain coalesces them into ONE publish (newest wins).
        for step in 2 ... 6 {
            let delta = NavigationSceneDelta(
                baseRevision: SceneRevision(UInt64(step - 1)),
                revision: SceneRevision(UInt64(step)),
                changes: [.upsert(makeComponent("a", "s\(step)"))]
            )
            #expect(store.applyExternalDelta(delta))
        }
        try await drain { store.lastPublishedRevision != afterSnapshot }
        let afterBurst = try #require(store.lastPublishedRevision)
        #expect(afterBurst.rawValue - afterSnapshot.rawValue == 1)
        #expect(store.reconciler.desired?.components == [makeComponent("a", "s6")])
    }

    @Test func revisionGapIsRefusedForSelfHeal() async throws {
        let (store, _) = try await makeReadyStore()
        store.applyExternalSnapshot(externalSnapshot(revision: 5, [makeComponent("a", "s1")]))

        // base 7 ≠ current chain head 5 → refused; caller must re-request a
        // full snapshot. Chain state must be unchanged by the refusal.
        let gap = NavigationSceneDelta(
            baseRevision: SceneRevision(7),
            revision: SceneRevision(8),
            changes: [.upsert(makeComponent("a", "s2"))]
        )
        #expect(!store.applyExternalDelta(gap))

        // The chain still anchors at 5: a properly-chained delta accepts.
        let chained = NavigationSceneDelta(
            baseRevision: SceneRevision(5),
            revision: SceneRevision(6),
            changes: [.upsert(makeComponent("a", "s3"))]
        )
        #expect(store.applyExternalDelta(chained))
    }

    @Test func deltaRemovalAndTimelineApply() async throws {
        let (store, _) = try await makeReadyStore()
        store.applyExternalSnapshot(externalSnapshot(revision: 1, [
            makeComponent("a", "s1"), makeComponent("b", "s1"),
        ]))
        let delta = NavigationSceneDelta(
            baseRevision: SceneRevision(1),
            revision: SceneRevision(2),
            changes: [
                .remove(ComponentID("a")),
                .timeline(SceneTimeline(cursor: nil)),
            ]
        )
        #expect(store.applyExternalDelta(delta))
        try await drain {
            store.reconciler.desired?.components == [makeComponent("b", "s1")]
        }
    }

    @Test func freshSnapshotDiscardsPendingDeltas() async throws {
        let (store, _) = try await makeReadyStore()
        store.applyExternalSnapshot(externalSnapshot(revision: 1, [makeComponent("a", "s1")]))
        // Delta accepted but not yet flushed…
        #expect(store.applyExternalDelta(NavigationSceneDelta(
            baseRevision: SceneRevision(1),
            revision: SceneRevision(2),
            changes: [.upsert(makeComponent("stale", "x"))]
        )))
        // …then a self-heal snapshot arrives first: pending changes must die
        // with the old chain, never leak into the healed scene.
        store.applyExternalSnapshot(externalSnapshot(revision: 20, [makeComponent("b", "s1")]))
        for _ in 0 ..< 200 { await Task.yield() }
        #expect(store.reconciler.desired?.components == [makeComponent("b", "s1")])
    }
}
