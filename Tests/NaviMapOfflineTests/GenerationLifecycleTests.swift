//
//  GenerationLifecycleTests.swift
//  NaviMapOfflineTests
//
//  The failure-path set against an in-memory file system, a
//  real SQLite registry, and scripted acknowledgements: acknowledgement
//  timeout rollback, kill during `activating` followed by startup
//  reconciliation, staging-orphan cleanup, and the regional lease
//  surviving a restart — plus the happy path they all deviate from and the
//  main-thread contract over the whole pipeline.
//

import Foundation
import NaviMapCore
import NaviMapOffline
import NaviMapTesting
import SQLite3
import Testing

@ContentPreparationActor
private struct Harness {
    let registryURL: URL
    let fileSystem = InMemoryContentFileSystem()
    let layout = ContentLayout(root: URL(fileURLWithPath: "/content-root", isDirectory: true))
    let confirmer: ScriptedActivationConfirmer
    let validator = ClosureGenerationValidator { directory, fileSystem throws(RejectionReason) in
        guard fileSystem.itemExists(at: directory.appendingPathComponent("payload.bin")) else {
            throw .coverage
        }
    }

    let content = ContentID("charts.terminal")

    init(script: [ScriptedActivationConfirmer.Step] = []) {
        MainThreadIOViolationRecorder.install()
        registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("navimapkit-registry-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("registry.sqlite")
        confirmer = ScriptedActivationConfirmer(script: script)
    }

    /// A fresh manager over the same registry file and file system: the
    /// process "restarted".
    func makeManager(
        timeout: Duration = .seconds(8),
        rollbackPolicy: RollbackPolicy = .retry,
        mounter: ClosureContentMounter = ClosureContentMounter()
    ) throws -> GenerationManager {
        try GenerationManager(
            registry: GenerationRegistry(fileURL: registryURL),
            fileSystem: fileSystem,
            layout: layout,
            confirmer: confirmer,
            validator: validator,
            mounter: mounter,
            acknowledgementTimeout: timeout,
            rollbackPolicy: rollbackPolicy
        )
    }

    /// downloading → staged → validated, with a payload the validator accepts.
    func stage(_ manager: GenerationManager, _ generationID: GenerationID) throws {
        let download = try manager.beginDownload(contentID: content, generationID: generationID)
        try fileSystem.write(
            Data("tiles".utf8),
            to: manager.stagingDirectory(for: download).appendingPathComponent("payload.bin")
        )
        try manager.completeDownload(download)
        try manager.validate(content, generationID)
    }

    func generationDirectoryExists(_ generationID: GenerationID) -> Bool {
        fileSystem.itemExists(at: layout.generationDirectory(content, generationID))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
    }
}

private let gen1 = GenerationID("2026-08")
private let gen2 = GenerationID("2026-09")

@Suite(.serialized)
struct GenerationLifecycleTests {
    private var contentViolations: Int {
        MainThreadIOViolationRecorder.shared.violations(operationPrefix: "content-").count
    }

    @Test func happyPathActivatesAndRetiresThePredecessor() async throws {
        let harness = await Harness()
        let violationsBefore = contentViolations
        let manager = try await harness.makeManager()
        try await harness.stage(manager, gen1)
        let first = try await manager.activate(harness.content, gen1)
        #expect(first.generationID == gen1)
        #expect(try await manager.record(harness.content, gen1)?.state == .active)
        #expect(try await manager.record(harness.content, gen1)?.isConfirmed == true)
        #expect(try await manager.activatedGeneration(for: harness.content)?.generationID == gen1)

        try await harness.stage(manager, gen2)
        _ = try await manager.activate(harness.content, gen2)
        let old = try #require(try await manager.record(harness.content, gen1))
        let new = try #require(try await manager.record(harness.content, gen2))
        #expect(old.state == .deleted)
        #expect(!old.isLeased)
        #expect(new.state == .active && new.isConfirmed)
        #expect(await !harness.generationDirectoryExists(gen1))
        #expect(await harness.generationDirectoryExists(gen2))
        #expect(await harness.fileSystem.linkDestination(at: harness.layout.currentLink(harness.content))
            == harness.layout.generationDirectory(harness.content, gen2).standardizedFileURL)
        #expect(harness.confirmer.confirmations.map(\.generationID) == [gen1, gen2])
        // The whole pipeline ran inside the preparation context: no
        // main-thread report from the registry or the file system.
        #expect(contentViolations == violationsBefore)
        await harness.cleanUp()
    }

