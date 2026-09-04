//
//  ContentSourceTests.swift
//  NaviMapKitTests
//
//  The content-source primitive end to end: executor mapping with unmount
//  inversion, the store's acknowledgement covering a revision under the
//  bound epoch (and only that epoch), failure on apply failure and on
//  epoch change, and the generation manager confirmed by the reconciler's
//  own acknowledgement — including a timeout whose rollback rebinds the
//  previous generation and whose late acknowledgement is harmless.
//

import Foundation
import NaviMapCore
@testable import NaviMapKit
import NaviMapOffline
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing

@MainActor
struct ContentSourceTests {
    private let content = ContentID("charts.terminal")
    private let directory = URL(fileURLWithPath: "/content-root/content/charts.terminal/generations/2026-09", isDirectory: true)
    private var mount: ContentMount {
        .geoJSON(directory: directory, entry: directory.appendingPathComponent("features.geojson"))
    }

    private func drain(until condition: () -> Bool) async throws {
        for _ in 0 ..< 10_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "condition not reached after bounded drain")
    }

    private func attachedReadyStore(driver: FakeSurfaceDriver) async throws -> NaviMapSceneStore {
        let store = NaviMapSceneStore()
        try await store.attach(driver: driver, host: FakeSurfaceHost())
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { store.reconciler.actual.isSurfaceReady }
        return store
    }

    private func bindingOps(in driver: FakeSurfaceDriver) -> [RenderOp] {
        driver.appliedPlans.flatMap(\.operations).filter {
            if case .setContentSource = $0 { return true }
            return false
        }
    }

    // MARK: Executor

    @Test func executorMapsTheBindingAndInvertsItOnUnmount() {
        let executor = RenderPlanExecutor()
        let component = AnySceneComponent(ContentSourceComponent(contentID: content, location: .prepared(mount)))
        let epoch = SceneEpoch(attachGeneration: 1, scopeGeneration: 1)

        let mounted = executor.makeRenderPlan(
            from: ReconcilePlan(epoch: epoch, revision: SceneRevision(1), operations: [.mount(component)]),
            components: [component]
        )
        #expect(mounted.operations == [.setContentSource(content, .prepared(mount))])

        let unmount = executor.makeRenderPlan(
            from: ReconcilePlan(epoch: epoch, revision: SceneRevision(2), operations: [.unmount(component.componentID)]),
            components: []
        )
        #expect(unmount.operations == [.setContentSource(content, .none)])
    }

    /// A stale apply (driver applied, reconciler rejected) leaves the
    /// mount unrecorded on the reconciler side; the executor's ledger still
    /// removes it once the component is gone from the desired scene, even
    /// though no unmount op is ever emitted for it.
    @Test func executorConvergesStateInstalledByAStaleApply() {
        let executor = RenderPlanExecutor()
        let component = AnySceneComponent(ContentSourceComponent(contentID: content, location: .prepared(mount)))
        let epoch = SceneEpoch(attachGeneration: 1, scopeGeneration: 1)
        _ = executor.makeRenderPlan(
            from: ReconcilePlan(epoch: epoch, revision: SceneRevision(1), operations: [.mount(component)]),
            components: [component]
        )
        // The reconciler never marked revision 1 applied; revision 2 has no
        // ops for the component because it was never "mounted".
        let next = executor.makeRenderPlan(
            from: ReconcilePlan(epoch: epoch, revision: SceneRevision(2), operations: []),
            components: []
        )
        #expect(next.operations == [.setContentSource(content, .none)])
        // Idempotent: nothing left to converge.
        let again = executor.makeRenderPlan(
            from: ReconcilePlan(epoch: epoch, revision: SceneRevision(3), operations: []),
            components: []
        )
        #expect(again.operations.isEmpty)
    }

    @Test func bindingSignatureTracksTheGenerationDirectory() {
        let a = ContentSourceComponent(contentID: content, location: .prepared(mount))
        let b = ContentSourceComponent(
            contentID: content,
            location: .prepared(.geoJSON(directory: directory, entry: directory.appendingPathComponent("other.geojson")))
        )
        // Same identity, different definition: a new generation is an
        // update, never a remount.
        #expect(a.componentID == b.componentID)
        #expect(a.definitionSignature != b.definitionSignature)
        #expect(a.definitionSignature != ContentSourceComponent(contentID: content, location: .none).definitionSignature)
    }

    // MARK: Store acknowledgement

    @Test func acknowledgementResolvesOnceACoveringPlanIsApplied() async throws {
        let driver = FakeSurfaceDriver()
        let store = try await attachedReadyStore(driver: driver)

        let revision = try #require(store.bindContentSource(content, .prepared(mount)))
        try await store.acknowledgement(covering: revision)
        #expect(driver.boundContentSources[content] == .prepared(mount))
        #expect(store.reconciler.actual.appliedRevision.map { $0 >= revision } == true)

        // A later revision covers an earlier waiter.
        let first = try #require(store.bindContentSource(content, .none))
        let second = try #require(store.bindContentSource(content, .prepared(mount)))
        #expect(second > first)
        try await store.acknowledgement(covering: first)
        #expect(driver.boundContentSources[content] == .prepared(mount))
    }

    @Test func acknowledgementFailsWhenTheApplyFails() async throws {
        let driver = FakeSurfaceDriver(script: [.acknowledge, .fail])
        let store = try await attachedReadyStore(driver: driver)
        try await drain { store.reconciler.actual.appliedRevision != nil }

        let revision = try #require(store.bindContentSource(content, .prepared(mount)))
        await #expect(throws: AcknowledgementFailure.applyFailed(.applyRejected(revision))) {
            try await store.acknowledgement(covering: revision)
        }
    }

    @Test func acknowledgementFailsWhenTheEpochChanges() async throws {
        let driver = FakeSurfaceDriver()
        let store = NaviMapSceneStore()
        try await store.attach(driver: driver, host: FakeSurfaceHost())
        // Not ready: nothing applies, the waiter stays pending.
        let revision = try #require(store.bindContentSource(content, .prepared(mount)))
        let waiting = Task { @MainActor in
            try await store.acknowledgement(covering: revision)
        }
        for _ in 0 ..< 100 { await Task.yield() }
        await store.detach()
        await #expect(throws: AcknowledgementFailure.epochChanged) {
            try await waiting.value
        }

        // Re-attached under a new epoch: the old revision never confirms;
        // a fresh binding under the new epoch does.
        try await store.attach(driver: driver, host: FakeSurfaceHost())
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { store.reconciler.actual.isSurfaceReady }
        let fresh = try #require(store.bindContentSource(content, .prepared(mount)))
        try await store.acknowledgement(covering: fresh)
        #expect(driver.boundContentSources[content] == .prepared(mount))
    }

    /// A task already cancelled when it asks for the acknowledgement must
    /// not leak a waiter: the cancellation handler runs after the append
    /// (main-actor ordering) and resumes it with CancellationError.
    @Test func acknowledgementCancelledOnEntryDoesNotLeakAWaiter() async throws {
        let driver = FakeSurfaceDriver()
        let store = NaviMapSceneStore()
        try await store.attach(driver: driver, host: FakeSurfaceHost())
        let revision = try #require(store.bindContentSource(content, .prepared(mount)))
        let waiting = Task { @MainActor in
            try await store.acknowledgement(covering: revision)
        }
        waiting.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
        // Nothing left behind: a later detach finds no waiter to fail, and a
        // fresh request under the new epoch behaves normally.
        await store.detach()
        try await store.attach(driver: driver, host: FakeSurfaceHost())
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { store.reconciler.actual.isSurfaceReady }
        let fresh = try #require(store.bindContentSource(content, .prepared(mount)))
        try await store.acknowledgement(covering: fresh)
        #expect(driver.boundContentSources[content] == .prepared(mount))
    }

    @Test func pendingBindingIsPublishedAtAttach() async throws {
        let driver = FakeSurfaceDriver()
        let store = NaviMapSceneStore()
        #expect(store.bindContentSource(content, .prepared(mount)) == nil)
        try await store.attach(driver: driver, host: FakeSurfaceHost())
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { driver.boundContentSources[content] != nil }
        #expect(driver.boundContentSources[content] == .prepared(mount))
    }

    // MARK: Generation manager confirmed by the reconciler

    private struct Pipeline {
        let harness: OfflinePipelineHarness
        let manager: GenerationManager
    }

    @ContentPreparationActor
    private func makePipeline(store: NaviMapSceneStore, timeout: Duration = .seconds(8)) throws -> Pipeline {
        let harness = OfflinePipelineHarness()
        let manager = try GenerationManager(
            registry: GenerationRegistry(fileURL: harness.registryURL),
            fileSystem: harness.fileSystem,
            layout: harness.layout,
            confirmer: SceneStoreActivationConfirmer(store: store),
            validator: ClosureGenerationValidator { _, _ in },
            mounter: ClosureContentMounter(),
            acknowledgementTimeout: timeout
        )
        return Pipeline(harness: harness, manager: manager)
    }

    @Test func activationIsConfirmedByTheReconcilerAcknowledgement() async throws {
        let driver = FakeSurfaceDriver()
        let store = try await attachedReadyStore(driver: driver)
        let pipeline = try await makePipeline(store: store)
        let generation = GenerationID("2026-09")

        let activated = try await pipeline.harness.stageAndActivate(pipeline.manager, generation)
        #expect(activated.generationID == generation)
        #expect(try await pipeline.manager.record(pipeline.harness.content, generation)?.isConfirmed == true)
        #expect(driver.boundContentSources[pipeline.harness.content] == .prepared(activated.mount))
        #expect(store.contentSource(for: pipeline.harness.content) == .prepared(activated.mount))
        await pipeline.harness.cleanUp()
    }

    @Test func timeoutRollsBackTheBindingAndALateAcknowledgementIsHarmless() async throws {
        // Plan 1: the ready replay. Plan 2: the activation binding, held.
        let driver = FakeSurfaceDriver(script: [.acknowledge, .acknowledgeWhenResumed])
        let store = try await attachedReadyStore(driver: driver)
        try await drain { store.reconciler.actual.appliedRevision != nil }
        let pipeline = try await makePipeline(store: store, timeout: .milliseconds(50))
        let generation = GenerationID("2026-09")

        await #expect(throws: GenerationFailure.acknowledgementTimedOut(generation)) {
            _ = try await pipeline.harness.stageAndActivate(pipeline.manager, generation)
        }
        // Rolled back in the registry; the rollback plan is queued behind
        // the held apply.
        #expect(try await pipeline.manager.record(pipeline.harness.content, generation)?.state == .staged)
        #expect(try await pipeline.manager.currentGeneration(for: pipeline.harness.content) == nil)
        #expect(store.contentSource(for: pipeline.harness.content) == .none)

        // The held acknowledgement arrives late: it confirms nothing (the
        // waiter is gone) and the rollback plan applies after it.
        driver.resumePending()
        try await drain { driver.boundContentSources[pipeline.harness.content] == nil && driver.appliedPlans.count >= 3 }
        #expect(bindingOps(in: driver).last == .setContentSource(pipeline.harness.content, .none))
        await pipeline.harness.cleanUp()
    }
}

/// Minimal offline harness for map-layer tests (the full failure matrix
/// lives in the offline target's own tests).
@ContentPreparationActor
private struct OfflinePipelineHarness {
    let registryURL: URL
    let fileSystem = InMemoryContentFileSystem()
    let layout = ContentLayout(root: URL(fileURLWithPath: "/content-root", isDirectory: true))
    let content = ContentID("charts.terminal")

    init() {
        MainThreadIOViolationRecorder.install()
        registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("navimapkit-pipeline-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("registry.sqlite")
    }

    func stageAndActivate(_ manager: GenerationManager, _ generationID: GenerationID) async throws -> ActivatedGeneration {
        let download = try manager.beginDownload(contentID: content, generationID: generationID)
        try fileSystem.write(Data("tiles".utf8), to: manager.stagingDirectory(for: download).appendingPathComponent("payload.bin"))
        try manager.completeDownload(download)
        try manager.validate(content, generationID)
        return try await manager.activate(content, generationID)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
    }
}
