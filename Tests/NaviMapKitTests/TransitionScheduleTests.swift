//
//  TransitionScheduleTests.swift
//  NaviMapKitTests
//
//  In realtime the store re-evaluates exactly at the earliest boundary a
//  component reports, once, and then schedules the next; nothing is
//  scheduled while a cursor is set or when no component reports a
//  boundary, and there is no periodic tick.
//

import Foundation
import NaviMapCore
@testable import NaviMapKit
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing

/// Draws one marker while the reference falls inside its interval and
/// reports the interval's boundaries.
private struct BoundedComponent: SceneComponent {
    var id: String
    var interval: DateInterval

    var componentID: ComponentID { ComponentID("test.bounded.\(id)") }
    var definitionSignature: DefinitionSignature { definitionSignature(at: nil) }
    var presentation: PresentationFragment { presentation(at: nil) }

    func isEffective(at reference: RepresentedTime?) -> Bool {
        guard let reference else { return true }
        return reference.instant >= interval.start && reference.instant < interval.end
    }

    func definitionSignature(at reference: RepresentedTime?) -> DefinitionSignature {
        DefinitionSignature("bounded/\(id)/\(isEffective(at: reference))")
    }

    func presentation(at reference: RepresentedTime?) -> PresentationFragment {
        guard isEffective(at: reference) else { return PresentationFragment() }
        return PresentationFragment(operations: [
            .upsertEntityMarker(EntityID("bounded.\(id)"), NavigationPosition(latitude: 0, longitude: 0, vertical: .unknown), label: nil),
        ])
    }

    func nextTransition(after reference: RepresentedTime) -> Date? {
        [interval.start, interval.end].filter { $0 > reference.instant }.min()
    }
}

@MainActor
struct TransitionScheduleTests {
    private func drain(until condition: () -> Bool) async throws {
        for _ in 0 ..< 10_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "condition not reached after bounded drain")
    }

    /// A store whose clock is a mutable box and whose waits complete only
    /// when the test releases them.
    private final class Clock: @unchecked Sendable {
        var now: Date
        var releases: [CheckedContinuation<Void, Never>] = []
        init(_ now: Date) { self.now = now }
    }

    private func makeReadyStore(now: Date) async throws -> (NaviMapSceneStore, FakeSurfaceDriver, Clock) {
        let clock = Clock(now)
        let store = NaviMapSceneStore()
        store.now = { clock.now }
        store.sleep = { _ in
            await withCheckedContinuation { continuation in
                clock.releases.append(continuation)
            }
        }
        let driver = FakeSurfaceDriver()
        try await store.attach(driver: driver, host: FakeSurfaceHost())
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { store.reconciler.actual.isSurfaceReady }
        return (store, driver, clock)
    }

    private func markerCount(_ driver: FakeSurfaceDriver, _ id: String) -> Int {
        driver.appliedPlans.flatMap(\.operations).filter {
            if case .upsertEntityMarker(let entity, _, _) = $0, entity == EntityID("bounded.\(id)") { return true }
            return false
        }.count
    }

    private func settle(_ store: NaviMapSceneStore) async throws {
        try await drain { store.reconciler.actual.appliedRevision == store.lastPublishedRevision }
    }

    private let interval = DateInterval(start: Date(timeIntervalSince1970: 1_000), duration: 1_000)

    // Failure paths first: when nothing may be scheduled.

    @Test func nothingIsScheduledWhileACursorIsSet() async throws {
        let (store, _, _) = try await makeReadyStore(now: Date(timeIntervalSince1970: 500))
        store.setTimeline(SceneTimeline(cursor: RepresentedTime(instant: Date(timeIntervalSince1970: 500))))
        store.setComponents([AnySceneComponent(BoundedComponent(id: "a", interval: interval))])
        try await settle(store)
        #expect(store.scheduledTransition == nil)
    }

    @Test func nothingIsScheduledWithoutABoundary() async throws {
        let (store, _, _) = try await makeReadyStore(now: Date(timeIntervalSince1970: 500))
        store.setComponents([AnySceneComponent(BasemapComponent(style: .operational))])
        try await settle(store)
        #expect(store.scheduledTransition == nil)
        // Past every boundary: nothing left to wait for.
        store.now = { Date(timeIntervalSince1970: 5_000) }
        store.setComponents([AnySceneComponent(BoundedComponent(id: "a", interval: interval))])
        try await settle(store)
        #expect(store.scheduledTransition == nil)
    }

    @Test func removingTheComponentCancelsTheWait() async throws {
        let (store, _, clock) = try await makeReadyStore(now: Date(timeIntervalSince1970: 500))
        store.setComponents([AnySceneComponent(BoundedComponent(id: "a", interval: interval))])
        try await settle(store)
        #expect(store.scheduledTransition == interval.start)
        store.setComponents([])
        try await settle(store)
        #expect(store.scheduledTransition == nil)
        // Releasing the old wait must not re-evaluate anything.
        let revision = store.lastPublishedRevision
        for continuation in clock.releases { continuation.resume() }
        clock.releases = []
        await Task.yield()
        #expect(store.lastPublishedRevision == revision)
    }

    // Happy path: one wait per boundary, re-evaluation exactly there.

    @Test func crossingTheBoundaryReevaluatesOnceAndSchedulesTheNext() async throws {
        let (store, driver, clock) = try await makeReadyStore(now: Date(timeIntervalSince1970: 500))
        store.setComponents([AnySceneComponent(BoundedComponent(id: "a", interval: interval))])
        try await settle(store)
        #expect(markerCount(driver, "a") == 0)
        #expect(store.scheduledTransition == interval.start)
        try await drain { clock.releases.count == 1 }

        // The clock reaches the start; the released wait re-evaluates.
        clock.now = interval.start
        let waiting = clock.releases.removeFirst()
        waiting.resume()
        try await drain { store.scheduledTransition == interval.end }
        try await settle(store)
        #expect(markerCount(driver, "a") == 1)
        try await drain { clock.releases.count == 1 }

        // The clock reaches the end; the marker is removed and nothing is
        // left to schedule.
        clock.now = interval.end
        clock.releases.removeFirst().resume()
        try await drain { store.scheduledTransition == nil }
        try await settle(store)
        let removals = driver.appliedPlans.flatMap(\.operations).filter {
            if case .removeEntityMarker(let id) = $0, id == EntityID("bounded.a") { return true }
            return false
        }.count
        #expect(removals == 1)
    }

    @Test func theEarliestBoundaryAcrossComponentsWins() async throws {
        let (store, _, _) = try await makeReadyStore(now: Date(timeIntervalSince1970: 500))
        let later = DateInterval(start: Date(timeIntervalSince1970: 3_000), duration: 100)
        store.setComponents([
            AnySceneComponent(BoundedComponent(id: "late", interval: later)),
            AnySceneComponent(BoundedComponent(id: "soon", interval: interval)),
        ])
        try await settle(store)
        #expect(store.scheduledTransition == interval.start)
    }
}
