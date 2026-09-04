//
//  NaviMapCoordinatorTests.swift
//  NaviMapKitTests
//
//  The declarative road across body re-evaluations: re-declared static
//  content reaches the reconciler — a
//  late-resolving route is an update, not frozen first-declaration state.
//  Exercises the real coordinator with a fake driver behind a test profile.
//

import NaviMapCore
@testable import NaviMapKit
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing
import UIKit

@MainActor
struct NaviMapCoordinatorTests {
    private func drain(until condition: () -> Bool) async throws {
        for _ in 0 ..< 10_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "condition not reached after bounded drain")
    }

    private func position(_ lat: Double, _ lon: Double) -> NavigationPosition {
        NavigationPosition(latitude: lat, longitude: lon, vertical: .unknown)
    }

    @Test func redeclaredContentReachesTheDriver() async throws {
        let driver = FakeSurfaceDriver()
        let profile = MapProfile(
            identifier: "navimap.profile.test",
            makeDriver: { driver },
            makeHost: { FakeSurfaceHost() }
        )
        let coordinator = NaviMapCoordinator()
        coordinator.start(
            profile: profile,
            hosting: profile.makeHost(),
            hostView: UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800)),
            handle: nil,
            elements: [NavigationBasemap(.operational).element],
            dataSource: nil,
            viewport: .free(CameraPose(
                center: position(37, -122), scale: MapScale(metersPerPoint: 100)
            )),
            setViewport: { _ in }
        )
        try await drain { !driver.attachedEpochs.isEmpty }
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain {
            driver.appliedPlans.flatMap(\.operations).contains { op in
                if case .setBasemap = op { return true }
                return false
            }
        }

        // The pilot's core flow: the body re-evaluates with a route that
        // resolved late — the re-declared content must reach the driver.
        let route = [position(37.6191, -122.3816), position(33.9425, -118.4081)]
        coordinator.elementsChanged(to: [
            NavigationBasemap(.operational).element,
            RoutePath(route).element,
        ])
        try await drain {
            driver.appliedPlans.flatMap(\.operations).contains { op in
                if case .upsertPath(_, let positions) = op { return positions == route }
                return false
            }
        }
        coordinator.stop()
    }
}
