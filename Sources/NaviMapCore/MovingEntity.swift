//
//  MovingEntity.swift
//  NaviMapCore
//
//  Public v0 moving-entity model: kinematic state with units carried by
//  the types, a memory-only track history, an optional prediction that is
//  structurally absent rather than unknown, and the entity itself. Every
//  quantity that can be unreported has an explicit `.unknown` case; no
//  Optional appears on the public surface.
//

import Foundation

/// What kind of thing an entity is.
public enum EntityKind: Sendable, Equatable {
    case ownship
    case airTraffic
    case vessel
    case uas
    case ground
    case searchAndRescue
}

/// A direction over the ground in degrees true, or unknown. Distinct from
/// the camera bearing type: a reported direction may be unreported, and
/// the depiction must show that rather than assume north.
public enum Direction: Sendable, Equatable {
    /// Degrees clockwise from true north. Any value is accepted and stored
    /// as observed; consumers read it modulo 360. Equality is on the stored
    /// value, so 0 and 360 are equal directions but unequal values: a
    /// report that switches between the two forms counts as a change.
    case degreesTrue(Double)
    case unknown
}

/// Ground speed. Stored in meters per second; constructed from the unit
/// the source reports so no caller converts by hand.
public enum Speed: Sendable, Equatable {
    case metersPerSecond(Double)
    case unknown

    public static func knots(_ value: Double) -> Speed {
        .metersPerSecond(value * 0.514444)
    }

    public static func kilometersPerHour(_ value: Double) -> Speed {
        .metersPerSecond(value / 3.6)
    }
}

/// Rate of climb or descent. Stored in meters per second, positive upward.
public enum VerticalRate: Sendable, Equatable {
    case metersPerSecond(Double)
    case unknown

    public static func feetPerMinute(_ value: Double) -> VerticalRate {
        .metersPerSecond(value * 0.3048 / 60)
    }
}

/// Rate of turn. Stored in degrees per second, positive clockwise.
public enum TurnRate: Sendable, Equatable {
    case degreesPerSecond(Double)
    case unknown
}

/// One observed state of a moving entity. The position carries its own
/// uncertainty and vertical coordinate; heading and course are distinct
/// because their difference is drift, and each may be unknown on its own.
/// The observation time is an `ObservedAt`, never a represented time.
public struct KinematicState: Sendable, Equatable {
    public var position: NavigationPosition
    /// Where the nose points.
    public var heading: Direction
    /// Where the entity is going over the ground.
    public var course: Direction
    public var groundSpeed: Speed
    public var verticalRate: VerticalRate
    public var turnRate: TurnRate
    public var observedAt: ObservedAt

    public init(
        position: NavigationPosition,
        heading: Direction,
        course: Direction,
        groundSpeed: Speed,
        verticalRate: VerticalRate,
        turnRate: TurnRate,
        observedAt: ObservedAt
    ) {
        self.position = position
        self.heading = heading
        self.course = course
        self.groundSpeed = groundSpeed
        self.verticalRate = verticalRate
        self.turnRate = turnRate
        self.observedAt = observedAt
    }
}

/// Past states of an entity, oldest first, held in memory only up to a
/// caller-declared capacity. An empty history is a history with no
/// samples, not an unknown one.
public struct TrackHistory: Sendable, Equatable {
    public private(set) var samples: [KinematicState]
    public let capacity: Int

    public init(capacity: Int, samples: [KinematicState] = []) {
        self.capacity = max(0, capacity)
        self.samples = Array(samples.suffix(self.capacity))
    }

    /// Appends the newest sample, dropping the oldest beyond the capacity.
    /// With capacity zero, as in `.none`, nothing is kept: the sample is
    /// dropped at once rather than accumulated.
    public mutating func append(_ sample: KinematicState) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public static let none = TrackHistory(capacity: 0)
}

/// A prediction of where an entity will be, supplied by the application.
/// `.none` means no prediction is offered, a structural absence; it is not
/// a prediction of unknown value. The SDK never extrapolates a position
/// itself: it draws what it is told.
public enum PredictedPath: Sendable, Equatable {
    case none
    case declared([NavigationPosition])
}

/// A moving entity: identity, kind, current state, history, and
/// prediction. Data age is the state's observation time; position
/// uncertainty is the position's own.
public struct MovingEntity: Sendable, Equatable {
    public var id: EntityID
    public var kind: EntityKind
    public var state: KinematicState
    public var track: TrackHistory
    public var prediction: PredictedPath

    public init(
        id: EntityID,
        kind: EntityKind,
        state: KinematicState,
        track: TrackHistory = .none,
        prediction: PredictedPath = .none
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.track = track
        self.prediction = prediction
    }
}

/// Ages at which a reported entity is shown as stale and at which it is
/// dropped. There is no default: no age is generally safe to keep drawing
/// traffic, so the application states both.
public struct StalenessPolicy: Sendable, Equatable {
    public var staleAfter: Duration
    public var dropAfter: Duration

    public init(staleAfter: Duration, dropAfter: Duration) {
        self.staleAfter = staleAfter
        self.dropAfter = dropAfter
    }
}
