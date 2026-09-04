//
//  ContentPipeline.swift
//  NaviMapKit
//
//  One map's offline content pipeline: owns the generation manager for the
//  map's content root, reconciles the registry once when it starts, binds
//  the current generation of every declared content item into the scene,
//  drives staging and activation for the application, reports activation
//  failures exactly once, and keeps per-content freshness for health.
//  Everything that touches disk runs on the content-preparation actor; the
//  main actor only sees values.
//

import Foundation
import NaviMapCore
import NaviMapOffline

@MainActor
package final class ContentPipeline {
    package struct Declaration: Sendable, Equatable {
        package var contentID: ContentID
        package var authority: ContentAuthority

        package init(contentID: ContentID, authority: ContentAuthority) {
            self.contentID = contentID
            self.authority = authority
        }
    }

    private let store: NaviMapSceneStore
    /// Nil means the application default, resolved on the preparation actor.
    private let rootPath: String?
    private let fileSystem: any ContentFileSystem
    private let acknowledgementTimeout: Duration
    private let now: @Sendable () -> Date

    private var manager: GenerationManager?
    private var preparation: Task<Void, Never>?
    private var declarations: [ContentID: ContentAuthority] = [:]
    /// Set when the registry could not be opened or reconciled: the pipeline
    /// is unavailable and every declared item reports unknown freshness.
    private var startupFailed = false

    /// Latest freshness per declared content, for operational health.
    package private(set) var contentHealth: [ContentID: ContentHealth] = [:]
    /// Fired once per activation failure, after the registry has rolled back.
    package var onIssue: ((MapOperationalIssue) -> Void)?
    package var onHealthChanged: (() -> Void)?

    package init(
        store: NaviMapSceneStore,
        rootPath: String?,
        fileSystem: any ContentFileSystem = LocalContentFileSystem(),
        acknowledgementTimeout: Duration = .seconds(8),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.rootPath = rootPath
        self.fileSystem = fileSystem
        self.acknowledgementTimeout = acknowledgementTimeout
        self.now = now
    }

    /// The application's content root: Application Support/NaviMapKit/content.
    /// Resolved only on the preparation actor: even the home-directory
    /// lookup stats the file system.
    @ContentPreparationActor
    package static func defaultRootPath() -> String {
        NSHomeDirectory() + "/Library/Application Support/NaviMapKit/content"
    }

    /// Declared content items. An unchanged set is a no-op; a changed set
    /// replaces the declarations and binds current generations once the
    /// pipeline is up. A content identity declared twice keeps the later
    /// declaration's policy.
    package func declare(_ items: [Declaration]) {
        var next: [ContentID: ContentAuthority] = [:]
        for item in items { next[item.contentID] = item.authority }
        guard next != declarations else { return }
        declarations = next
        for contentID in contentHealth.keys where next[contentID] == nil {
            contentHealth[contentID] = nil
        }
        if startupFailed {
            markAllUnknown()
        } else if manager != nil {
            Task { await bindCurrentGenerations() }
        }
    }

    /// Opens the registry, reconciles it once for this pipeline's lifetime,
    /// then binds current generations. Never blocks the caller.
    package func start() {
        guard preparation == nil else { return }
        preparation = Task { [weak self] in
            guard let self else { return }
            let store = store
            let rootPath = rootPath
            let fileSystem = fileSystem
            let timeout = acknowledgementTimeout
            let now = now
            let manager = await Self.makeManager(
                rootPath: rootPath, fileSystem: fileSystem, confirmer: SceneStoreActivationConfirmer(store: store),
                acknowledgementTimeout: timeout, now: now
            )
            guard let manager else {
                // The registry could not be opened or reconciled: the
                // pipeline is unavailable, which must be visible, not silent.
                startupFailed = true
                markAllUnknown()
                return
            }
            self.manager = manager
            await bindCurrentGenerations()
        }
    }

    package func stop() {
        preparation?.cancel()
        preparation = nil
        onIssue = nil
        onHealthChanged = nil
    }

    // MARK: Application entry points

    /// Moves an unpacked generation directory into staging and registers it.
    /// The directory must already have the content family's shape. Throws
    /// only public errors.
    package func stage(_ contentID: ContentID, generation: GenerationID, directory: URL) async throws -> StagedDownload {
        guard declarations[contentID] != nil else { throw NaviMapContentError.contentNotDeclared(contentID) }
        let manager = try await readyManager()
        do {
            return try await manager.stageExternalDirectory(directory, contentID: contentID, generationID: generation)
        } catch let failure as GenerationFailure {
            throw Self.publicError(for: failure)
        }
    }

    /// Validates, activates, and waits for the render confirmation. An
    /// activation outcome is thrown as the public operational issue and
    /// reported to the delegate exactly once; any other fault is thrown as
    /// a public content error. Nothing package-level escapes.
    package func activate(_ staged: StagedDownload) async throws {
        let manager = try await readyManager()
        do {
            let state = try await manager.record(staged.contentID, staged.generationID)?.state
            if state == .active {
                await refreshHealth(for: staged.contentID, manager: manager)
                return
            }
            if state != .validated {
                try await manager.validate(staged.contentID, staged.generationID)
            }
            _ = try await manager.activate(staged.contentID, staged.generationID)
        } catch let failure as GenerationFailure {
            await refreshHealth(for: staged.contentID, manager: manager)
            if let issue = failure.operationalIssue(for: staged.contentID) {
                onIssue?(issue)
                throw issue
            }
            throw Self.publicError(for: failure)
        }
        await refreshHealth(for: staged.contentID, manager: manager)
    }

    /// Faults that are not activation outcomes, as the public error type.
    private static func publicError(for failure: GenerationFailure) -> NaviMapContentError {
        switch failure {
        case .duplicateGeneration(let generationID): .generationAlreadyExists(generationID)
        case .previouslyRejected(let generationID, let reason): .generationPreviouslyRejected(generationID, reason)
        case .fileSystem, .registry: .contentUnavailable
        case .unknownGeneration, .invalidTransition: .activationFailed
        case .acknowledgementTimedOut, .confirmationFailed, .validationFailed: .activationFailed
        }
    }

    // MARK: Internals

    @ContentPreparationActor
    private static func makeManager(
        rootPath: String?,
        fileSystem: any ContentFileSystem,
        confirmer: any ActivationConfirming,
        acknowledgementTimeout: Duration,
        now: @escaping @Sendable () -> Date
    ) async -> GenerationManager? {
        let root = URL(fileURLWithPath: rootPath ?? defaultRootPath(), isDirectory: true)
        let layout = ContentLayout(root: root)
        guard let registry = try? GenerationRegistry(fileURL: root.appendingPathComponent("registry.sqlite", isDirectory: false)) else {
            return nil
        }
        let manager = GenerationManager(
            registry: registry,
            fileSystem: fileSystem,
            layout: layout,
            confirmer: confirmer,
            validator: GeoJSONOverlayFamily.Validator(),
            mounter: GeoJSONOverlayFamily.Mounter(),
            acknowledgementTimeout: acknowledgementTimeout,
            now: now
        )
        do {
            _ = try await manager.reconcileAtStartup()
        } catch {
            registry.close()
            return nil
        }
        return manager
    }

    private func markAllUnknown() {
        var changed = false
        for contentID in declarations.keys where contentHealth[contentID] != .unknown {
            contentHealth[contentID] = .unknown
            changed = true
        }
        if changed { onHealthChanged?() }
    }

    private func readyManager() async throws -> GenerationManager {
        if let manager { return manager }
        await preparation?.value
        guard let manager else { throw NaviMapContentError.contentUnavailable }
        return manager
    }

    private func bindCurrentGenerations() async {
        guard let manager else { return }
        for contentID in declarations.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let activated = try? await manager.activatedGeneration(for: contentID)
            store.bindContentSource(contentID, activated.map { .prepared($0.mount) } ?? .none)
            await refreshHealth(for: contentID, manager: manager)
        }
    }

    private func refreshHealth(for contentID: ContentID, manager: GenerationManager) async {
        guard let authority = declarations[contentID] else { return }
        let current = try? await manager.currentGeneration(for: contentID)
        var record: GenerationRecord?
        if let current {
            record = try? await manager.record(contentID, current)
        }
        let health: ContentHealth
        if let record, record.state == .active,
           await (try? manager.activatedGeneration(for: contentID)) != nil {
            health = ContentFreshness.health(installedAt: record.installedAt, authority: authority, now: now())
        } else {
            // No active generation, or an active one whose files cannot be
            // mounted: freshness is unknowable and reported as such.
            health = .unknown
        }
        if contentHealth[contentID] != health {
            contentHealth[contentID] = health
            onHealthChanged?()
        }
    }
}
