//
//  Camera.swift
//  NaviMapCore
//
//  Public v0 camera intent types. Provider zoom does not
//  exist here — business code speaks scale / ground resolution; only the
//  internal runtime converts to a provider's zoom. Camera altitude and
//  projection are explicitly deferred to internal draft.
//

import Foundation

/// Map scale as ground resolution. One representation, explicit unit.
public struct MapScale: Sendable, Equatable {
    /// Meters of ground distance per screen point.
    public var metersPerPoint: Double

    public init(metersPerPoint: Double) {
        self.metersPerPoint = metersPerPoint
    }
}

/// True-north referenced bearing in degrees; magnetic conversion lives in the
/// domain profiles, never in Core.
/// Value domain: any Double is accepted and interpreted modulo 360 at use
/// (720° ≡ 0°, -90° ≡ 270°); equality is on the stored raw value.
public struct Bearing: Sendable, Equatable {
    public var degreesTrue: Double

    public init(degreesTrue: Double) {
        self.degreesTrue = degreesTrue
    }

    public static let north = Bearing(degreesTrue: 0)
}

public struct ViewportPadding: Sendable, Equatable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    /// Equal vertical / horizontal insets (the common fit-framing shape).
    /// Labels are mandatory by design: a positional two-value form reads
    /// ambiguously.
    public static func symmetric(horizontal: Double, vertical: Double) -> ViewportPadding {
        ViewportPadding(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
    }

    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static let zero = ViewportPadding()
}

public struct CameraPose: Sendable, Equatable {
    public var center: NavigationPosition
    public var scale: MapScale
    public var bearing: Bearing
    /// Camera tilt from nadir in degrees. Value domain: intent accepts any
    /// non-negative value; the runtime clamps to its capability range at
    /// apply (never a crash, never silent camera jumps beyond the clamp).
    public var pitchDegrees: Double
    public var padding: ViewportPadding

    public init(
        center: NavigationPosition,
        scale: MapScale,
        bearing: Bearing = .north,
        pitchDegrees: Double = 0,
        padding: ViewportPadding = .zero
    ) {
        self.center = center
        self.scale = scale
        self.bearing = bearing
        self.pitchDegrees = pitchDegrees
        self.padding = padding
    }
}

/// Stable identity of a moving entity. `MovingEntity` itself stays internal
/// draft in v0; following the ownship needs no internal type.
public struct EntityID: Hashable, Sendable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// The scene's own aircraft/vessel/vehicle.
    public static let ownship = EntityID("navimap.entity.ownship")
}
