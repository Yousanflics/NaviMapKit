//
//  NavigationPosition.swift
//  NaviMapCore
//
//  Public v0 spatial core. Unknown is an
//  explicit case everywhere — never Optional nil.
//

import Foundation

/// Coordinate reference system, carried explicitly — never implied
public enum CoordinateReferenceSystem: Sendable, Equatable {
    case wgs84
    /// Escape hatch for chart-local or mission-local systems; the identifier
    /// is an EPSG code or a documented profile-specific name.
    case identified(String)
}

public struct HorizontalCoordinate: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var crs: CoordinateReferenceSystem

    public init(latitude: Double, longitude: Double, crs: CoordinateReferenceSystem = .wgs84) {
        self.latitude = latitude
        self.longitude = longitude
        self.crs = crs
    }
}

/// Vertical coordinate with its reference. `.unknown` is an explicit case —
/// a value the safety policy sees, not a nil the app can `if let` away
public enum VerticalCoordinate: Sendable, Equatable {
    case msl(Measurement<UnitLength>)
    case agl(Measurement<UnitLength>)
    case ellipsoidal(Measurement<UnitLength>)
    case flightLevel(Int)
    case chartDatum(Measurement<UnitLength>)
    /// Depth below chart datum; positive downward.
    case depth(Measurement<UnitLength>)
    case unknown
}

/// Vertical accuracy on its own axis. Explicit two-state: a missing vertical
/// accuracy is UNKNOWN, not a structural absence — Optional would let it be
/// `if let`-filtered away.
public enum VerticalAccuracy: Sendable, Equatable {
    case known(Measurement<UnitLength>)
    case unknown
}

/// Horizontal/vertical accuracy. `.unknown` is explicit.
public enum PositionUncertainty: Sendable, Equatable {
    case known(horizontal: Measurement<UnitLength>, vertical: VerticalAccuracy)
    case unknown
}

public struct NavigationPosition: Sendable, Equatable {
    public var horizontal: HorizontalCoordinate
    public var vertical: VerticalCoordinate
    public var uncertainty: PositionUncertainty

    public init(
        horizontal: HorizontalCoordinate,
        vertical: VerticalCoordinate,
        uncertainty: PositionUncertainty
    ) {
        self.horizontal = horizontal
        self.vertical = vertical
        self.uncertainty = uncertainty
    }

    /// Convenience form frozen with the acceptance example (semantics are part of the
    /// freeze): CRS defaults to WGS84 and uncertainty defaults to the
    /// explicit `.unknown` case — defaulted, never silently omitted.
    public init(latitude: Double, longitude: Double, vertical: VerticalCoordinate) {
        self.init(
            horizontal: HorizontalCoordinate(latitude: latitude, longitude: longitude),
            vertical: vertical,
            uncertainty: .unknown
        )
    }
}
