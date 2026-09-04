//
//  RoutePathPipelineTests.swift
//  NaviMapKitTests
//
//  Path primitive through the store/executor pipeline: mount emits the
//  upsert, a definition change re-renders (the late-resolving-route case the
//  pilot depends on), unmount and path-dropping updates emit the removal,
//  and `.fit` viewport persistence stores the action's result.
//

import Foundation
import NaviMapCore
@testable import NaviMapKit
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing

@MainActor
struct RoutePathPipelineTests {
    private func position(_ lat: Double, _ lon: Double) -> NavigationPosition {
        NavigationPosition(latitude: lat, longitude: lon, vertical: .unknown)
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

    private func pathOps(in driver: FakeSurfaceDriver) -> [RenderOp] {
        driver.appliedPlans.flatMap(\.operations).filter {
            if case .upsertPath = $0 { return true }
            if case .removePath = $0 { return true }
            return false
        }
    }

    @Test func routeChangeIsAnUpdateThatReRenders() async throws {
        let (store, driver) = try await makeReadyStore()
        let direct = [position(37.6191, -122.3816), position(34.05, -118.25)]
        store.setComponents([AnySceneComponent(RoutePathComponent(positions: direct))])
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
        #expect(pathOps(in: driver).count == 1)

        // The pilot's core scenario: the resolved route lands late — same
        // component identity, new definition → a second upsert reaches the
        // driver (no remount, no silent stale line).
        let resolved = direct + [position(36.0, -120.0)]
        store.setComponents([AnySceneComponent(RoutePathComponent(positions: resolved))])
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
        let ops = pathOps(in: driver)
        #expect(ops.count == 2)
        if case .upsertPath(_, let positions) = try #require(ops.last) {
            #expect(positions == resolved)
        }
    }

    @Test func unmountEmitsPathRemoval() async throws {
        let (store, driver) = try await makeReadyStore()
        let component = AnySceneComponent(RoutePathComponent(positions: [
            position(37.0, -122.0), position(38.0, -121.0),
        ]))
        store.setComponents([component])
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
        store.setComponents([])
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
        if case .removePath(let componentID) = try #require(pathOps(in: driver).last) {
            #expect(componentID == component.componentID)
        } else {
            Issue.record("expected a removePath operation")
        }
    }

    @Test func fitViewportPersistsItsResultNotIntent() async throws {
        MainThreadIOViolationRecorder.install()
        let store = ViewportSessionStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("navimapkit-fit-\(UUID().uuidString)")
                .appendingPathComponent("viewport-session.json")
        )

        let fitViewport = NavigationViewport.fit(ViewportFit(positions: [
            position(37.0, -122.0), position(38.0, -121.0),
        ]))
        let effective = CameraPose(
            center: position(37.5, -121.5),
            scale: MapScale(metersPerPoint: 222)
        )

        // Before the size gate produced a pose: nothing true to write.
        await store.saveOffMain(ViewportSession(viewport: fitViewport, lastCameraPose: nil))
        #expect(await store.loadOffMain() == nil)

        // After: the RESULT persists, as a free pose.
        await store.saveOffMain(ViewportSession(viewport: fitViewport, lastCameraPose: effective))
        let restored = try #require(await store.loadOffMain())
        #expect(restored.viewport == .free(effective))
        await store.clearOffMain()
    }
}
