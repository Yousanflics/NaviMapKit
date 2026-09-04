//
//  TimeSemantics.swift
//  NaviMapCore
//
//  Public v0 time model. Different semantics =
//  different types: implicit cross-semantic flow fails to compile; explicit
//  conversion converges on named inits that are greppable and reviewable
//  (audit, not prohibition — review B1 wording). `.instant` accessors are
//  deliberate, non-removable escape hatches: real observations must be
//  constructible from Date.
//

import Foundation

/// Which moment a presentation represents on the scene timeline.
public struct RepresentedTime: Sendable, Equatable, Hashable {
    public let instant: Date

    public init(instant: Date) {
        self.instant = instant
    }
}

/// When the data was produced by its source.
public struct GeneratedAt: Sendable, Equatable, Hashable {
    public let instant: Date

    public init(instant: Date) {
        self.instant = instant
    }
}

/// When the content was installed on this device. NOT the data's time — the
/// 12:00-generated / 18:00-installed confusion is the founding bug of this
/// type family.
public struct InstalledAt: Sendable, Equatable, Hashable {
    public let instant: Date

    public init(instant: Date) {
        self.instant = instant
    }
}

/// When an observation was actually made.
public struct ObservedAt: Sendable, Equatable, Hashable {
    public let instant: Date

    /// Normal construction from a real observation.
    public init(instant: Date) {
        self.instant = instant
    }

    /// The ONLY named path for degrading an install time into an observation
    /// time. Every call site is visible in diffs and reported by
    /// `scripts/report-time-conversions.sh`.
    public init(assumingObservation installed: InstalledAt) {
        instant = installed.instant
    }
}

/// Business validity. Three explicit states — `nil`-means-permanent is the
/// unknown-as-Optional mistake pointed the unsafe way (review B2).
public enum ValidityPeriod: Sendable, Equatable {
    case permanent
    case interval(DateInterval)
    /// Evaluated conservatively; NEVER treated as `.permanent`.
    case unknown
}

/// Content cycle (AIRAC, chart edition, …).
public struct ContentCycle: Sendable, Equatable, Hashable {
    public var identifier: String
    public var effectiveFrom: Date

    public init(identifier: String, effectiveFrom: Date) {
        self.identifier = identifier
        self.effectiveFrom = effectiveFrom
    }
}

/// Freshness of content relative to its refresh policy. `.unknown` is
/// explicit and rendered conservatively.
public enum DataFreshness: Sendable, Equatable {
    case current
    case stale(since: Date)
    case expired(at: Date)
    case unknown
}

/// Temporal envelope of a component. The Optionals here
/// carry STRUCTURAL nil semantics, documented per the Optional discipline:
/// - `represented == nil` → the component is atemporal (timeline cursor has
///   no effect on it); this is a structural state, not an unknown.
/// - `cycle == nil` → the content has no cycle concept at all.
public struct TemporalExtent: Sendable, Equatable {
    public var validity: ValidityPeriod
    public var represented: RepresentedTime?
    public var cycle: ContentCycle?

    public init(
        validity: ValidityPeriod,
        represented: RepresentedTime? = nil,
        cycle: ContentCycle? = nil
    ) {
        self.validity = validity
        self.represented = represented
        self.cycle = cycle
    }
}
