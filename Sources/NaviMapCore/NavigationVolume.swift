//
//  NavigationVolume.swift
//  NaviMapCore
//
//  Public v0 volume model: the single representation for airspace,
//  temporary restrictions, geofences, hazards, and mission corridors. A
//  volume is a horizontal footprint bounded by two vertical coordinates and
//  a temporal envelope. Unknown is an explicit case on every axis where it
//  can occur; no Optional appears on the public surface.
//

import Foundation

/// A closed ring of horizontal coordinates. The ring is implicitly closed:
/// the last vertex connects back to the first, so callers do not repeat
/// the first vertex at the end. All vertices are expected to share one
/// coordinate reference system.
public struct HorizontalRing: Sendable, Equatable {
    public var vertices: [HorizontalCoordinate]

    public init(_ vertices: [HorizontalCoordinate]) {
        self.vertices = vertices
    }

    /// True when the ring has fewer than three vertices. Degeneracy is a
    /// property callers can read; the model does not reject it, so a
    /// declaration that arrives malformed stays visible to validation
    /// rather than disappearing at construction. Area and self-intersection
    /// checks belong to validation, not to the model.
    public var isDegenerate: Bool {
        vertices.count < 3
    }

    /// True when the vertices do not all share one coordinate reference
    /// system. Like degeneracy, a readable property rather than a rejection:
    /// validation decides what to do with a mixed ring.
    public var hasMixedReferenceSystems: Bool {
        guard let first = vertices.first?.crs else { return false }
        return vertices.contains { $0.crs != first }
    }
}

/// A polygon footprint: one outer ring and any number of holes.
public struct PolygonGeometry: Sendable, Equatable {
    public var outer: HorizontalRing
    public var holes: [HorizontalRing]

    public init(outer: HorizontalRing, holes: [HorizontalRing] = []) {
        self.outer = outer
        self.holes = holes
    }

    /// True when the outer ring or any hole has fewer than three vertices.
    public var isDegenerate: Bool {
        outer.isDegenerate || holes.contains { $0.isDegenerate }
    }

    /// True when any ring mixes coordinate reference systems, or when the
    /// rings do not all share the outer ring's system.
    public var hasMixedReferenceSystems: Bool {
        if outer.hasMixedReferenceSystems || holes.contains(where: { $0.hasMixedReferenceSystems }) {
            return true
        }
        guard let reference = outer.vertices.first?.crs else { return false }
        return holes.contains { hole in
            hole.vertices.first.map { $0.crs != reference } ?? false
        }
    }
}

/// Horizontal extent of a volume. v0 carries polygons only; further shapes
/// arrive as new cases.
public enum HorizontalGeometry: Sendable, Equatable {
    case polygon(PolygonGeometry)

    /// True when any ring of the geometry has fewer than three vertices.
    public var isDegenerate: Bool {
        switch self {
        case let .polygon(polygon): polygon.isDegenerate
        }
    }

    /// True when the geometry mixes coordinate reference systems.
    public var hasMixedReferenceSystems: Bool {
        switch self {
        case let .polygon(polygon): polygon.hasMixedReferenceSystems
        }
    }
}

/// Whether a volume admits or excludes navigation.
public enum VolumeMode: Sendable, Equatable {
    /// Navigation inside the volume is the intended state, for example a
    /// mission corridor or a permitted area.
    case inclusion
    /// Navigation inside the volume is restricted or hazardous, for example
    /// controlled airspace, a restricted area, or a geofence.
    case exclusion
}

/// Confidence in the data behind a declaration. `.unknown` is explicit: a
/// declaration whose provenance is not known is still a declaration, and
/// safety policy treats it conservatively rather than filtering it away.
public enum DataQuality: Sendable, Equatable {
    /// Issued by the authority responsible for the data, for example an
    /// aeronautical information publication.
    case authoritative
    /// Informational, derived, or user-supplied; not a basis for compliance.
    case advisory
    case unknown
}

/// A volume in navigation space: footprint, vertical bounds, effectivity,
/// mode, and data quality. Either vertical bound may be `.unknown`; a volume
/// with an unknown bound is treated as potentially relevant at every
/// altitude, never as absent.
public struct NavigationVolume: Sendable, Equatable {
    public var footprint: HorizontalGeometry
    public var lower: VerticalCoordinate
    public var upper: VerticalCoordinate
    public var effectivity: TemporalExtent
    public var mode: VolumeMode
    public var quality: DataQuality

    public init(
        footprint: HorizontalGeometry,
        lower: VerticalCoordinate,
        upper: VerticalCoordinate,
        effectivity: TemporalExtent,
        mode: VolumeMode,
        quality: DataQuality
    ) {
        self.footprint = footprint
        self.lower = lower
        self.upper = upper
        self.effectivity = effectivity
        self.mode = mode
        self.quality = quality
    }

    /// True when either vertical bound is unknown, so altitude-based policy
    /// must keep the volume visible.
    public var hasUnknownVerticalBound: Bool {
        lower == .unknown || upper == .unknown
    }
}
