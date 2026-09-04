//
//  GenerationManager.swift
//  NaviMapOffline
//
//  The generation activation state machine.
//  Isolated to the content-preparation executor: it is the registry's only
//  writer, and every failure path — acknowledgement timeout, kill during
//  activation, staging orphans, regional leases — has a defined transition
//  here rather than in the integrator's hands.
//
//  Isolation note: the design table lists a dedicated `GenerationManager`
//  actor beside `ContentPreparationActor`. Both must serialize on the same
//  executor (the registry's single-writer guarantee and rule 5's "never on
//  the main thread" are the same constraint), so this type is a class
//  isolated to that global actor rather than a second actor with its own
//  executor. Cross-actor hops between the manager and the registry would
//  buy nothing and cost atomicity.
//

import Foundation
import NaviMapCore

package struct StartupReconciliation: Sendable, Equatable {
    package var rolledBack: [GenerationID] = []
    package var completedRetirements: [GenerationID] = []
    package var resetToStaged: [GenerationID] = []
    package var removedOrphanDirectories = 0
    /// Directories still on disk for `rejected`/`deleted` records (a kill
    /// between the registry write and the removal).
    package var removedResidualDirectories = 0
    package var rebuiltLinks = 0

    package init() {}
}

@ContentPreparationActor
package final class GenerationManager {
    package let layout: ContentLayout
    package let acknowledgementTimeout: Duration
    package let rollbackPolicy: RollbackPolicy

    private let registry: GenerationRegistry
    private let fileSystem: any ContentFileSystem
    private let confirmer: any ActivationConfirming
    private let validator: any GenerationValidating
    private let mounter: any ContentMounting
    private let now: @Sendable () -> Date

    package init(
        registry: GenerationRegistry,
        fileSystem: any ContentFileSystem,
        layout: ContentLayout,
        confirmer: any ActivationConfirming,
        validator: any GenerationValidating,
        mounter: any ContentMounting,
        acknowledgementTimeout: Duration = .seconds(8),
        rollbackPolicy: RollbackPolicy = .retry,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.registry = registry
        self.fileSystem = fileSystem
        self.layout = layout
        self.confirmer = confirmer
        self.validator = validator
        self.mounter = mounter
        self.acknowledgementTimeout = acknowledgementTimeout
        self.rollbackPolicy = rollbackPolicy
        self.now = now
    }

    // MARK: Queries

    package func record(_ contentID: ContentID, _ generationID: GenerationID) throws -> GenerationRecord? {
        try registry.record(contentID: contentID, generationID: generationID)
    }

    package func records(for contentID: ContentID) throws -> [GenerationRecord] {
        try registry.records(for: contentID)
    }

    package func currentGeneration(for contentID: ContentID) throws -> GenerationID? {
        try registry.currentGeneration(for: contentID)
    }

    /// The render source for locally authoritative content: the current
    /// generation, only while its record is `active`. The mount is derived
    /// from the directory here, on the preparation actor; a derivation
    /// failure is a file-system fault, never an empty mount.
    package func activatedGeneration(for contentID: ContentID) throws -> ActivatedGeneration? {
        guard let current = try registry.currentGeneration(for: contentID),
              let record = try registry.record(contentID: contentID, generationID: current),
              record.state == .active
        else { return nil }
        return try activatedGeneration(for: record)
    }

    // MARK: downloading → staged

    /// Opens a staging directory and records the generation as
    /// `downloading`. The downloader writes into `stagingDirectory` and
    /// then calls `completeDownload`.
    package func beginDownload(contentID: ContentID, generationID: GenerationID) throws -> StagedDownload {
        if try registry.record(contentID: contentID, generationID: generationID) != nil {
            throw GenerationFailure.duplicateGeneration(generationID)
        }
        let stagingID = UUID()
        try fileSystem.createDirectory(at: layout.stagingDirectory(contentID, stagingID))
        try registry.insert(GenerationRecord(
            contentID: contentID,
            generationID: generationID,
            state: .downloading,
            location: .staging(stagingID),
            installedAt: InstalledAt(instant: now())
        ))
        return StagedDownload(contentID: contentID, generationID: generationID, stagingID: stagingID)
    }

    /// Stages a directory the application has already unpacked in the
    /// content family's shape: it is moved into the staging tree and
    /// registered as `staged`. The application must not touch it afterwards.
    /// Idempotent for a generation that was staged or validated earlier but
    /// never activated (the existing registration is returned and the new
    /// directory is left to the caller); an active generation is reported
    /// as a duplicate. A rejected generation's identity is spent: staging it
    /// again is refused before any copy or digest, with the recorded
    /// reason, and corrected content must arrive as a new generation.
    package func stageExternalDirectory(
        _ directory: URL,
        contentID: ContentID,
        generationID: GenerationID
    ) throws -> StagedDownload {
        if let existing = try registry.record(contentID: contentID, generationID: generationID) {
            switch existing.state {
            case .staged:
                guard case .staging(let stagingID) = existing.location else {
                    throw GenerationFailure.registry("staged generation \(generationID.rawValue) has no staging location")
                }
                return StagedDownload(contentID: contentID, generationID: generationID, stagingID: stagingID)
            case .validated:
                return StagedDownload(contentID: contentID, generationID: generationID, stagingID: nil)
            case .active:
                throw GenerationFailure.duplicateGeneration(generationID)
            case .rejected:
                throw GenerationFailure.previouslyRejected(generationID, existing.rejectionReason)
            default:
                throw GenerationFailure.invalidTransition(generationID, from: existing.state, to: .downloading)
            }
        }
        let download = try beginDownload(contentID: contentID, generationID: generationID)
        let destination = stagingDirectory(for: download)
        do {
            try fileSystem.removeItem(at: destination)
            try fileSystem.moveItem(at: directory, to: destination)
        } catch {
            try? registry.delete(contentID: contentID, generationID: generationID)
            try? fileSystem.removeItem(at: destination)
            throw GenerationFailure.fileSystem("cannot move \(directory.path) into staging: \(error)")
        }
        try completeDownload(download)
        return download
    }

    /// The staging directory while the files are staged, or the generation
    /// directory once they have been validated into the generations tree.
    package func stagingDirectory(for download: StagedDownload) -> URL {
        if let stagingID = download.stagingID {
            return layout.stagingDirectory(download.contentID, stagingID)
        }
        return layout.generationDirectory(download.contentID, download.generationID)
    }

    @discardableResult
    package func completeDownload(_ download: StagedDownload) throws -> GenerationRecord {
        var record = try requireRecord(download.contentID, download.generationID)
        try require(record, in: [.downloading], to: .staged)
        record.state = .staged
        try registry.update(record)
        return record
    }

    // MARK: staged → validating → validated | rejected

    /// Checksum, schema, and coverage must all pass (rule 1); on failure
    /// the entry becomes `rejected` and its files are deleted.
    @discardableResult
    package func validate(_ contentID: ContentID, _ generationID: GenerationID) throws -> GenerationRecord {
        var record = try requireRecord(contentID, generationID)
        try require(record, in: [.staged], to: .validating)
        record.state = .validating
        try registry.update(record)

        let directory = layout.directory(for: record)
        do {
            try validator.validate(directory: directory, fileSystem: fileSystem)
        } catch {
            record.state = .rejected
            record.rejectionReason = error
            try registry.update(record)
            try fileSystem.removeItem(at: directory)
            throw GenerationFailure.validationFailed(generationID, error)
        }

        // Validated files move out of staging into the generations tree.
        if case .staging = record.location {
            let destination = layout.generationDirectory(contentID, generationID)
            try fileSystem.removeItem(at: destination)
            try fileSystem.moveItem(at: directory, to: destination)
            record.location = .generations
        }
        record.state = .validated
        try registry.update(record)
        return record
    }

    // MARK: validated → activating → active (or rollback)

    /// Atomic activation (rule 2), render confirmation with a bounded wait
    /// (rules 3–4), and the regional lease (rule 6).
    package func activate(
        _ contentID: ContentID,
        _ generationID: GenerationID,
        leaseScope: String? = nil
    ) async throws -> ActivatedGeneration {
        var record = try requireRecord(contentID, generationID)
        try require(record, in: [.validated], to: .activating)
        var previous = try registry.records(for: contentID).first { $0.state == .active }

        try registry.transaction {
            record.state = .activating
            try registry.update(record)
            try registry.setCurrentGeneration(generationID, for: contentID)
            if var leased = previous {
                leased.isLeased = true
                leased.leaseScope = leaseScope
                try registry.update(leased)
                previous = leased
            }
        }
        try rebuildCurrentLink(for: contentID)

        let activated: ActivatedGeneration
        do {
            activated = try activatedGeneration(for: record)
        } catch {
            try await rollBack(record, previous: previous, because: error)
            throw error
        }

        let confirmation: ActivationConfirmation
        do {
            confirmation = try await awaitConfirmation(of: activated)
        } catch {
            try await rollBack(record, previous: previous, because: error)
            throw error
        }

        switch confirmation {
        case .rendered:
            try registry.transaction {
                record.state = .active
                record.isConfirmed = true
                try registry.update(record)
                if var retiring = previous {
                    retiring.state = .retiring
                    retiring.isLeased = false
                    retiring.leaseScope = nil
                    try registry.update(retiring)
                    previous = retiring
                }
            }
            if let previous {
                try completeRetirement(of: previous)
            }
        case .deferredUntilRegionalRender:
            // In effect for its own scope; the predecessor stays leased
            // (persisted) until an in-region render confirms the successor.
            record.state = .active
            record.isConfirmed = false
            try registry.update(record)
        }
        return activated
    }

    /// Rule 6 completion: an in-region render confirmed the current
    /// generation, so leased predecessors may retire.
    package func confirmRegionalRender(_ contentID: ContentID) throws {
        guard let current = try registry.currentGeneration(for: contentID),
              var record = try registry.record(contentID: contentID, generationID: current),
              record.state == .active
        else { return }
        var retiring: [GenerationRecord] = []
        try registry.transaction {
            record.isConfirmed = true
            try registry.update(record)
            for var leased in try registry.records(for: contentID) where leased.isLeased {
                leased.state = .retiring
                leased.isLeased = false
                leased.leaseScope = nil
                try registry.update(leased)
                retiring.append(leased)
            }
        }
        for record in retiring {
            try completeRetirement(of: record)
        }
    }

    // MARK: Startup reconciliation (rule 5)

    /// Registry-authoritative recovery: unfinished `activating` entries
    /// roll back, `retiring` entries with a confirmed successor finish
    /// deleting, interrupted validations return to `staged`, incomplete
    /// downloads and staging directories without a record are removed,
    /// directories left behind by `rejected`/`deleted` records are removed,
    /// and every `current` link is rebuilt from the registry.
    ///
    /// Startup only, by contract: the download and residual-directory
    /// cleanup assumes no download or removal is in progress. Running it
    /// while the manager is live would delete work in flight.
    @discardableResult
    package func reconcileAtStartup() async throws -> StartupReconciliation {
        var summary = StartupReconciliation()
        let contentIDs = try Set(registry.contentIDs()).union(contentDirectoriesOnDisk())

        for contentID in contentIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            let records = try registry.records(for: contentID)
            let current = try registry.currentGeneration(for: contentID)

            for record in records where record.state == .activating {
                let previous = records.first { $0.state == .active }
                try registry.transaction {
                    try registry.setCurrentGeneration(previous?.generationID, for: contentID)
                    if var unleased = previous {
                        unleased.isLeased = false
                        unleased.leaseScope = nil
                        try registry.update(unleased)
                    }
                    var failed = record
                    failed.state = .activationFailed
                    try registry.update(failed)
                }
                try settleFailedActivation(record)
                summary.rolledBack.append(record.generationID)
                await confirmer.submitRollback(for: contentID, to: previous.flatMap { try? activatedGeneration(for: $0) })
            }

            for record in records where record.state == .retiring {
                let successorConfirmed = try current
                    .flatMap { try registry.record(contentID: contentID, generationID: $0) }?
                    .isConfirmed ?? false
                if successorConfirmed {
                    try completeRetirement(of: record)
                    summary.completedRetirements.append(record.generationID)
                }
            }

            for var record in records where record.state == .validating {
                record.state = .staged
                try registry.update(record)
                summary.resetToStaged.append(record.generationID)
            }

            for record in records where record.state == .downloading {
                try fileSystem.removeItem(at: layout.directory(for: record))
                try registry.delete(contentID: contentID, generationID: record.generationID)
                summary.removedOrphanDirectories += 1
            }

            // A kill between "state = rejected/deleted" and the removal
            // leaves the directory behind; the record is the truth.
            for record in records where record.state == .rejected || record.state == .deleted {
                let directory = layout.directory(for: record)
                if fileSystem.itemExists(at: directory) {
                    try fileSystem.removeItem(at: directory)
                    summary.removedResidualDirectories += 1
                }
            }

            let referencedStaging = try Set(registry.records(for: contentID).compactMap { record -> String? in
                if case .staging(let stagingID) = record.location { return stagingID.uuidString }
                return nil
            })
            for child in try fileSystem.contentsOfDirectory(at: layout.stagingDirectory(contentID))
                where !referencedStaging.contains(child.lastPathComponent) {
                try fileSystem.removeItem(at: child)
                summary.removedOrphanDirectories += 1
            }

            try rebuildCurrentLink(for: contentID)
            summary.rebuiltLinks += 1
        }
        return summary
    }

    // MARK: Internals

    private func awaitConfirmation(of generation: ActivatedGeneration) async throws -> ActivationConfirmation {
        let confirmer = confirmer
        let timeout = acknowledgementTimeout
        return try await withThrowingTaskGroup(of: ActivationConfirmation.self) { group in
            group.addTask { try await confirmer.confirmActivation(of: generation) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw GenerationFailure.acknowledgementTimedOut(generation.generationID)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw GenerationFailure.confirmationFailed(generation.generationID, .applyRejected)
            }
            return first
        }
    }

    /// Rule 4: the registry points back to the previous generation, a
    /// rollback plan is submitted, and the failed generation returns to
    /// `staged` or becomes `rejected` by policy. Re-reads the record first:
    /// if startup reconciliation already handled it, nothing is done twice.
    private func rollBack(
        _ failed: GenerationRecord,
        previous: GenerationRecord?,
        because error: any Error
    ) async throws {
        guard let fresh = try registry.record(contentID: failed.contentID, generationID: failed.generationID),
              fresh.state == .activating
        else { return }
        try registry.transaction {
            try registry.setCurrentGeneration(previous?.generationID, for: failed.contentID)
            if var unleased = previous {
                unleased.isLeased = false
                unleased.leaseScope = nil
                try registry.update(unleased)
            }
            var record = fresh
            record.state = .activationFailed
            try registry.update(record)
        }
        try rebuildCurrentLink(for: failed.contentID)
        await confirmer.submitRollback(for: failed.contentID, to: previous.flatMap { try? activatedGeneration(for: $0) })
        try settleFailedActivation(fresh)
    }

    private func settleFailedActivation(_ record: GenerationRecord) throws {
        var settled = record
        switch rollbackPolicy {
        case .retry:
            settled.state = .staged
            try registry.update(settled)
        case .reject:
            settled.state = .rejected
            try registry.update(settled)
            try fileSystem.removeItem(at: layout.directory(for: settled))
        }
    }

    private func completeRetirement(of record: GenerationRecord) throws {
        try fileSystem.removeItem(at: layout.directory(for: record))
        var deleted = record
        deleted.state = .deleted
        deleted.isLeased = false
        deleted.leaseScope = nil
        try registry.update(deleted)
    }

    /// The `current` link is derived: rebuilt from the registry, never
    /// consulted as truth (rule 2).
    private func rebuildCurrentLink(for contentID: ContentID) throws {
        let link = layout.currentLink(contentID)
        if let current = try registry.currentGeneration(for: contentID) {
            try fileSystem.replaceSymbolicLink(at: link, destination: layout.generationDirectory(contentID, current))
        } else {
            try fileSystem.removeItem(at: link)
        }
    }

    private func activatedGeneration(for record: GenerationRecord) throws -> ActivatedGeneration {
        let directory = layout.generationDirectory(record.contentID, record.generationID)
        return try ActivatedGeneration(
            contentID: record.contentID,
            generationID: record.generationID,
            directory: directory,
            mount: mounter.mount(for: directory, fileSystem: fileSystem)
        )
    }

    private func contentDirectoriesOnDisk() throws -> [ContentID] {
        try fileSystem.contentsOfDirectory(at: layout.root.appendingPathComponent("content", isDirectory: true))
            .map { ContentID($0.lastPathComponent) }
    }

    private func requireRecord(_ contentID: ContentID, _ generationID: GenerationID) throws -> GenerationRecord {
        guard let record = try registry.record(contentID: contentID, generationID: generationID) else {
            throw GenerationFailure.unknownGeneration(generationID)
        }
        return record
    }

    private func require(_ record: GenerationRecord, in states: [GenerationState], to next: GenerationState) throws {
        guard states.contains(record.state) else {
            throw GenerationFailure.invalidTransition(record.generationID, from: record.state, to: next)
        }
    }
}
