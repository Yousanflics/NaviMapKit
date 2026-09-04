//
//  TrafficTargetsTests.swift
//  NaviAviationMapKitTests
//
//  Traffic targets are drawn as labelled markers, marked stale and then
//  dropped by the staleness policy against the evaluation reference,
//  never filtered for unknown quantities, and left out and reported when
//  malformed. A report that changes nothing is a no-op; crossing a
//  staleness boundary is an ordinary update.
//

import Foundation
@testable import NaviAviationMapKit
import NaviMapCore
import NaviMapScene
import Testing

private let policy = StalenessPolicy(staleAfter: .seconds(15), dropAfter: .seconds(60))

private func entity(
    observedAt: TimeInterval = 1_000,
    vertical: VerticalCoordinate = .flightLevel(350),
    speed: Speed = .knots(450),
    prediction: PredictedPath = .none
) -> MovingEntity {
    MovingEntity(
        id: EntityID("unused"),
        kind: .airTraffic,
        state: KinematicState(
            position: NavigationPosition(latitude: 37.7, longitude: -122.3, vertical: vertical),
            heading: .degreesTrue(270),
            course: .unknown,
            groundSpeed: speed,
            verticalRate: .unknown,
            turnRate: .unknown,
            observedAt: ObservedAt(instant: Date(timeIntervalSince1970: observedAt))
        ),
        prediction: prediction
    )
}

private func at(_ seconds: TimeInterval) -> RepresentedTime {
    RepresentedTime(instant: Date(timeIntervalSince1970: seconds))
}

struct TrafficTargetsTests {
    private func component(_ target: TrafficTarget) -> TrafficTargetComponent {
        TrafficTargetComponent(collectionID: "nearby", target: target, staleness: policy, appearance: .standard)
    }

    private func labels(_ fragment: PresentationFragment) -> [String] {
        fragment.operations.compactMap {
            if case let .upsertEntityMarker(_, _, label) = $0 { return label }
            return nil
        }
    }

    // Failure paths first.

    @Test func staleThenDroppedByAgeAtTheReference() {
        let component = component(TrafficTarget(address: "N123", entity: entity(observedAt: 1_000)))
        #expect(component.freshness(at: at(1_010)) == .fresh)
        #expect(component.freshness(at: at(1_015)) == .stale)
        #expect(component.freshness(at: at(1_059)) == .stale)
        #expect(component.freshness(at: at(1_060)) == .dropped)
        #expect(labels(component.presentation(at: at(1_010))) == ["N123 FL350"])
        #expect(labels(component.presentation(at: at(1_030))) == ["N123 FL350 STALE"])
        #expect(component.presentation(at: at(1_100)).operations.isEmpty)
        #expect(component.presentation(at: at(1_100)).rejectedDeclarations.isEmpty)
        // Freshness is a signature component: crossing a boundary is an update.
        #expect(component.definitionSignature(at: at(1_010)) != component.definitionSignature(at: at(1_030)))
        #expect(component.definitionSignature(at: at(1_030)) != component.definitionSignature(at: at(1_100)))
        #expect(component.nextTransition(after: at(1_000)) == Date(timeIntervalSince1970: 1_015))
        #expect(component.nextTransition(after: at(1_020)) == Date(timeIntervalSince1970: 1_060))
        #expect(component.nextTransition(after: at(1_060)) == nil)
    }

    @Test func malformedTargetsAreLeftOutAndReported() throws {
        let components = TrafficTargets.components(
            for: [
                TrafficTarget(address: "A", entity: entity()),
                TrafficTarget(address: "", entity: entity()),
                TrafficTarget(address: "A", entity: entity(observedAt: 2_000)),
                TrafficTarget(address: "B", entity: entity(speed: .metersPerSecond(-1))),
            ],
            collectionID: "nearby", staleness: policy, appearance: .standard
        )
        #expect(components.count == 3)
        let defects = try #require(components.last?.makePresentation(at(1_001), .basePrimitives).rejectedDeclarations)
        #expect(defects == [
            RejectedDeclaration(address: "", defect: .emptyAddress),
            RejectedDeclaration(address: "A", defect: .duplicateAddress),
        ])
        let negative = components[1].makePresentation(at(1_001), .basePrimitives)
        #expect(negative.operations.isEmpty)
        #expect(negative.rejectedDeclarations == [RejectedDeclaration(address: "B", defect: .valueOutOfRange)])
        // The kept duplicate is the first declared.
        #expect(components[0].definitionSignature == component(TrafficTarget(address: "A", entity: entity())).definitionSignature)
    }

    @Test func unknownAltitudeIsShownNotFiltered() {
        let component = component(TrafficTarget(address: "N1", entity: entity(vertical: .unknown)))
        #expect(labels(component.presentation(at: at(1_001))) == ["N1 ALT UNK"])
    }

    // Happy paths.

    @Test func aReportThatChangesNothingButTimeIsANoOp() {
        let a = component(TrafficTarget(address: "N1", entity: entity(observedAt: 1_000)))
        let b = component(TrafficTarget(address: "N1", entity: entity(observedAt: 1_005)))
        #expect(a.definitionSignature(at: at(1_010)) == b.definitionSignature(at: at(1_010)))
        let moved = component(TrafficTarget(address: "N1", entity: entity(observedAt: 1_005, vertical: .flightLevel(360))))
        #expect(a.definitionSignature(at: at(1_010)) != moved.definitionSignature(at: at(1_010)))
    }

    @Test func directionsAreNormalizedInTheSignatureOnly() {
        func target(_ heading: Direction) -> TrafficTarget {
            var entity = entity()
            entity.state.heading = heading
            return TrafficTarget(address: "N1", entity: entity)
        }
        #expect(target(.degreesTrue(0)).entity != target(.degreesTrue(360)).entity)
        #expect(component(target(.degreesTrue(0))).definitionSignature == component(target(.degreesTrue(360))).definitionSignature)
        #expect(component(target(.degreesTrue(-90))).definitionSignature == component(target(.degreesTrue(270))).definitionSignature)
        #expect(component(target(.degreesTrue(90))).definitionSignature != component(target(.degreesTrue(270))).definitionSignature)
        #expect(component(target(.unknown)).definitionSignature != component(target(.degreesTrue(0))).definitionSignature)
    }

    @Test func declaredPredictionIsDrawnAsAPath() {
        let path = [
            NavigationPosition(latitude: 37.7, longitude: -122.3, vertical: .unknown),
            NavigationPosition(latitude: 37.8, longitude: -122.4, vertical: .unknown),
        ]
        let component = component(TrafficTarget(address: "N1", entity: entity(prediction: .declared(path))))
        let fragment = component.presentation(at: at(1_001))
        #expect(fragment.operations.contains { if case let .upsertPath(id, positions) = $0 { return id == component.componentID && positions == path } else { return false } })
        let single = self.component(TrafficTarget(address: "N2", entity: entity(prediction: .declared([path[0]]))))
        #expect(single.presentation(at: at(1_001)).rejectedDeclarations == [RejectedDeclaration(address: "N2", defect: .valueOutOfRange)])
    }

    @Test func groupsMapEachEmissionToPerTargetComponents() {
        let components = TrafficTargets.components(
            for: [TrafficTarget(address: "X", entity: entity()), TrafficTarget(address: "Y", entity: entity())],
            collectionID: "nearby", staleness: policy, appearance: .standard
        )
        #expect(components.map(\.componentID.rawValue) == [
            "navimap.component.traffic.nearby.1:X",
            "navimap.component.traffic.nearby.1:Y",
        ])
    }
}
