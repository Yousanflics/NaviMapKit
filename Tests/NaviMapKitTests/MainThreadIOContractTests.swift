//
//  MainThreadIOContractTests.swift
//  NaviMapKitTests
//
//  The main-thread I/O contract hook as a mechanism (a main-thread call is
//  reported with its call site; an off-main call is silent), and the
//  contract applied to the one disk surface in scope: the coordinator's
//  startup restore and its flush moments perform no main-thread I/O, keep
//  restore-before-GPS ordering, and never clobber the previous session
//  before the restore has resolved.
//

import Foundation
import NaviMapCore
@testable import NaviMapKit
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing
import UIKit

private extension CameraPose {
    func withScale(_ metersPerPoint: Double) -> CameraPose {
        var copy = self
        copy.scale = MapScale(metersPerPoint: metersPerPoint)
        return copy
    }
}

struct MainThreadIOContractHookTests {
    private let recorder = MainThreadIOViolationRecorder.shared

    @MainActor
    @Test func mainThreadCallIsReportedWithItsCallSite() {
        MainThreadIOViolationRecorder.install()
        let before = recorder.violations(operationPrefix: "test.probe.main").count
        let expectedLine: UInt = #line; MainThreadIOContract.assertOffMainThread("test.probe.main")
        let after = recorder.violations(operationPrefix: "test.probe.main")
        #expect(after.count == before + 1)
        #expect(after.last?.file.hasSuffix("MainThreadIOContractTests.swift") == true)
        #expect(after.last?.line == expectedLine)
    }

    @Test func offMainCallIsSilent() async {
        MainThreadIOViolationRecorder.install()
        let before = recorder.violations(operationPrefix: "test.probe.offmain").count
        await Task.detached {
            MainThreadIOContract.assertOffMainThread("test.probe.offmain")
        }.value
        #expect(recorder.violations(operationPrefix: "test.probe.offmain").count == before)
    }
}

/// Captures the typed viewport events so a test can wait for the
/// coordinator to have processed a surface signal before acting on it.
@MainActor
private final class ViewportStateRecorder: NaviMapDelegate {
    private(set) var states: [NavigationViewportState] = []
    func map(_ map: NaviMapHandle, didChange viewport: NavigationViewportState) {
        states.append(viewport)
    }
}

@MainActor
struct StartupIOContractTests {
    private let recorder = MainThreadIOViolationRecorder.shared

