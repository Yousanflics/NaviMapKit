//
//  OfflineOverlayTests.swift
//  NaviMapKitTests
//
//  The offline overlay end to end through the public handle: a declared
//  overlay binds its current generation at attach, staging and activation
//  through the handle render the new generation with zero main-thread I/O,
//  an activation failure is thrown to the caller and reported to the
//  delegate exactly once, a provider mount failure rolls the activation
//  back instead of confirming it, a surface rebuild replays the binding,
//  and freshness reaches operational health.
//

import Foundation
import NaviMapCore
@testable import NaviMapKit
import NaviMapOffline
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing
import UIKit

@MainActor
private final class EventRecorder: NaviMapDelegate {
    private(set) var issues: [MapOperationalIssue] = []
    private(set) var health: [OperationalMapHealth] = []
    func map(_ map: NaviMapHandle, didFail issue: MapOperationalIssue) { issues.append(issue) }
    func map(_ map: NaviMapHandle, didChange health: OperationalMapHealth) { self.health.append(health) }
}

@MainActor
struct OfflineOverlayTests {
    private let content = ContentID("terminal-obstacles")
    private let authority = ContentAuthority.localAuthoritative(
        RefreshPolicy(staleAfter: .seconds(3600), expiredAfter: .seconds(86_400))
    )

