//
//  FakeSurfaceDriverTests.swift
//  NaviMapRuntimeTests
//

import NaviMapCore
import NaviMapRuntime
import NaviMapTesting
import Testing

@MainActor
struct FakeSurfaceDriverTests {
    private let epoch = SceneEpoch(attachGeneration: 1, scopeGeneration: 1)

    @Test func acknowledgesInScriptOrder() async throws {
        let driver = FakeSurfaceDriver(script: [.acknowledge, .fail])
        try await driver.attach(to: FakeSurfaceHost(), epoch: epoch)

        let ack = try await driver.apply(RenderPlan(epoch: epoch, revision: SceneRevision(1)))
        #expect(ack.appliedRevision == SceneRevision(1))

        await #expect(throws: SurfaceDriverFailure.applyRejected(SceneRevision(2))) {
            _ = try await driver.apply(RenderPlan(epoch: epoch, revision: SceneRevision(2)))
        }
        #expect(driver.appliedPlans.count == 2)
    }

    @Test func suspendedAcknowledgementWaitsForExplicitResume() async throws {
        // Deterministic delayed-ack: the apply suspends until the test resumes
        // it — no wall-clock sleeps involved.
        let driver = FakeSurfaceDriver(script: [.acknowledgeWhenResumed])
        try await driver.attach(to: FakeSurfaceHost(), epoch: epoch)

        let task = Task { @MainActor in
            try await driver.apply(RenderPlan(epoch: epoch, revision: SceneRevision(9)))
        }
        // Let the apply reach its suspension point, then release it.
        while driver.appliedPlans.isEmpty {
            await Task.yield()
        }
        driver.resumePending()

        let ack = try await task.value
        #expect(ack.appliedRevision == SceneRevision(9))
    }
}
