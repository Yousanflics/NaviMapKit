//
//  ReconcilerCoreTests.swift
//  NaviMapSceneTests
//
//  Tests for the reconciliation core semantics plus the
//  component-level diff upgrade.
//

import NaviMapCore
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing

@MainActor
struct ReconcilerCoreTests {
    private func component(_ id: String, _ signature: String) -> AnySceneComponent {
        AnySceneComponent(
            componentID: ComponentID(id),
            definitionSignature: DefinitionSignature(signature)
        )
    }

    private func snapshot(
        revision: UInt64,
        _ components: [AnySceneComponent]
    ) -> NavigationSceneSnapshot {
        NavigationSceneSnapshot(
            epoch: SceneEpoch(attachGeneration: 1, scopeGeneration: 1),
            revision: SceneRevision(revision),
            components: components
        )
    }

    // MARK: Diff judgment

    @Test func diffJudgmentTable() {
        let mounted: [ComponentID: DefinitionSignature] = [
            ComponentID("keep"): DefinitionSignature("v1"),
            ComponentID("changed"): DefinitionSignature("v1"),
            ComponentID("gone"): DefinitionSignature("v1"),
        ]
        let desired = [
            component("keep", "v1"), // no-op
            component("changed", "v2"), // update (same id, new signature)
            component("new", "v1"), // mount
        ]

        let ops = ReconcilerCore.diff(mounted: mounted, desired: desired)

        #expect(ops == [
            .unmount(ComponentID("gone")),
            .mount(component("new", "v1")),
            .update(component("changed", "v2")),
        ])
    }

    @Test func diffOrderingIsDeterministic() {
        let desired = [component("b", "v1"), component("a", "v1")]
        let ops = ReconcilerCore.diff(mounted: [:], desired: desired)
        #expect(ops == [.mount(component("a", "v1")), .mount(component("b", "v1"))])
    }

    // MARK: Seed semantics (generation gating, accepts/markApplied)

    @Test func planRequiresReadySurfaceAndUnappliedRevision() throws {
        let core = ReconcilerCore()
        core.updateDesired(snapshot(revision: 1, [component("a", "v1")]))
        #expect(core.reconcilePlan() == nil) // surface not ready

        let generation = core.attachSurface(initialSurfaceGeneration: 0)
        core.surfaceBecameReady(attachGeneration: generation, surfaceGeneration: 0)

        let plan = core.reconcilePlan()
        #expect(plan != nil)
        #expect(try core.markApplied(#require(plan)))
        #expect(core.reconcilePlan() == nil) // applied — nothing to do
    }

    @Test func staleGenerationReadinessIsRejected() {
        let core = ReconcilerCore()
        let generation = core.attachSurface(initialSurfaceGeneration: 0)
        #expect(!core.surfaceBecameReady(attachGeneration: generation &+ 1, surfaceGeneration: 0))
        #expect(!core.surfaceBecameReady(attachGeneration: generation, surfaceGeneration: 5))
        #expect(core.surfaceBecameReady(attachGeneration: generation, surfaceGeneration: 0))
        // Second ready on the same generation is a no-op (one-way latch).
        #expect(!core.surfaceBecameReady(attachGeneration: generation, surfaceGeneration: 0))
    }

    @Test func stalePlanIsNotAccepted() throws {
        let core = ReconcilerCore()
        let generation = core.attachSurface(initialSurfaceGeneration: 0)
        core.surfaceBecameReady(attachGeneration: generation, surfaceGeneration: 0)
        core.updateDesired(snapshot(revision: 1, [component("a", "v1")]))
        let plan = try #require(core.reconcilePlan())

        // Desired moves on before the plan lands.
        core.updateDesired(snapshot(revision: 2, [component("a", "v2")]))

        #expect(!core.accepts(plan))
        #expect(!core.markApplied(plan))
    }

    @Test func surfaceRebuildForcesFullReplay() throws {
        // rebuild = actual reset + full replay, zero business
        // involvement.
        let core = ReconcilerCore()
        var generation = core.attachSurface(initialSurfaceGeneration: 0)
        core.surfaceBecameReady(attachGeneration: generation, surfaceGeneration: 0)
        core.updateDesired(snapshot(revision: 1, [component("a", "v1"), component("b", "v1")]))
        #expect(try core.markApplied(#require(core.reconcilePlan())))

        // Surface reload (style reload analog).
        core.surfaceLoadStarted(attachGeneration: generation, surfaceGeneration: 1)
        #expect(core.reconcilePlan() == nil) // not ready during reload
        core.surfaceBecameReady(attachGeneration: generation, surfaceGeneration: 1)

        let replay = core.reconcilePlan()
        #expect(replay != nil)
        // Everything mounts again — the mounted tree was reset.
        #expect(replay?.operations.count == 2)
        #expect(try #require(replay?.operations.allSatisfy {
            if case .mount = $0 { return true } else { return false }
        }))

        // Controller-level rebuild does the same through attachSurface.
        generation = core.attachSurface(initialSurfaceGeneration: 0)
        core.surfaceBecameReady(attachGeneration: generation, surfaceGeneration: 0)
        #expect(core.reconcilePlan()?.operations.count == 2)
    }

    @Test func equalDesiredSnapshotsDoNotChurn() throws {
        let core = ReconcilerCore()
        let generation = core.attachSurface(initialSurfaceGeneration: 0)
        core.surfaceBecameReady(attachGeneration: generation, surfaceGeneration: 0)
        core.updateDesired(snapshot(revision: 1, [component("a", "v1")]))
        #expect(try core.markApplied(#require(core.reconcilePlan())))

        // Identical snapshot (same revision, same content): no new plan.
        core.updateDesired(snapshot(revision: 1, [component("a", "v1")]))
        #expect(core.reconcilePlan() == nil)
    }

    // MARK: F4 — attach failure injection

    @Test func fakeDriverAttachFailureInjection() async throws {
        let driver = FakeSurfaceDriver(attachScript: [.fail, .succeed])
        let epoch = SceneEpoch(attachGeneration: 1, scopeGeneration: 1)

        await #expect(throws: SurfaceDriverFailure.attachRejected) {
            try await driver.attach(to: FakeSurfaceHost(), epoch: epoch)
        }
        try await driver.attach(to: FakeSurfaceHost(), epoch: epoch)
        #expect(driver.attachedEpochs == [epoch])
    }

    // MARK: Custom equality with payload present

    @Test func componentEqualityIgnoresPresentationPayload() {
        // The reintroduced hand-written ==: closures never
        // participate; equality is id + signature exactly.
        let a = AnySceneComponent(
            componentID: ComponentID("x"),
            definitionSignature: DefinitionSignature("v1"),
            makePresentation: { _, _ in PresentationFragment() }
        )
        let b = AnySceneComponent(
            componentID: ComponentID("x"),
            definitionSignature: DefinitionSignature("v1"),
            makePresentation: { _, _ in PresentationFragment() }
        )
        #expect(a == b)
    }
}