    private func drain(until condition: () -> Bool) async throws {
        for _ in 0 ..< 10_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "condition not reached after bounded drain")
    }

    private func drain(untilAsync condition: () async -> Bool) async throws {
        for _ in 0 ..< 10_000 {
            if await condition() { return }
            await Task.yield()
        }
        let reached = await condition()
        try #require(reached, "condition not reached after bounded drain")
    }

    private func position(_ lat: Double, _ lon: Double) -> NavigationPosition {
        NavigationPosition(latitude: lat, longitude: lon, vertical: .unknown)
    }

    private func makeStore() -> ViewportSessionStore {
        MainThreadIOViolationRecorder.install()
        return ViewportSessionStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("navimapkit-startup-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("viewport-session.json")
        )
    }

    private func makeProfile(_ driver: FakeSurfaceDriver) -> MapProfile {
        MapProfile(
            identifier: "navimap.profile.test",
            makeDriver: { driver },
            makeHost: { FakeSurfaceHost() }
        )
    }

    private var sessionViolationCount: Int {
        recorder.violations(operationPrefix: "viewport-session").count
    }

    @Test func restoreIsReadOffMainAndStillPrecedesReadiness() async throws {
        let store = makeStore()
        let restoredPose = CameraPose(
            center: position(37.6191, -122.3816), scale: MapScale(metersPerPoint: 42)
        )
        await store.saveOffMain(ViewportSession(
            viewport: .follow(.ownship, .courseUp), lastCameraPose: restoredPose
        ))
        let violationsBefore = sessionViolationCount

        let driver = FakeSurfaceDriver()
        let coordinator = NaviMapCoordinator(sessionStore: store)
        coordinator.start(
            profile: makeProfile(driver),
            hosting: FakeSurfaceHost(),
            hostView: UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800)),
            handle: nil,
            elements: [NavigationBasemap(.operational).element],
            dataSource: nil,
            viewport: .follow(.ownship, .courseUp),
            setViewport: { _ in }
        )
        try await drain { !driver.attachedEpochs.isEmpty }
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { !driver.cameraUpdates.isEmpty }

        // The FIRST camera set is the restore, without animation: it was
        // known before attach, so readiness cannot overtake it.
        #expect(driver.cameraUpdates.first?.pose == restoredPose)
        #expect(driver.cameraUpdates.first?.animated == false)
        #expect(sessionViolationCount == violationsBefore)

        coordinator.stop()
        await store.clearOffMain()
    }

    /// Restore ownership: the binding's initial value is
    /// the fallback; a persisted free intent replaces it with one discrete
    /// `.restore` write-back before the surface is ready, and the camera's
    /// first set is that pose without animation.
    @Test func persistedIntentIsRestoredIntoTheBindingBeforeReadiness() async throws {
        let store = makeStore()
        let persistedPose = CameraPose(
            center: position(35.6762, 139.6503), scale: MapScale(metersPerPoint: 88)
        )
        await store.saveOffMain(ViewportSession(
            viewport: .free(persistedPose), lastCameraPose: persistedPose
        ))
        let violationsBefore = sessionViolationCount

        let driver = FakeSurfaceDriver()
        let coordinator = NaviMapCoordinator(sessionStore: store)
        var bindingWrites: [NavigationViewport] = []
        coordinator.start(
            profile: makeProfile(driver),
            hosting: FakeSurfaceHost(),
            hostView: UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800)),
            handle: nil,
            elements: [],
            dataSource: nil,
            viewport: .follow(.ownship, .courseUp),
            setViewport: { bindingWrites.append($0) }
        )
        try await drain { !driver.attachedEpochs.isEmpty }
        // The write-back happened before attach completed, exactly once.
        #expect(bindingWrites == [.free(persistedPose)])

        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { !driver.cameraUpdates.isEmpty }
        #expect(driver.cameraUpdates.first?.pose == persistedPose)
        #expect(driver.cameraUpdates.first?.animated == false)
        #expect(sessionViolationCount == violationsBefore)

        coordinator.stop()
        await store.clearOffMain()
    }

    /// `.fit` is an action for this session: it outranks the persisted
    /// intent (no write-back), while the persisted pose still applies
    /// first without animation.
    @Test func fitIntentOutranksPersistedIntent() async throws {
        let store = makeStore()
        let persistedPose = CameraPose(
            center: position(35.6762, 139.6503), scale: MapScale(metersPerPoint: 88)
        )
        await store.saveOffMain(ViewportSession(
            viewport: .free(persistedPose), lastCameraPose: persistedPose
        ))
        let fit = ViewportFit(positions: [position(37.0, -122.0), position(38.0, -121.0)])

        let driver = FakeSurfaceDriver()
        let coordinator = NaviMapCoordinator(sessionStore: store)
        var bindingWrites: [NavigationViewport] = []
        // The coordinator holds the host view weakly; the size gate needs
        // it alive for the fit to resolve.
        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        coordinator.start(
            profile: makeProfile(driver),
            hosting: FakeSurfaceHost(),
            hostView: hostView,
            handle: nil,
            elements: [],
            dataSource: nil,
            viewport: .fit(fit),
            setViewport: { bindingWrites.append($0) }
        )
        try await drain { !driver.attachedEpochs.isEmpty }
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { driver.cameraUpdates.count >= 2 }
        #expect(bindingWrites.isEmpty)
        #expect(driver.cameraUpdates.first?.pose == persistedPose)
        #expect(driver.cameraUpdates.first?.animated == false)
        #expect(driver.cameraUpdates.last?.pose != persistedPose)
        withExtendedLifetime(hostView) {}

        coordinator.stop()
        await store.clearOffMain()
    }

    /// An unrecognized persisted schema is discarded whole: no intent
    /// write-back, no pose restore — the initial value
    /// stands, exactly as when nothing is stored.
    @Test func unrecognizedPersistedSchemaLeavesTheBindingUntouched() async throws {
        let store = makeStore()
        let persistedPose = CameraPose(
            center: position(35.6762, 139.6503), scale: MapScale(metersPerPoint: 88)
        )
        await store.saveOffMain(ViewportSession(
            viewport: .free(persistedPose), lastCameraPose: persistedPose
        ))
        // Tamper with the file off the main thread (test-side I/O).
        let fileURL = store.fileURL
        try await Task.detached {
            var json = try #require(JSONSerialization.jsonObject(
                with: Data(contentsOf: fileURL)
            ) as? [String: Any])
            json["schemaVersion"] = 999
            try JSONSerialization.data(withJSONObject: json).write(to: fileURL)
        }.value

        let driver = FakeSurfaceDriver()
        let coordinator = NaviMapCoordinator(sessionStore: store)
        var bindingWrites: [NavigationViewport] = []
        coordinator.start(
            profile: makeProfile(driver),
            hosting: FakeSurfaceHost(),
            hostView: UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800)),
            handle: nil,
            elements: [],
            dataSource: nil,
            viewport: .free(persistedPose.withScale(1)),
            setViewport: { bindingWrites.append($0) }
        )
        try await drain { !driver.attachedEpochs.isEmpty }
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { !driver.cameraUpdates.isEmpty }
        #expect(bindingWrites.isEmpty)
        #expect(driver.cameraUpdates.first?.pose == persistedPose.withScale(1))

        coordinator.stop()
        await store.clearOffMain()
    }

    @Test func flushBeforeRestoreResolvesKeepsThePreviousSession() async {
        let store = makeStore()
        let previousPose = CameraPose(
            center: position(48.8566, 2.3522), scale: MapScale(metersPerPoint: 77)
        )
        let previous = ViewportSession(viewport: .free(previousPose), lastCameraPose: previousPose)
        await store.saveOffMain(previous)

        let driver = FakeSurfaceDriver()
        let coordinator = NaviMapCoordinator(sessionStore: store)
        coordinator.start(
            profile: makeProfile(driver),
            hosting: FakeSurfaceHost(),
            hostView: UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800)),
            handle: nil,
            elements: [],
            dataSource: nil,
            viewport: .follow(.ownship, .courseUp),
            setViewport: { _ in }
        )
        // Torn down before the off-main restore read could resolve: the
        // flush has nothing true to write and must leave the file intact.
        coordinator.stop()
        for _ in 0 ..< 100 { await Task.yield() }
        let loaded = await store.loadOffMain()
        #expect(loaded == previous)
        await store.clearOffMain()
    }

    @Test func explicitFlushWritesOffMain() async throws {
        let store = makeStore()
        let violationsBefore = sessionViolationCount
        let handle = NaviMapHandle()
        let states = ViewportStateRecorder()
        handle.delegate = states
        let driver = FakeSurfaceDriver()
        let coordinator = NaviMapCoordinator(sessionStore: store)
        coordinator.start(
            profile: makeProfile(driver),
            hosting: FakeSurfaceHost(),
            hostView: UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800)),
            handle: handle,
            elements: [],
            dataSource: nil,
            viewport: .follow(.ownship, .courseUp),
            setViewport: { _ in }
        )
        try await drain { !driver.attachedEpochs.isEmpty }
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        let heldPose = CameraPose(
            center: position(51.4700, -0.4543), scale: MapScale(metersPerPoint: 60)
        )
        driver.emitSurfaceEvent(.cameraIdle(heldPose))
        // The idle signal must have reached the coordinator before the
        // flush, or the flush persists the earlier pose.
        try await drain { states.states.last?.camera == heldPose }

        handle.flushViewport()
        try await drain(untilAsync: { await store.loadOffMain()?.lastCameraPose == heldPose })
        #expect(sessionViolationCount == violationsBefore)

        coordinator.stop()
        await store.clearOffMain()
    }
}
