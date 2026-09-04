//
//  DeclarationRejectionTests.swift
//  NaviMapKitTests
//
//  A malformed element of a declared component is announced exactly when it
//  is left out of the depiction: once per element and defect while the
//  declaration stands, again if it is removed and declared again, and never
//  for elements that are drawn.
//

import Foundation
import NaviMapCore
@testable import NaviMapKit
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing

/// Declares elements by address; the malformed ones are left out.
private struct ElementsComponent: SceneComponent {
    var id: String
    var rejected: [RejectedDeclaration]
    var drawn: [String]

    var componentID: ComponentID { ComponentID("test.elements.\(id)") }
    var definitionSignature: DefinitionSignature {
        DefinitionSignature("elements/\(id)/\(drawn.joined(separator: ","))/\(rejected.map(\.address).joined(separator: ","))")
    }

    var presentation: PresentationFragment {
        PresentationFragment(
            operations: drawn.map { .upsertEntityMarker(EntityID("\(id).\($0)"), NavigationPosition(latitude: 0, longitude: 0, vertical: .unknown), label: nil) },
            rejectedDeclarations: rejected
        )
    }
}

@MainActor
struct DeclarationRejectionTests {
    private func drain(until condition: () -> Bool) async throws {
        for _ in 0 ..< 10_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "condition not reached after bounded drain")
    }

    private func makeReadyStore() async throws -> NaviMapSceneStore {
        let store = NaviMapSceneStore()
        let driver = FakeSurfaceDriver()
        try await store.attach(driver: driver, host: FakeSurfaceHost())
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { store.reconciler.actual.isSurfaceReady }
        return store
    }

    private let degenerate = RejectedDeclaration(address: "bad-ring", defect: .degenerateRing)
    private let mixed = RejectedDeclaration(address: "mixed-crs", defect: .mixedReferenceSystems)

    // Failure paths first: what must be announced, and only that.

    @Test func eachMalformedElementIsAnnouncedOnceWhileDeclared() async throws {
        let store = try await makeReadyStore()
        var announced: [(ComponentID, String, DeclarationDefect)] = []
        store.onDeclarationRejected = { announced.append(($0, $1, $2)) }
        let component = ElementsComponent(id: "a", rejected: [degenerate, mixed], drawn: ["ok"])
        store.setComponents([AnySceneComponent(component)])
        #expect(announced.map(\.1) == ["bad-ring", "mixed-crs"])
        #expect(announced.map(\.2) == [.degenerateRing, .mixedReferenceSystems])
        #expect(announced.allSatisfy { $0.0 == component.componentID })
        // The component is still accepted: its valid element is drawn.
        #expect(store.reconciler.desired?.components.count == 1)
        // Re-declaring the same malformed elements announces nothing new.
        store.setComponents([AnySceneComponent(component)])
        store.setComponents([AnySceneComponent(component)])
        #expect(announced.count == 2)
    }

    @Test func aNewDefectOnAKnownAddressIsAnnouncedAgain() async throws {
        let store = try await makeReadyStore()
        var announced: [DeclarationDefect] = []
        store.onDeclarationRejected = { announced.append($2) }
        store.setComponents([AnySceneComponent(ElementsComponent(id: "a", rejected: [degenerate], drawn: []))])
        store.setComponents([AnySceneComponent(ElementsComponent(
            id: "a", rejected: [RejectedDeclaration(address: "bad-ring", defect: .mixedReferenceSystems)], drawn: []
        ))])
        #expect(announced == [.degenerateRing, .mixedReferenceSystems])
    }

    @Test func removingAndRedeclaringAnnouncesAgain() async throws {
        let store = try await makeReadyStore()
        var count = 0
        store.onDeclarationRejected = { _, _, _ in count += 1 }
        let component = ElementsComponent(id: "a", rejected: [degenerate], drawn: [])
        store.setComponents([AnySceneComponent(component)])
        store.setComponents([])
        store.setComponents([AnySceneComponent(component)])
        #expect(count == 2)
    }

    @Test func fixingTheElementThenBreakingItAnnouncesAgain() async throws {
        let store = try await makeReadyStore()
        var count = 0
        store.onDeclarationRejected = { _, _, _ in count += 1 }
        store.setComponents([AnySceneComponent(ElementsComponent(id: "a", rejected: [degenerate], drawn: []))])
        store.setComponents([AnySceneComponent(ElementsComponent(id: "a", rejected: [], drawn: ["bad-ring"]))])
        store.setComponents([AnySceneComponent(ElementsComponent(id: "a", rejected: [degenerate], drawn: []))])
        #expect(count == 2)
    }

    @Test func aDuplicateIdentityKeepsTheFirstAndIsReportedOnce() async throws {
        let store = try await makeReadyStore()
        var duplicates: [ComponentID] = []
        store.onDuplicateComponent = { duplicates.append($0) }
        var rejections = 0
        store.onDeclarationRejected = { _, _, _ in rejections += 1 }
        let first = ElementsComponent(id: "same", rejected: [], drawn: ["first"])
        let second = ElementsComponent(id: "same", rejected: [], drawn: ["second"])
        store.setComponents([AnySceneComponent(first), AnySceneComponent(second)])
        #expect(store.reconciler.desired?.components.count == 1)
        #expect(store.reconciler.desired?.components.first?.definitionSignature == first.definitionSignature)
        #expect(duplicates == [first.componentID])
        #expect(rejections == 0)
        // Re-declaring the same duplicate announces nothing new; removing it
        // and declaring it again announces again.
        store.setComponents([AnySceneComponent(first), AnySceneComponent(second)])
        #expect(duplicates.count == 1)
        store.setComponents([AnySceneComponent(first)])
        store.setComponents([AnySceneComponent(first), AnySceneComponent(second)])
        #expect(duplicates.count == 2)
    }

    @Test func aDataSourceSnapshotWithDuplicateIdentitiesIsDeduplicatedToo() async throws {
        // The external road carries application snapshots straight in, so
        // it reaches the same tables and is guarded at the same entry.
        let store = try await makeReadyStore()
        var duplicates: [ComponentID] = []
        store.onDuplicateComponent = { duplicates.append($0) }
        let first = ElementsComponent(id: "snap", rejected: [], drawn: ["first"])
        let second = ElementsComponent(id: "snap", rejected: [], drawn: ["second"])
        store.applyExternalSnapshot(NavigationSceneSnapshot(
            epoch: SceneEpoch(attachGeneration: 1, scopeGeneration: 1),
            revision: SceneRevision(7),
            components: [AnySceneComponent(first), AnySceneComponent(second)]
        ))
        #expect(store.reconciler.desired?.components.count == 1)
        #expect(duplicates == [first.componentID])
    }

    @Test func internalReevaluationDoesNotReannounceADuplicate() async throws {
        let store = try await makeReadyStore()
        var duplicates: [ComponentID] = []
        store.onDuplicateComponent = { duplicates.append($0) }
        let first = ElementsComponent(id: "again", rejected: [], drawn: ["first"])
        let second = ElementsComponent(id: "again", rejected: [], drawn: ["second"])
        store.setComponents([AnySceneComponent(first), AnySceneComponent(second)])
        #expect(duplicates.count == 1)
        // A boundary re-evaluation republishes the standing declaration; the
        // application withdrew nothing, so nothing is announced again, and
        // the next producer declaration of the same duplicate stays quiet too.
        store.reevaluate()
        store.reevaluate()
        #expect(duplicates.count == 1)
        store.setComponents([AnySceneComponent(first), AnySceneComponent(second)])
        #expect(duplicates.count == 1)
    }

    @Test func aDeltaFlushBetweenTwoSnapshotsDoesNotReannounceADuplicate() async throws {
        let store = try await makeReadyStore()
        var duplicates: [ComponentID] = []
        store.onDuplicateComponent = { duplicates.append($0) }
        let epoch = SceneEpoch(attachGeneration: 1, scopeGeneration: 1)
        let first = ElementsComponent(id: "snap", rejected: [], drawn: ["first"])
        let second = ElementsComponent(id: "snap", rejected: [], drawn: ["second"])
        let other = ElementsComponent(id: "other", rejected: [], drawn: ["x"])
        store.applyExternalSnapshot(NavigationSceneSnapshot(
            epoch: epoch, revision: SceneRevision(1),
            components: [AnySceneComponent(first), AnySceneComponent(second)]
        ))
        #expect(duplicates.count == 1)
        let published = store.lastPublishedRevision
        #expect(store.applyExternalDelta(NavigationSceneDelta(
            baseRevision: SceneRevision(1), revision: SceneRevision(2),
            changes: [.upsert(AnySceneComponent(other))]
        )))
        try await drain { store.lastPublishedRevision != published }
        #expect(store.reconciler.desired?.components.count == 2)
        store.applyExternalSnapshot(NavigationSceneSnapshot(
            epoch: epoch, revision: SceneRevision(3),
            components: [AnySceneComponent(first), AnySceneComponent(second), AnySceneComponent(other)]
        ))
        #expect(duplicates.count == 1)
    }

    // Happy path.

    @Test func drawnElementsAreNeverAnnounced() async throws {
        let store = try await makeReadyStore()
        var count = 0
        store.onDeclarationRejected = { _, _, _ in count += 1 }
        store.setComponents([AnySceneComponent(ElementsComponent(id: "a", rejected: [], drawn: ["x", "y"]))])
        #expect(count == 0)
    }
}