    private func drain(until condition: () -> Bool) async throws {
        for _ in 0 ..< 20_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "condition not reached after bounded drain")
    }

    @MainActor
    private struct Rig {
        let root: URL
        let fileSystem = InMemoryContentFileSystem()
        let driver = FakeSurfaceDriver()
        let handle = NaviMapHandle()
        let recorder = EventRecorder()
        let coordinator: NaviMapCoordinator
        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))

        init(timeout: Duration = .seconds(8)) {
            MainThreadIOViolationRecorder.install()
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("navimapkit-overlay-\(UUID().uuidString)", isDirectory: true)
            handle.delegate = recorder
            coordinator = NaviMapCoordinator(
                sessionStore: ViewportSessionStore(fileURL: root.appendingPathComponent("viewport.json")),
                contentRootPath: root.path,
                contentFileSystem: fileSystem,
                contentAcknowledgementTimeout: timeout
            )
        }

        var profile: MapProfile {
            MapProfile(identifier: "navimap.profile.test", makeDriver: { driver }, makeHost: { FakeSurfaceHost() })
        }

        func start(_ elements: [NavigationSceneElement]) {
            coordinator.start(
                profile: profile, hosting: FakeSurfaceHost(), hostView: hostView, handle: handle,
                elements: elements, dataSource: nil, viewport: .follow(.ownship, .courseUp), setViewport: { _ in }
            )
        }

        func ready() {
            driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
            driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        }

        /// An unpacked generation directory in the family's shape, as an
        /// application's downloader would hand it over.
        @ContentPreparationActor
        func unpackedGeneration(_ name: String, features: [String] = []) throws -> URL {
            let directory = root.appendingPathComponent("downloads", isDirectory: true).appendingPathComponent(name, isDirectory: true)
            let data = Data("""
            {"type":"FeatureCollection","features":[\(features.joined(separator: ","))]}
            """.utf8)
            try GeoJSONOverlayFamily.write(featureCollection: data, into: directory, fileSystem: fileSystem)
            return directory
        }

        func cleanUp() {
            coordinator.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private let point = """
    {"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[-122.38,37.62]}}
    """

    @Test func stageAndActivateRenderTheGenerationWithoutMainThreadIO() async throws {
        let rig = Rig()
        let violationsBefore = MainThreadIOViolationRecorder.shared.violations(operationPrefix: "content-").count
        rig.start([NavigationBasemap(.operational).element, OfflineOverlay(content, authority: authority).element])
        try await drain { !rig.driver.attachedEpochs.isEmpty }
        rig.ready()

        let directory = try await rig.unpackedGeneration("2026-09", features: [point])
        let staged = try await rig.handle.content.stage(content, generation: GenerationID("2026-09"), directory: directory)
        try await rig.handle.content.activate(staged)

        guard case .prepared(let mount)? = rig.driver.boundContentSources[content] else {
            Issue.record("content not bound after activation")
            rig.cleanUp()
            return
        }
        #expect(mount.entry.lastPathComponent == "features.geojson")
        #expect(rig.recorder.issues.isEmpty)
        #expect(rig.recorder.health.last?.content[content] == .fresh)
        #expect(MainThreadIOViolationRecorder.shared.violations(operationPrefix: "content-").count == violationsBefore)
        rig.cleanUp()
    }

    @Test func declaredOverlayBindsItsCurrentGenerationAtAttach() async throws {
        let rig = Rig()
        rig.start([OfflineOverlay(content, authority: authority).element])
        try await drain { !rig.driver.attachedEpochs.isEmpty }
        rig.ready()
        let directory = try await rig.unpackedGeneration("2026-09", features: [point])
        let staged = try await rig.handle.content.stage(content, generation: GenerationID("2026-09"), directory: directory)
        try await rig.handle.content.activate(staged)
        rig.coordinator.stop()

        // A new map over the same content root sees the activated generation
        // without any application action.
        let second = Rig()
        let reopened = NaviMapCoordinator(
            sessionStore: ViewportSessionStore(fileURL: rig.root.appendingPathComponent("viewport.json")),
            contentRootPath: rig.root.path, contentFileSystem: rig.fileSystem
        )
        reopened.start(
            profile: second.profile, hosting: FakeSurfaceHost(), hostView: second.hostView, handle: second.handle,
            elements: [OfflineOverlay(content, authority: authority).element], dataSource: nil,
            viewport: .follow(.ownship, .courseUp), setViewport: { _ in }
        )
        try await drain { !second.driver.attachedEpochs.isEmpty }
        second.ready()
        // Wait for exactly what is asserted: health turns fresh on
        // activation and the binding reaches the driver on a separate
        // apply, in no guaranteed order, so both are awaited.
        try await drain {
            second.driver.boundContentSources[content] != nil
                && second.recorder.health.last?.content[content] == .fresh
        }
        #expect(second.driver.boundContentSources[content] != nil)
        #expect(second.recorder.health.last?.content[content] == .fresh)
        reopened.stop()
        rig.cleanUp()
    }

    @Test func activationFailureIsThrownAndReportedOnce() async throws {
        let rig = Rig()
        rig.start([OfflineOverlay(content, authority: authority).element])
        try await drain { !rig.driver.attachedEpochs.isEmpty }
        rig.ready()
        // Declared as two features, holding one: coverage rejects it.
        let directory = try await rig.unpackedGeneration("2026-09", features: [point])
        let manifestURL = directory.appendingPathComponent(ContentManifest.fileName)
        try await Task { @ContentPreparationActor in
            var manifest = try JSONDecoder().decode(ContentManifest.self, from: rig.fileSystem.read(at: manifestURL))
            manifest.featureCount = 2
            try rig.fileSystem.write(JSONEncoder().encode(manifest), to: manifestURL)
        }.value

        let staged = try await rig.handle.content.stage(content, generation: GenerationID("2026-09"), directory: directory)
        await #expect(throws: MapOperationalIssue.contentActivationFailed(content, .rejected(.coverage))) {
            try await rig.handle.content.activate(staged)
        }
        #expect(rig.recorder.issues == [.contentActivationFailed(content, .rejected(.coverage))])
        #expect(rig.driver.boundContentSources[content] == nil)
        #expect(rig.recorder.health.last?.content[content] == .unknown)
        rig.cleanUp()
    }

    @Test func providerMountFailureRollsTheActivationBack() async throws {
        let rig = Rig()
        rig.driver.failingContentBindings = [content]
        rig.start([OfflineOverlay(content, authority: authority).element])
        try await drain { !rig.driver.attachedEpochs.isEmpty }
        rig.ready()
        let directory = try await rig.unpackedGeneration("2026-09", features: [point])
        let staged = try await rig.handle.content.stage(content, generation: GenerationID("2026-09"), directory: directory)
        await #expect(throws: MapOperationalIssue.contentActivationFailed(content, .confirmationFailed(.applyRejected))) {
            try await rig.handle.content.activate(staged)
        }
        #expect(rig.recorder.issues.count == 1)
        #expect(rig.driver.boundContentSources[content] == nil)
        rig.cleanUp()
    }

    @Test func surfaceRebuildReplaysTheBinding() async throws {
        let rig = Rig()
        rig.start([OfflineOverlay(content, authority: authority).element])
        try await drain { !rig.driver.attachedEpochs.isEmpty }
        rig.ready()
        let directory = try await rig.unpackedGeneration("2026-09", features: [point])
        let staged = try await rig.handle.content.stage(content, generation: GenerationID("2026-09"), directory: directory)
        try await rig.handle.content.activate(staged)
        let bindingsBefore = rig.driver.appliedPlans.flatMap(\.operations).filter {
            if case .setContentSource(_, .prepared) = $0 { return true }
            return false
        }.count
        #expect(bindingsBefore == 1)

        // Style reload: the runtime's state is gone; the full replay must
        // re-emit the binding so the provider mounts the content again.
        rig.driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 2))
        rig.driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 2))
        try await drain {
            rig.driver.appliedPlans.flatMap(\.operations).filter {
                if case .setContentSource(_, .prepared) = $0 { return true }
                return false
            }.count == 2
        }
        rig.cleanUp()
    }

    /// Installing the same generation again is a distinguishable benign
    /// failure: the public error names it, and no issue reaches the delegate.
    @Test func restagingAnInstalledGenerationIsBenign() async throws {
        let rig = Rig()
        rig.start([OfflineOverlay(content, authority: authority).element])
        try await drain { !rig.driver.attachedEpochs.isEmpty }
        rig.ready()
        let first = try await rig.unpackedGeneration("first", features: [point])
        let staged = try await rig.handle.content.stage(content, generation: GenerationID("2026-09"), directory: first)
        try await rig.handle.content.activate(staged)

        let again = try await rig.unpackedGeneration("again", features: [point])
        await #expect(throws: NaviMapContentError.generationAlreadyExists(GenerationID("2026-09"))) {
            _ = try await rig.handle.content.stage(content, generation: GenerationID("2026-09"), directory: again)
        }
        #expect(rig.recorder.issues.isEmpty)
        // The map did not take the second copy; the application can drop it.
        let untouched = await Task { @ContentPreparationActor in rig.fileSystem.itemExists(at: again) }.value
        #expect(untouched)
        rig.cleanUp()
    }

    /// A rejected identity is refused on re-stage with the recorded reason,
    /// reported to the delegate only once (at rejection time).
    @Test func restagingARejectedGenerationIsRefusedWithoutANewReport() async throws {
        let rig = Rig()
        rig.start([OfflineOverlay(content, authority: authority).element])
        try await drain { !rig.driver.attachedEpochs.isEmpty }
        rig.ready()
        let directory = try await rig.unpackedGeneration("2026-09", features: [point])
        let manifestURL = directory.appendingPathComponent(ContentManifest.fileName)
        try await Task { @ContentPreparationActor in
            var manifest = try JSONDecoder().decode(ContentManifest.self, from: rig.fileSystem.read(at: manifestURL))
            manifest.featureCount = 2
            try rig.fileSystem.write(JSONEncoder().encode(manifest), to: manifestURL)
        }.value
        let staged = try await rig.handle.content.stage(content, generation: GenerationID("2026-09"), directory: directory)
        await #expect(throws: MapOperationalIssue.contentActivationFailed(content, .rejected(.coverage))) {
            try await rig.handle.content.activate(staged)
        }
        #expect(rig.recorder.issues.count == 1)

        let corrected = try await rig.unpackedGeneration("corrected", features: [point])
        await #expect(throws: NaviMapContentError.generationPreviouslyRejected(GenerationID("2026-09"), .coverage)) {
            _ = try await rig.handle.content.stage(content, generation: GenerationID("2026-09"), directory: corrected)
        }
        #expect(rig.recorder.issues.count == 1)
        let untouched = await Task { @ContentPreparationActor in rig.fileSystem.itemExists(at: corrected) }.value
        #expect(untouched)
        rig.cleanUp()
    }

    @Test func stagingUndeclaredContentIsRefused() async throws {
        let rig = Rig()
        rig.start([NavigationBasemap(.operational).element])
        try await drain { !rig.driver.attachedEpochs.isEmpty }
        let directory = try await rig.unpackedGeneration("2026-09")
        await #expect(throws: NaviMapContentError.contentNotDeclared(content)) {
            _ = try await rig.handle.content.stage(content, generation: GenerationID("2026-09"), directory: directory)
        }
        rig.cleanUp()
    }
}

