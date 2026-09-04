//
//  EvaluationReferenceTests.swift
//  NaviMapKitTests
//
//  The store supplies the instant every component is evaluated at: the
//  timeline cursor, or its clock sampled once per publish when the scene is
//  realtime. A component whose depiction depends on that instant draws an
//  expired or not-yet-effective element in neither mode.
//

import Foundation
import NaviMapCore
@testable import NaviMapKit
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing

/// Draws one marker while the reference falls inside its interval.
private struct TimedComponent: SceneComponent {
    var interval: DateInterval

    var componentID: ComponentID { ComponentID("test.timed") }
    var definitionSignature: DefinitionSignature { definitionSignature(at: nil) }
    var presentation: PresentationFragment { presentation(at: nil) }

    func isEffective(at reference: RepresentedTime?) -> Bool {
        guard let reference else { return true }
        return reference.instant >= interval.start && reference.instant < interval.end
    }

    func definitionSignature(at reference: RepresentedTime?) -> DefinitionSignature {
        DefinitionSignature("timed/\(isEffective(at: reference))")
    }

    func presentation(at reference: RepresentedTime?) -> PresentationFragment {
        guard isEffective(at: reference) else { return PresentationFragment() }
        return PresentationFragment(operations: [
            .upsertEntityMarker(EntityID("timed"), NavigationPosition(latitude: 0, longitude: 0, vertical: .unknown), label: nil),
        ])
    }
}

@MainActor
struct EvaluationReferenceTests {
    private let interval = DateInterval(start: Date(timeIntervalSince1970: 1_000), duration: 1_000)

    private func drain(until condition: () -> Bool) async throws {
        for _ in 0 ..< 10_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "condition not reached after bounded drain")
    }

    private func makeReadyStore(now: Date) async throws -> (NaviMapSceneStore, FakeSurfaceDriver) {
        let store = NaviMapSceneStore()
        store.now = { now }
        let driver = FakeSurfaceDriver()
        try await store.attach(driver: driver, host: FakeSurfaceHost())
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { store.reconciler.actual.isSurfaceReady }
        return (store, driver)
    }

    private func markerOps(in driver: FakeSurfaceDriver) -> Int {
        driver.appliedPlans.flatMap(\.operations).filter {
            if case .upsertEntityMarker(let id, _, _) = $0, id == EntityID("timed") { return true }
            return false
        }.count
    }

    private func settle(_ store: NaviMapSceneStore) async throws {
        try await drain { store.reconciler.actual.appliedRevision == store.lastPublishedRevision }
    }

    // Failure paths first: what must not be drawn.

    @Test func realtimeExpiredElementIsNotDrawn() async throws {
        let (store, driver) = try await makeReadyStore(now: Date(timeIntervalSince1970: 5_000))
        store.setComponents([AnySceneComponent(TimedComponent(interval: interval))])
        try await settle(store)
        #expect(markerOps(in: driver) == 0)
        #expect(store.publishedReference == RepresentedTime(instant: Date(timeIntervalSince1970: 5_000)))
    }

    @Test func realtimeNotYetEffectiveElementIsNotDrawn() async throws {
        let (store, driver) = try await makeReadyStore(now: Date(timeIntervalSince1970: 10))
        store.setComponents([AnySceneComponent(TimedComponent(interval: interval))])
        try await settle(store)
        #expect(markerOps(in: driver) == 0)
    }

    @Test func replayCursorOutsideTheIntervalIsNotDrawn() async throws {
        let (store, driver) = try await makeReadyStore(now: Date(timeIntervalSince1970: 1_500))
        store.setTimeline(SceneTimeline(cursor: RepresentedTime(instant: Date(timeIntervalSince1970: 100))))
        store.setComponents([AnySceneComponent(TimedComponent(interval: interval))])
        try await settle(store)
        // The cursor, not the clock, is the reference during replay.
        #expect(markerOps(in: driver) == 0)
        #expect(store.publishedReference == RepresentedTime(instant: Date(timeIntervalSince1970: 100)))
    }

    // Happy paths.

    @Test func realtimeEffectiveElementIsDrawnAtTheSampledInstant() async throws {
        let (store, driver) = try await makeReadyStore(now: Date(timeIntervalSince1970: 1_500))
        store.setComponents([AnySceneComponent(TimedComponent(interval: interval))])
        try await settle(store)
        #expect(markerOps(in: driver) == 1)
    }

    @Test func aLaterSampleReconcilesAsAnOrdinaryUpdate() async throws {
        let (store, driver) = try await makeReadyStore(now: Date(timeIntervalSince1970: 1_500))
        let component = AnySceneComponent(TimedComponent(interval: interval))
        store.setComponents([component])
        try await settle(store)
        #expect(markerOps(in: driver) == 1)
        // Same declaration, clock now past the end: the drawn set changes,
        // the signature changes, and the marker is removed.
        store.now = { Date(timeIntervalSince1970: 5_000) }
        store.setComponents([component])
        try await settle(store)
        let removals = driver.appliedPlans.flatMap(\.operations).filter {
            if case .removeEntityMarker(let id) = $0, id == EntityID("timed") { return true }
            return false
        }.count
        #expect(removals == 1)
    }
}
