//
//  NavigationFeature.swift
//  NaviMapCore
//
//  Typed selection/query results: `didSelect` and
//  `features(at:)` return domain objects, never layer ids or feature JSON.
//  v0 renders exactly one selectable thing — entity markers — so the enum
//  has one case; domain cases (airspace, airport, …) arrive with their
//  components as additive, non-breaking cases.
//

/// A view-space point in points, origin top-left of the map surface.
/// Deliberately not CGPoint: Core stays CoreGraphics-free.
public struct ScreenPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum NavigationFeature: Sendable, Equatable {
    /// A rendered entity marker (v0: the ownship).
    case entity(EntityID)
}
