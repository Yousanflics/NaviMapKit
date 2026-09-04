//
//  MovingEntityTests.swift
//  NaviMapCoreTests
//

import Foundation
import NaviMapCore
import Testing

struct MovingEntityTests {
    private func state(
        heading: Direction = .degreesTrue(90),
        speed: Speed = .knots(120),
        observedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> KinematicState {
        KinematicState(
            position: NavigationPosition(latitude: 37.6, longitude: -122.4, vertical: .msl(.init(value: 3_000, unit: .feet))),
            heading: heading,
            course: .degreesTrue(95),
            groundSpeed: speed,
            verticalRate: .feetPerMinute(-500),
            turnRate: .unknown,
            observedAt: ObservedAt(instant: observedAt)
        )
    }

    // Failure paths first: unknown stays explicit and distinct.

    @Test func unknownIsAnExplicitCaseOnEveryQuantity() {
        #expect(Direction.unknown != .degreesTrue(0))
        #expect(Speed.unknown != .metersPerSecond(0))
        #expect(VerticalRate.unknown != .metersPerSecond(0))
        #expect(TurnRate.unknown != .degreesPerSecond(0))
        let partial = state(heading: .unknown, speed: .unknown)
        #expect(partial.heading == .unknown)
        #expect(partial.course == .degreesTrue(95))
        #expect(partial != state())
    }

    @Test func historyIsBoundedAndNeverPersistsBeyondCapacity() {
        var history = TrackHistory(capacity: 2)
        history.append(state(observedAt: Date(timeIntervalSince1970: 1)))
        history.append(state(observedAt: Date(timeIntervalSince1970: 2)))
        history.append(state(observedAt: Date(timeIntervalSince1970: 3)))
        #expect(history.samples.map(\.observedAt.instant.timeIntervalSince1970) == [2, 3])
        #expect(TrackHistory(capacity: 1, samples: [state(observedAt: Date(timeIntervalSince1970: 1)), state()]).samples.count == 1)
        #expect(TrackHistory(capacity: -5).capacity == 0)
        #expect(TrackHistory.none.samples.isEmpty)
    }

    @Test func noPredictionIsStructuralNotUnknown() {
        #expect(PredictedPath.none == .none)
        #expect(PredictedPath.none != .declared([]))
        #expect(MovingEntity(id: EntityID("t1"), kind: .airTraffic, state: state()).prediction == .none)
    }

    // Happy paths.

    @Test func unitsConvertToTheCanonicalStore() {
        #expect(Speed.knots(1) == .metersPerSecond(0.514444))
        #expect(Speed.kilometersPerHour(36) == .metersPerSecond(10))
        if case let .metersPerSecond(rate) = VerticalRate.feetPerMinute(-500) {
            #expect(abs(rate - -2.54) < 1e-9)
        } else {
            Issue.record("feet per minute did not convert")
        }
    }

    @Test func entitiesCompareByValueAcrossEveryField() {
        let a = MovingEntity(id: EntityID("t1"), kind: .airTraffic, state: state())
        #expect(a == MovingEntity(id: EntityID("t1"), kind: .airTraffic, state: state()))
        #expect(a != MovingEntity(id: EntityID("t2"), kind: .airTraffic, state: state()))
        #expect(a != MovingEntity(id: EntityID("t1"), kind: .vessel, state: state()))
        #expect(a != MovingEntity(id: EntityID("t1"), kind: .airTraffic, state: state(observedAt: Date(timeIntervalSince1970: 2_000))))
        #expect(a != MovingEntity(id: EntityID("t1"), kind: .airTraffic, state: state(), prediction: .declared([])))
        let policy = StalenessPolicy(staleAfter: .seconds(15), dropAfter: .seconds(60))
        #expect(policy == StalenessPolicy(staleAfter: .seconds(15), dropAfter: .seconds(60)))
        #expect(policy != StalenessPolicy(staleAfter: .seconds(15), dropAfter: .seconds(90)))
    }
}
