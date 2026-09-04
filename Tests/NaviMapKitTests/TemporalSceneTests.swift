//
//  TemporalSceneTests.swift
//  NaviMapKitTests
//
//  Represented-time semantics: a temporal component's
//  signature and presentation are pure functions of the evaluation
//  reference the store supplies (the cursor, or its clock sampled at
//  publish when the scene is realtime), so a cursor move reconciles as an
//  ORDINARY signature-triggered update — the only path; there is no
//  timeline bypass. Atemporal components are structurally unaffected by
//  cursor motion.
//

import Foundation
import NaviMapCore
@testable import NaviMapKit
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing

/// A component whose rendition depends on the cursor: it renders a marker
/// whose label is the represented instant (e.g. a radar-frame stand-in).
private struct TemporalMarkerComponent: SceneComponent {
    var componentID: ComponentID { ComponentID("test.temporal.marker") }
    var definitionSignature: DefinitionSignature { DefinitionSignature("temporal/realtime") }
    var presentation: PresentationFragment {
        PresentationFragment(operations: [.upsertEntityMarker(
            EntityID("test.temporal"), Self.position, label: "realtime"
        )])
    }

    static let position = NavigationPosition(latitude: 37, longitude: -122, vertical: .unknown)

    func definitionSignature(at cursor: RepresentedTime?) -> DefinitionSignature {
        guard let cursor else { return definitionSignature }
        return DefinitionSignature("temporal/\(cursor.instant.timeIntervalSince1970)")
    }

    func presentation(at cursor: RepresentedTime?) -> PresentationFragment {
        guard let cursor else { return presentation }
        return PresentationFragment(operations: [.upsertEntityMarker(
            EntityID("test.temporal"), Self.position,
            label: "t=\(Int(cursor.instant.timeIntervalSince1970))"
        )])
    }
}

@MainActor
struct TemporalSceneTests {
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

    private func markerOps(_ driver: FakeSurfaceDriver) -> [RenderOp] {
        driver.appliedPlans.flatMap(\.operations).filter {
            if case .upsertEntityMarker = $0 { return true }
            return false
        }
    }

    @Test func cursorMoveUpdatesTemporalComponentThroughSignatureRule() async throws {
        let (store, driver) = try await makeReadyStore()
        store.setComponents([AnySceneComponent(TemporalMarkerComponent())])
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
        let mountedOps = markerOps(driver)
        #expect(mountedOps.count == 1)

        // Move the cursor: the component's signature changes → an ordinary
        // update op carries the cursor-evaluated presentation.
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        store.setTimeline(SceneTimeline(cursor: RepresentedTime(instant: instant)))
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
        let ops = markerOps(driver)
        #expect(ops.count == 2)
        if case .upsertEntityMarker(_, _, let label) = try #require(ops.last) {
            #expect(label == "t=1700000000")
        }

        // The signature the reconciler saw is cursor-derived (the rule, not
        // a bypass): mounted tree carries the temporal signature.
        #expect(
            store.reconciler.mounted[ComponentID("test.temporal.marker")]
                == DefinitionSignature("temporal/1700000000.0")
        )
    }

    @Test func atemporalComponentsIgnoreCursorMoves() async throws {
        let (store, driver) = try await makeReadyStore()
        store.setComponents([AnySceneComponent(BasemapComponent(style: .operational))])
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
        let before = driver.appliedPlans.flatMap(\.operations).count

        store.setTimeline(SceneTimeline(cursor: RepresentedTime(instant: Date(timeIntervalSince1970: 1))))
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
        // A new (empty) plan may apply for the revision, but no component
        // operations re-emit: the atemporal signature did not change.
        let after = driver.appliedPlans.flatMap(\.operations).count
        #expect(after == before)
    }

    @Test func returningToRealtimeEvaluatesAtTheStoreClock() async throws {
        let (store, driver) = try await makeReadyStore()
        store.now = { Date(timeIntervalSince1970: 9_000) }
        store.setComponents([AnySceneComponent(TemporalMarkerComponent())])
        store.setTimeline(SceneTimeline(cursor: RepresentedTime(instant: Date(timeIntervalSince1970: 5))))
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }

        // Realtime is the store's clock sampled at publish, never a missing
        // reference: the component sees an instant in both modes.
        store.setTimeline(.realtime)
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
        if case .upsertEntityMarker(_, _, let label) = try #require(markerOps(driver).last) {
            #expect(label == "t=9000")
        }
        #expect(
            store.reconciler.mounted[ComponentID("test.temporal.marker")]
                == DefinitionSignature("temporal/9000.0")
        )
        #expect(store.publishedReference == RepresentedTime(instant: Date(timeIntervalSince1970: 9_000)))
    }

    @Test func temporalAndAtemporalCoexistUnderCursorMotion() async throws {
        let (store, driver) = try await makeReadyStore()
        store.setComponents([
            AnySceneComponent(BasemapComponent(style: .operational)),
            AnySceneComponent(TemporalMarkerComponent()),
        ])
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
        let basemapOpsBefore = driver.appliedPlans.flatMap(\.operations).filter {
            if case .setBasemap = $0 { return true }
            return false
        }.count

        store.setTimeline(SceneTimeline(cursor: RepresentedTime(instant: Date(timeIntervalSince1970: 9))))
        try await drain {
            store.reconciler.actual.appliedRevision == store.lastPublishedRevision
        }
        // Temporal updated; basemap untouched (mount/update quadrants stay
        // independent under cursor motion).
        let basemapOpsAfter = driver.appliedPlans.flatMap(\.operations).filter {
            if case .setBasemap = $0 { return true }
            return false
        }.count
        #expect(basemapOpsAfter == basemapOpsBefore)
        if case .upsertEntityMarker(_, _, let label) = try #require(markerOps(driver).last) {
            #expect(label == "t=9")
        }
    }
}
