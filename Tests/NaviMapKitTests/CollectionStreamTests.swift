//
//  CollectionStreamTests.swift
//  NaviMapKitTests
//
//  A streamed collection reaches the scene as whole groups: every emission
//  replaces the collection's members, so a member that stops appearing is
//  unmounted, and the stream itself is never part of any signature.
//

import Foundation
import NaviMapCore
@testable import NaviMapKit
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing
import UIKit

/// One member of a streamed collection, drawn as a marker.
private struct MemberComponent: SceneComponent {
    var address: String
    var latitude: Double

    var componentID: ComponentID { ComponentID("test.collection.member.\(address)") }
    var definitionSignature: DefinitionSignature { DefinitionSignature("member/\(address)/\(latitude)") }
    var presentation: PresentationFragment {
        PresentationFragment(operations: [.upsertEntityMarker(
            EntityID("test.collection.\(address)"),
            NavigationPosition(latitude: latitude, longitude: -122, vertical: .unknown),
            label: nil
        )])
    }
}

@MainActor
struct CollectionStreamTests {
    private func drain(until condition: () -> Bool) async throws {
        for _ in 0 ..< 10_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "condition not reached after bounded drain")
    }

    private func group(_ members: [(String, Double)]) -> [AnySceneComponent] {
        members.map { AnySceneComponent(MemberComponent(address: $0.0, latitude: $0.1)) }
    }

    private func markerOps(_ driver: FakeSurfaceDriver) -> [(EntityID, Bool)] {
        driver.appliedPlans.flatMap(\.operations).compactMap { op in
            switch op {
            case .upsertEntityMarker(let id, _, _) where id.rawValue.hasPrefix("test.collection."): (id, true)
            case .removeEntityMarker(let id) where id.rawValue.hasPrefix("test.collection."): (id, false)
            default: nil
            }
        }
    }

    private func makeStartedCoordinator(groups: AsyncStream<[AnySceneComponent]>) async throws -> (NaviMapCoordinator, FakeSurfaceDriver, UIView) {
        let driver = FakeSurfaceDriver()
        let profile = MapProfile(
            identifier: "navimap.profile.test",
            makeDriver: { driver },
            makeHost: { FakeSurfaceHost() }
        )
        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let coordinator = NaviMapCoordinator()
        coordinator.start(
            profile: profile,
            hosting: profile.makeHost(),
            hostView: hostView,
            handle: nil,
            elements: [
                NavigationBasemap(.operational).element,
                NavigationSceneElement(kind: .collectionStream(collectionID: "test.collection", groups: groups)),
            ],
            dataSource: nil,
            viewport: .free(CameraPose(
                center: NavigationPosition(latitude: 37, longitude: -122, vertical: .unknown),
                scale: MapScale(metersPerPoint: 100)
            )),
            setViewport: { _ in }
        )
        try await drain { !driver.attachedEpochs.isEmpty }
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain {
            driver.appliedPlans.flatMap(\.operations).contains { if case .setBasemap = $0 { true } else { false } }
        }
        return (coordinator, driver, hostView)
    }

    // Failure path first: a member that stops appearing must be unmounted.

    @Test func aMemberAbsentFromTheNextGroupIsUnmounted() async throws {
        let (groups, continuation) = AsyncStream.makeStream(of: [AnySceneComponent].self)
        let (coordinator, driver, hostView) = try await makeStartedCoordinator(groups: groups)
        continuation.yield(group([("a", 37.1), ("b", 37.2)]))
        try await drain { markerOps(driver).filter(\.1).count == 2 }
        continuation.yield(group([("b", 37.2)]))
        try await drain { markerOps(driver).contains { !$0.1 && $0.0 == EntityID("test.collection.a") } }
        // b was re-declared unchanged: no second upsert for it.
        #expect(markerOps(driver).filter { $0.1 && $0.0 == EntityID("test.collection.b") }.count == 1)
        continuation.finish()
        withExtendedLifetime((coordinator, hostView)) {}
    }

    @Test func anEmptyGroupUnmountsEveryMember() async throws {
        let (groups, continuation) = AsyncStream.makeStream(of: [AnySceneComponent].self)
        let (coordinator, driver, hostView) = try await makeStartedCoordinator(groups: groups)
        continuation.yield(group([("a", 37.1)]))
        try await drain { markerOps(driver).filter(\.1).count == 1 }
        continuation.yield([])
        try await drain { markerOps(driver).contains { !$0.1 } }
        continuation.finish()
        withExtendedLifetime((coordinator, hostView)) {}
    }

    // Happy path: a changed member updates, an unchanged one is a no-op.

    @Test func aChangedMemberUpdatesInPlace() async throws {
        let (groups, continuation) = AsyncStream.makeStream(of: [AnySceneComponent].self)
        let (coordinator, driver, hostView) = try await makeStartedCoordinator(groups: groups)
        continuation.yield(group([("a", 37.1)]))
        try await drain { markerOps(driver).filter(\.1).count == 1 }
        continuation.yield(group([("a", 37.3)]))
        try await drain { markerOps(driver).filter(\.1).count == 2 }
        #expect(!markerOps(driver).contains { !$0.1 })
        continuation.finish()
        withExtendedLifetime((coordinator, hostView)) {}
    }
}
