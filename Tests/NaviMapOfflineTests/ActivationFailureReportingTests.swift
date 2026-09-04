//
//  ActivationFailureReportingTests.swift
//  NaviMapOfflineTests
//
//  Each activation failure path the manager can take maps to the public
//  issue the delegate receives — one test per path, driven through the
//  manager rather than the enum, so the mapping is tied to the real
//  mechanism. Plus the freshness evaluation from the authority policy.
//

import Foundation
import NaviMapCore
import NaviMapOffline
import NaviMapTesting
import Testing

@ContentPreparationActor
private struct Harness {
    let registryURL: URL
    let fileSystem = InMemoryContentFileSystem()
    let layout = ContentLayout(root: URL(fileURLWithPath: "/content-root", isDirectory: true))
    let confirmer: ScriptedActivationConfirmer
    let content = ContentID("charts.terminal")

    init(script: [ScriptedActivationConfirmer.Step] = []) {
        MainThreadIOViolationRecorder.install()
        registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("navimapkit-report-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("registry.sqlite")
        confirmer = ScriptedActivationConfirmer(script: script)
    }

    func makeManager(timeout: Duration = .seconds(8), rejectPayload: Bool = false) throws -> GenerationManager {
        try GenerationManager(
            registry: GenerationRegistry(fileURL: registryURL),
            fileSystem: fileSystem,
            layout: layout,
            confirmer: confirmer,
            validator: ClosureGenerationValidator { _, _ throws(RejectionReason) in
                if rejectPayload { throw .checksum }
            },
            mounter: ClosureContentMounter(),
            acknowledgementTimeout: timeout
        )
    }

    func stage(_ manager: GenerationManager, _ generationID: GenerationID) throws {
        let download = try manager.beginDownload(contentID: content, generationID: generationID)
        try fileSystem.write(Data("tiles".utf8), to: manager.stagingDirectory(for: download).appendingPathComponent("payload.bin"))
        try manager.completeDownload(download)
        try manager.validate(content, generationID)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
    }
}

private let gen1 = GenerationID("2026-09")

/// Captures the failure the manager threw for a path.
private func failure(_ body: () async throws -> Void) async -> GenerationFailure? {
    do {
        try await body()
        return nil
    } catch let failure as GenerationFailure {
        return failure
    } catch {
        return nil
    }
}

@Suite(.serialized)
struct ActivationFailureReportingTests {
    @Test func acknowledgementTimeoutReportsTimedOut() async throws {
        let harness = await Harness(script: [.never])
        let manager = try await harness.makeManager(timeout: .milliseconds(50))
        try await harness.stage(manager, gen1)
        let thrown = await failure { _ = try await manager.activate(harness.content, gen1) }
        #expect(thrown?.operationalIssue(for: harness.content)
            == .contentActivationFailed(harness.content, .acknowledgementTimedOut))
        await harness.cleanUp()
    }

    @Test func confirmationFailureReportsItsTypedReason() async throws {
        let harness = await Harness(script: [.fail(.epochChanged)])
        let manager = try await harness.makeManager()
        try await harness.stage(manager, gen1)
        let thrown = await failure { _ = try await manager.activate(harness.content, gen1) }
        #expect(thrown?.operationalIssue(for: harness.content)
            == .contentActivationFailed(harness.content, .confirmationFailed(.epochChanged)))
        await harness.cleanUp()
    }

    @Test func validationFailureReportsRejected() async throws {
        let harness = await Harness()
        let manager = try await harness.makeManager(rejectPayload: true)
        let thrown = await failure { try await harness.stage(manager, gen1) }
        #expect(thrown?.operationalIssue(for: harness.content)
            == .contentActivationFailed(harness.content, .rejected(.checksum)))
        await harness.cleanUp()
    }

    @Test func nonActivationFailuresAreNotReported() {
        let content = ContentID("charts.terminal")
        #expect(GenerationFailure.unknownGeneration(gen1).operationalIssue(for: content) == nil)
        #expect(GenerationFailure.duplicateGeneration(gen1).operationalIssue(for: content) == nil)
        #expect(GenerationFailure.invalidTransition(gen1, from: .staged, to: .active).operationalIssue(for: content) == nil)
        #expect(GenerationFailure.registry("locked").operationalIssue(for: content) == nil)
        #expect(GenerationFailure.fileSystem("enoent").operationalIssue(for: content) == nil)
    }

    // MARK: Freshness from authority policy

    private let installed = InstalledAt(instant: Date(timeIntervalSince1970: 1_000_000))
    private let policy = RefreshPolicy(staleAfter: .seconds(3600), expiredAfter: .seconds(86_400))

    @Test func freshnessFollowsThePolicyThresholds() {
        let base = installed.instant
        let authority = ContentAuthority.localAuthoritative(policy)
        #expect(ContentFreshness.health(installedAt: installed, authority: authority, now: base.addingTimeInterval(10)) == .fresh)
        #expect(ContentFreshness.health(installedAt: installed, authority: authority, now: base.addingTimeInterval(3600)) == .stale)
        #expect(ContentFreshness.health(installedAt: installed, authority: authority, now: base.addingTimeInterval(86_400)) == .expired)
    }

    @Test func hybridUsesItsLocalPolicyAndRemoteAllowedIsUnknown() {
        let base = installed.instant
        #expect(ContentFreshness.health(
            installedAt: installed, authority: .hybrid(HybridPolicy(local: policy)), now: base.addingTimeInterval(4000)
        ) == .stale)
        // No policy: the explicit unknown state, never a guess.
        #expect(ContentFreshness.health(installedAt: installed, authority: .remoteAllowed, now: base) == .unknown)
    }
}