    @Test func acknowledgementTimeoutRollsBackToThePreviousGeneration() async throws {
        let harness = await Harness(script: [.rendered, .never])
        let manager = try await harness.makeManager(timeout: .milliseconds(50))
        try await harness.stage(manager, gen1)
        _ = try await manager.activate(harness.content, gen1)
        try await harness.stage(manager, gen2)

        await #expect(throws: GenerationFailure.acknowledgementTimedOut(gen2)) {
            _ = try await manager.activate(harness.content, gen2)
        }
        let previous = try #require(try await manager.record(harness.content, gen1))
        let failed = try #require(try await manager.record(harness.content, gen2))
        #expect(try await manager.currentGeneration(for: harness.content) == gen1)
        #expect(previous.state == .active && !previous.isLeased)
        // Retryable by policy: back to staged, files kept.
        #expect(failed.state == .staged)
        #expect(await harness.generationDirectoryExists(gen2))
        #expect(harness.confirmer.rollbacks.map { $0?.generationID } == [gen1])
        #expect(await harness.fileSystem.linkDestination(at: harness.layout.currentLink(harness.content))
            == harness.layout.generationDirectory(harness.content, gen1).standardizedFileURL)
        // No stable "activated but unconfirmed" state was left behind.
        #expect(try await manager.activatedGeneration(for: harness.content)?.generationID == gen1)
        await harness.cleanUp()
    }

    @Test func rejectPolicyDiscardsTheFailedGeneration() async throws {
        let harness = await Harness(script: [.fail(.applyRejected)])
        let manager = try await harness.makeManager(rollbackPolicy: .reject)
        try await harness.stage(manager, gen1)
        await #expect(throws: GenerationFailure.self) {
            _ = try await manager.activate(harness.content, gen1)
        }
        #expect(try await manager.record(harness.content, gen1)?.state == .rejected)
        #expect(await !harness.generationDirectoryExists(gen1))
        #expect(try await manager.currentGeneration(for: harness.content) == nil)
        #expect(harness.confirmer.rollbacks.count == 1)
        await harness.cleanUp()
    }

    @Test func killDuringActivatingIsReconciledAtStartup() async throws {
        let harness = await Harness(script: [.rendered, .holdUntilReleased])
        let manager = try await harness.makeManager()
        try await harness.stage(manager, gen1)
        _ = try await manager.activate(harness.content, gen1)
        try await harness.stage(manager, gen2)

        // The process dies while gen2 is `activating`: the activation task
        // never resumes before the "restart" below.
        let dying = Task { @ContentPreparationActor in
            try await manager.activate(harness.content, gen2)
        }
        for _ in 0 ..< 10_000 {
            if try await manager.record(harness.content, gen2)?.state == .activating { break }
            await Task.yield()
        }
        #expect(try await manager.record(harness.content, gen2)?.state == .activating)
        #expect(try await manager.record(harness.content, gen1)?.isLeased == true)

        let restarted = try await harness.makeManager()
        let summary = try await restarted.reconcileAtStartup()
        #expect(summary.rolledBack == [gen2])
        #expect(try await restarted.currentGeneration(for: harness.content) == gen1)
        let previous = try #require(try await restarted.record(harness.content, gen1))
        #expect(previous.state == .active && !previous.isLeased)
        #expect(try await restarted.record(harness.content, gen2)?.state == .staged)
        #expect(await harness.fileSystem.linkDestination(at: harness.layout.currentLink(harness.content))
            == harness.layout.generationDirectory(harness.content, gen1).standardizedFileURL)
        #expect(harness.confirmer.rollbacks.map { $0?.generationID } == [gen1])

        // Letting the dead process's task finish must not undo recovery.
        harness.confirmer.release()
        _ = await dying.result
        #expect(try await restarted.record(harness.content, gen2)?.state == .staged)
        #expect(try await restarted.currentGeneration(for: harness.content) == gen1)
        #expect(harness.confirmer.rollbacks.count == 1)
        await harness.cleanUp()
    }

    @Test func stagingOrphansAreRemovedAtStartup() async throws {
        let harness = await Harness()
        let manager = try await harness.makeManager()
        // A legitimate in-flight download plus two directories nobody
        // registered (a crash between mkdir and the registry insert).
        let download = try await manager.beginDownload(contentID: harness.content, generationID: gen1)
        let orphanA = await harness.layout.stagingDirectory(harness.content, UUID())
        let orphanB = await harness.layout.stagingDirectory(harness.content, UUID())
        try await harness.fileSystem.createDirectory(at: orphanA)
        try await harness.fileSystem.write(Data("half".utf8), to: orphanB.appendingPathComponent("payload.bin"))

        let summary = try await harness.makeManager().reconcileAtStartup()
        // The registered-but-incomplete download is removed too (its files
        // cannot be trusted) — three directories, three removals.
        #expect(summary.removedOrphanDirectories == 3)
        #expect(await !harness.fileSystem.itemExists(at: orphanA))
        #expect(await !harness.fileSystem.itemExists(at: orphanB))
        #expect(await !harness.fileSystem.itemExists(at: manager.stagingDirectory(for: download)))
        #expect(try await manager.record(harness.content, gen1) == nil)
        await harness.cleanUp()
    }

    @Test func regionalLeaseSurvivesRestart() async throws {
        let harness = await Harness(script: [.rendered, .deferredUntilRegionalRender])
        let manager = try await harness.makeManager()
        try await harness.stage(manager, gen1)
        _ = try await manager.activate(harness.content, gen1)
        try await harness.stage(manager, gen2)
        _ = try await manager.activate(harness.content, gen2, leaseScope: "region-a")

        var leased = try #require(try await manager.record(harness.content, gen1))
        #expect(leased.state == .active && leased.isLeased && leased.leaseScope == "region-a")
        #expect(try await manager.record(harness.content, gen2)?.isConfirmed == false)

        // Restart: reconciliation must neither retire the leased
        // predecessor nor roll back the regionally active successor.
        let restarted = try await harness.makeManager()
        let summary = try await restarted.reconcileAtStartup()
        #expect(summary.rolledBack.isEmpty && summary.completedRetirements.isEmpty)
        leased = try #require(try await restarted.record(harness.content, gen1))
        #expect(leased.isLeased && leased.leaseScope == "region-a")
        #expect(await harness.generationDirectoryExists(gen1))
        #expect(try await restarted.currentGeneration(for: harness.content) == gen2)

        try await restarted.confirmRegionalRender(harness.content)
        #expect(try await restarted.record(harness.content, gen1)?.state == .deleted)
        #expect(await !harness.generationDirectoryExists(gen1))
        #expect(try await restarted.record(harness.content, gen2)?.isConfirmed == true)
        await harness.cleanUp()
    }

    @Test func validationFailureRejectsAndCleansStaging() async throws {
        let harness = await Harness()
        let manager = try await harness.makeManager()
        let download = try await manager.beginDownload(contentID: harness.content, generationID: gen1)
        try await manager.completeDownload(download) // no payload written
        await #expect(throws: GenerationFailure.self) {
            try await manager.validate(harness.content, gen1)
        }
        #expect(try await manager.record(harness.content, gen1)?.state == .rejected)
        #expect(await !harness.fileSystem.itemExists(at: manager.stagingDirectory(for: download)))
        await harness.cleanUp()
    }

    @Test func derivedCurrentLinkIsRebuiltFromTheRegistry() async throws {
        let harness = await Harness()
        let manager = try await harness.makeManager()
        try await harness.stage(manager, gen1)
        _ = try await manager.activate(harness.content, gen1)
        // The link drifts (a crash between the registry commit and the
        // rename); the registry wins.
        try await harness.fileSystem.replaceSymbolicLink(
            at: harness.layout.currentLink(harness.content),
            destination: harness.layout.generationDirectory(harness.content, gen2)
        )
        let summary = try await harness.makeManager().reconcileAtStartup()
        #expect(summary.rebuiltLinks == 1)
        #expect(await harness.fileSystem.linkDestination(at: harness.layout.currentLink(harness.content))
            == harness.layout.generationDirectory(harness.content, gen1).standardizedFileURL)
        await harness.cleanUp()
    }

    /// A kill between the `rejected` registry write and the directory
    /// removal leaves files behind; startup reconciliation removes them
    /// because the record, not the directory, is the truth.
    @Test func residualDirectoryOfARejectedRecordIsRemovedAtStartup() async throws {
        let harness = await Harness()
        let manager = try await harness.makeManager()
        try await harness.stage(manager, gen1)
        #expect(await harness.generationDirectoryExists(gen1))

        // Simulate the crash: the record says rejected, the files remain.
        let registry = try await GenerationRegistry(fileURL: harness.registryURL)
        var record = try #require(try await registry.record(contentID: harness.content, generationID: gen1))
        record.state = .rejected
        try await registry.update(record)
        await registry.close()

        let summary = try await harness.makeManager().reconcileAtStartup()
        #expect(summary.removedResidualDirectories == 1)
        #expect(await !harness.generationDirectoryExists(gen1))
        #expect(try await manager.record(harness.content, gen1)?.state == .rejected)
        await harness.cleanUp()
    }

    /// The mount is derived when the generation is handed out; a derivation
    /// failure is a file-system fault that rolls the activation back
    /// before it is thrown, leaving the previous generation in effect.
    @Test func mountDerivationFailureRollsBackBeforeThrowing() async throws {
        let harness = await Harness()
        let failing = ClosureContentMounter { directory, _ in
            if directory.lastPathComponent == gen2.rawValue {
                throw GenerationFailure.fileSystem("manifest unreadable")
            }
            return .geoJSON(directory: directory, entry: directory.appendingPathComponent("payload.bin"))
        }
        let manager = try await harness.makeManager(mounter: failing)
        try await harness.stage(manager, gen1)
        _ = try await manager.activate(harness.content, gen1)
        try await harness.stage(manager, gen2)

        await #expect(throws: GenerationFailure.fileSystem("manifest unreadable")) {
            _ = try await manager.activate(harness.content, gen2)
        }
        #expect(try await manager.currentGeneration(for: harness.content) == gen1)
        #expect(try await manager.record(harness.content, gen1)?.isLeased == false)
        #expect(try await manager.record(harness.content, gen2)?.state == .staged)
        #expect(harness.confirmer.rollbacks.map { $0?.generationID } == [gen1])
        #expect(try await manager.activatedGeneration(for: harness.content)?.generationID == gen1)
        await harness.cleanUp()
    }

    /// A generation staged but never activated (the process died in
    /// between) can be staged again: the existing registration is returned
    /// and activation proceeds; an active generation is a duplicate.
    @Test func restagingIsIdempotentBeforeActivationAndADuplicateAfter() async throws {
        let harness = await Harness()
        let manager = try await harness.makeManager()
        let unpacked = harness.layout.root.appendingPathComponent("downloads/first", isDirectory: true)
        try await harness.fileSystem.write(Data("tiles".utf8), to: unpacked.appendingPathComponent("payload.bin"))
        let first = try await manager.stageExternalDirectory(unpacked, contentID: harness.content, generationID: gen1)

        let again = harness.layout.root.appendingPathComponent("downloads/again", isDirectory: true)
        try await harness.fileSystem.write(Data("tiles".utf8), to: again.appendingPathComponent("payload.bin"))
        let second = try await manager.stageExternalDirectory(again, contentID: harness.content, generationID: gen1)
        #expect(second == first)
        #expect(await harness.fileSystem.itemExists(at: again))

        try await manager.validate(harness.content, gen1)
        _ = try await manager.activate(harness.content, gen1)
        await #expect(throws: GenerationFailure.duplicateGeneration(gen1)) {
            _ = try await manager.stageExternalDirectory(again, contentID: harness.content, generationID: gen1)
        }
        await harness.cleanUp()
    }

    /// A validated generation is returned as it is (its files already live
    /// in the generations tree). A rejected generation's identity is spent:
    /// staging it again is refused before any work with the recorded
    /// reason, and corrected content arrives as a new generation.
    @Test func validatedIsIdempotentAndRejectedIdentityIsSpent() async throws {
        let harness = await Harness()
        let manager = try await harness.makeManager()
        // Rejected first: no payload, the validator refuses.
        let broken = harness.layout.root.appendingPathComponent("downloads/broken", isDirectory: true)
        try await harness.fileSystem.createDirectory(at: broken)
        _ = try await manager.stageExternalDirectory(broken, contentID: harness.content, generationID: gen1)
        await #expect(throws: GenerationFailure.validationFailed(gen1, .coverage)) {
            try await manager.validate(harness.content, gen1)
        }
        let rejected = try #require(try await manager.record(harness.content, gen1))
        #expect(rejected.state == .rejected && rejected.rejectionReason == .coverage)

        // Same identity again: refused with the reason, and the caller's
        // directory is untouched (no copy, no digest).
        let fixed = harness.layout.root.appendingPathComponent("downloads/fixed", isDirectory: true)
        try await harness.fileSystem.write(Data("tiles".utf8), to: fixed.appendingPathComponent("payload.bin"))
        await #expect(throws: GenerationFailure.previouslyRejected(gen1, .coverage)) {
            _ = try await manager.stageExternalDirectory(fixed, contentID: harness.content, generationID: gen1)
        }
        #expect(await harness.fileSystem.itemExists(at: fixed.appendingPathComponent("payload.bin")))
        #expect(try await manager.record(harness.content, gen1)?.state == .rejected)

        // Corrected content as a new generation succeeds.
        let staged = try await manager.stageExternalDirectory(fixed, contentID: harness.content, generationID: gen2)
        try await manager.validate(harness.content, gen2)
        #expect(try await manager.record(harness.content, gen2)?.state == .validated)

        // Validated: staging again returns the registration with no staging id.
        let again = harness.layout.root.appendingPathComponent("downloads/again", isDirectory: true)
        try await harness.fileSystem.write(Data("tiles".utf8), to: again.appendingPathComponent("payload.bin"))
        let idempotent = try await manager.stageExternalDirectory(again, contentID: harness.content, generationID: gen2)
        #expect(idempotent.stagingID == nil && staged.stagingID != nil)
        #expect(await manager.stagingDirectory(for: idempotent) == harness.layout.generationDirectory(harness.content, gen2))
        _ = try await manager.activate(harness.content, gen2)
        #expect(try await manager.record(harness.content, gen2)?.state == .active)

        // The rejection survives a restart with its reason.
        let restarted = try await harness.makeManager()
        #expect(try await restarted.record(harness.content, gen1)?.rejectionReason == .coverage)
        await harness.cleanUp()
    }

    /// A version-1 registry (no rejection reason column) is migrated in
    /// place when opened; existing rows survive with no reason recorded.
    @Test func versionOneRegistryIsMigrated() async throws {
        let harness = await Harness()
        try await Task { @ContentPreparationActor in
            try FileManager.default.createDirectory(at: harness.registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var db: OpaquePointer?
            #expect(sqlite3_open(harness.registryURL.path, &db) == SQLITE_OK)
            let v1 = """
            CREATE TABLE schema_version(version INTEGER NOT NULL);
            INSERT INTO schema_version(version) VALUES (1);
            CREATE TABLE generations(content_id TEXT NOT NULL, generation_id TEXT NOT NULL, state TEXT NOT NULL,
                location TEXT NOT NULL, leased INTEGER NOT NULL DEFAULT 0, lease_scope TEXT,
                confirmed INTEGER NOT NULL DEFAULT 0, sequence INTEGER NOT NULL, installed_at REAL NOT NULL,
                PRIMARY KEY(content_id, generation_id));
            CREATE TABLE current_generation(content_id TEXT PRIMARY KEY, generation_id TEXT NOT NULL);
            INSERT INTO generations VALUES ('charts.terminal', 'old', 'rejected', 'generations', 0, NULL, 0, 1, 0);
            """
            #expect(sqlite3_exec(db, v1, nil, nil, nil) == SQLITE_OK)
            sqlite3_close(db)
        }.value
        let manager = try await harness.makeManager()
        let migrated = try #require(try await manager.record(harness.content, GenerationID("old")))
        #expect(migrated.state == .rejected && migrated.rejectionReason == nil)
        // Its identity stays spent, with no reason to report.
        let retry = harness.layout.root.appendingPathComponent("downloads/retry", isDirectory: true)
        try await harness.fileSystem.write(Data("tiles".utf8), to: retry.appendingPathComponent("payload.bin"))
        await #expect(throws: GenerationFailure.previouslyRejected(GenerationID("old"), nil)) {
            _ = try await manager.stageExternalDirectory(retry, contentID: harness.content, generationID: GenerationID("old"))
        }
        await harness.cleanUp()
    }

    @Test func invalidTransitionsAreRefused() async throws {
        let harness = await Harness()
        let manager = try await harness.makeManager()
        let download = try await manager.beginDownload(contentID: harness.content, generationID: gen1)
        await #expect(throws: GenerationFailure.invalidTransition(gen1, from: .downloading, to: .activating)) {
            _ = try await manager.activate(harness.content, gen1)
        }
        await #expect(throws: GenerationFailure.invalidTransition(gen1, from: .downloading, to: .validating)) {
            try await manager.validate(harness.content, gen1)
        }
        try await manager.completeDownload(download)
        await #expect(throws: GenerationFailure.invalidTransition(gen1, from: .staged, to: .activating)) {
            _ = try await manager.activate(harness.content, gen1)
        }
        await harness.cleanUp()
    }
}
