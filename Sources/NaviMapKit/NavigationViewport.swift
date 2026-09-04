//
//  NavigationViewport.swift
//  NaviMapKit
//
//  Public v0 viewport intent. The app
//  states intent — free camera or follow an entity — and the SDK owns the
//  camera. `.frame(...)` (fit-geometry) stays internal draft for now.
//

import NaviMapCore

/// How the camera behaves while following an entity.
public struct FollowConfiguration: Sendable, Equatable {
    public enum Orientation: String, Sendable {
        /// Map stays north-up; the entity marker rotates.
        case northUp
        /// Map rotates so the entity's course points up. Course is derived
        /// from consecutive positions when the source carries no course.
        case courseUp
    }

    public var orientation: Orientation
    /// Scale held while following (~30 m/pt keeps an airport environment in
    /// frame on a tablet; apps override via the memberwise init).
    public var scale: MapScale

    public init(orientation: Orientation, scale: MapScale = MapScale(metersPerPoint: 30)) {
        self.orientation = orientation
        self.scale = scale
    }

    public static let courseUp = FollowConfiguration(orientation: .courseUp)
    public static let northUp = FollowConfiguration(orientation: .northUp)
}

/// Fit-to-positions framing intent (promoted from the
/// `frame()` internal draft by the pilot's ideal code — the minimal shape,
/// not the full geometry framing).
public struct ViewportFit: Sendable, Equatable {
    /// Positions to bring into view. One position centers at
    /// `fallbackScale` (no extent to fit); empty is a no-op intent.
    public var positions: [NavigationPosition]
    public var padding: ViewportPadding
    /// The finest (most zoomed-in) resolution the fit may choose — a floor
    /// on meters/point. Nil = no floor. Named for the reading direction:
    /// "the camera gets no closer than this" (the old provider `maxZoom`
    /// inverted into scale vocabulary reads exactly backwards).
    public var closestScale: MapScale?
    /// Scale used when the positions have no fittable extent (single
    /// position, or all coincident). Explicit field, not a buried constant;
    /// default ≈ the old zoom-9 city-region framing at mid-latitudes.
    public var fallbackScale: MapScale

    public init(
        positions: [NavigationPosition],
        padding: ViewportPadding = .zero,
        closestScale: MapScale? = nil,
        fallbackScale: MapScale = MapScale(metersPerPoint: 120)
    ) {
        self.positions = positions
        self.padding = padding
        self.closestScale = closestScale
        self.fallbackScale = fallbackScale
    }
}

/// Viewport intent — the only public camera vocabulary (the
/// runtime's camera is driver-owned; apps never touch provider cameras).
public enum NavigationViewport: Sendable, Equatable {
    /// App-controlled camera at an explicit pose.
    case free(CameraPose)
    /// SDK-controlled camera tracking an entity (v0: `.ownship`).
    case follow(EntityID, FollowConfiguration)
    /// Frame the given positions. A BINDING INTENT, not a one-shot action:
    /// every time the binding becomes `.fit(f)` the fit recomputes — the
    /// surface-size gate only defers the computation until the view has a
    /// real layout, it never consumes the intent. Priority rule:
    /// an explicit `.fit` beats the persisted-session restore — restore
    /// applies first without animation, then the fit recomputes and takes
    /// over; net effect: fit wins.
    case fit(ViewportFit)
}