// MARK: - Pipeline availability, declarations, and public error types

@MainActor
struct OfflinePipelineRobustnessTests {
    private let content = ContentID("terminal-obstacles")
    private let authority = ContentAuthority.localAuthoritative(
        RefreshPolicy(staleAfter: .seconds(3600), expiredAfter: .seconds(86_400))
    )

    private func drain(until condition: () -> Bool) async throws {
        for _ in 0 ..< 20_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "condition not reached after bounded drain")
    }

    @MainActor
    private final class HealthRecorder: NaviMapDelegate {
        private(set) var health: [OperationalMapHealth] = []
        func map(_ map: NaviMapHandle, didChange health: OperationalMapHealth) { self.health.append(health) }
    }

    /// A registry that cannot be opened (its root is an existing file) must
    /// be visible: every declared item reports unknown freshness and the
    /// handle throws the public unavailability error.
    @Test func unopenableRegistryIsVisibleAsUnknownFreshness() async throws {
        MainThreadIOViolationRecorder.install()
        let blockedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("navimapkit-blocked-\(UUID().uuidString)", isDirectory: false)
        try Data("not a directory".utf8).write(to: blockedRoot)
        defer { try? FileManager.default.removeItem(at: blockedRoot) }

        let driver = FakeSurfaceDriver()
        let handle = NaviMapHandle()
        let recorder = HealthRecorder()
        handle.delegate = recorder
        let coordinator = NaviMapCoordinator(
            sessionStore: ViewportSessionStore(fileURL: blockedRoot.appendingPathExtension("viewport")),
            contentRootPath: blockedRoot.path,
            contentFileSystem: InMemoryContentFileSystem()
        )
        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        coordinator.start(
            profile: MapProfile(identifier: "navimap.profile.test", makeDriver: { driver }, makeHost: { FakeSurfaceHost() }),
            hosting: FakeSurfaceHost(), hostView: hostView, handle: handle,
            elements: [OfflineOverlay(content, authority: authority).element], dataSource: nil,
            viewport: .follow(.ownship, .courseUp), setViewport: { _ in }
        )
        try await drain { !driver.attachedEpochs.isEmpty }
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { recorder.health.last?.content[content] == .unknown }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unused", isDirectory: true)
        await #expect(throws: NaviMapContentError.contentUnavailable) {
            _ = try await handle.content.stage(content, generation: GenerationID("g1"), directory: directory)
        }
        withExtendedLifetime(hostView) {}
        coordinator.stop()
    }

    /// Declaring the same content twice keeps the later policy and does
    /// not trap; an unchanged declaration set does not rebind.
    @Test func duplicateDeclarationsKeepTheLaterPolicyAndUnchangedSetsDoNotRebind() async throws {
        MainThreadIOViolationRecorder.install()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("navimapkit-declare-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = InMemoryContentFileSystem()
        let driver = FakeSurfaceDriver()
        let handle = NaviMapHandle()
        let recorder = HealthRecorder()
        handle.delegate = recorder
        let coordinator = NaviMapCoordinator(
            sessionStore: ViewportSessionStore(fileURL: root.appendingPathComponent("viewport.json")),
            contentRootPath: root.path, contentFileSystem: fileSystem
        )
        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let twice = [
            OfflineOverlay(content, authority: authority).element,
            OfflineOverlay(content, authority: .remoteAllowed).element,
        ]
        coordinator.start(
            profile: MapProfile(identifier: "navimap.profile.test", makeDriver: { driver }, makeHost: { FakeSurfaceHost() }),
            hosting: FakeSurfaceHost(), hostView: hostView, handle: handle,
            elements: twice, dataSource: nil, viewport: .follow(.ownship, .courseUp), setViewport: { _ in }
        )
        try await drain { !driver.attachedEpochs.isEmpty }
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))

        // Install a generation; the later declaration (remote allowed, no
        // refresh policy) governs freshness, so health reports unknown.
        let unpacked = root.appendingPathComponent("downloads/g1", isDirectory: true)
        try await Task { @ContentPreparationActor in
            try GeoJSONOverlayFamily.write(
                featureCollection: Data(#"{"type":"FeatureCollection","features":[]}"#.utf8),
                into: unpacked, fileSystem: fileSystem
            )
        }.value
        let staged = try await handle.content.stage(content, generation: GenerationID("g1"), directory: unpacked)
        try await handle.content.activate(staged)
        try await drain { recorder.health.last?.content[content] == .unknown }
        let bindingsAfterActivation = driver.appliedPlans.flatMap(\.operations).filter {
            if case .setContentSource(_, .prepared) = $0 { return true }
            return false
        }.count
        #expect(bindingsAfterActivation == 1)

        // The same declarations again: no rebind, no new plan with a binding.
        coordinator.elementsChanged(to: twice)
        for _ in 0 ..< 200 { await Task.yield() }
        let bindingsAfterRedeclare = driver.appliedPlans.flatMap(\.operations).filter {
            if case .setContentSource(_, .prepared) = $0 { return true }
            return false
        }.count
        #expect(bindingsAfterRedeclare == bindingsAfterActivation)
        withExtendedLifetime(hostView) {}
        coordinator.stop()
    }

    /// Internal faults that are not activation outcomes reach the
    /// application as public errors, never as package types.
    @Test func internalFaultsAreThrownAsPublicErrors() async throws {
        MainThreadIOViolationRecorder.install()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("navimapkit-public-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = FakeSurfaceDriver()
        let handle = NaviMapHandle()
        let coordinator = NaviMapCoordinator(
            sessionStore: ViewportSessionStore(fileURL: root.appendingPathComponent("viewport.json")),
            contentRootPath: root.path, contentFileSystem: InMemoryContentFileSystem()
        )
        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        coordinator.start(
            profile: MapProfile(identifier: "navimap.profile.test", makeDriver: { driver }, makeHost: { FakeSurfaceHost() }),
            hosting: FakeSurfaceHost(), hostView: hostView, handle: handle,
            elements: [OfflineOverlay(content, authority: authority).element], dataSource: nil,
            viewport: .follow(.ownship, .courseUp), setViewport: { _ in }
        )
        try await drain { !driver.attachedEpochs.isEmpty }
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))

        // A staged download for a generation the registry never saw.
        let phantom = StagedDownload(contentID: content, generationID: GenerationID("never"), stagingID: UUID())
        await #expect(throws: NaviMapContentError.activationFailed) {
            try await handle.content.activate(phantom)
        }
        withExtendedLifetime(hostView) {}
        coordinator.stop()
    }
}
