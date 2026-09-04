//
//  Capability.swift
//  NaviMapCore
//
//  Typed capability vocabulary. Replaces the
//  interim stringly manifest: capabilities are
//  named constants, sets are a real type with negotiation-shaped operations,
//  and the report is the public negotiation outcome — safety content never
//  degrades silently.
//

/// One runtime capability. Closed vocabulary per minor version: components
/// require capabilities by constant, never by ad-hoc string.
public struct Capability: Hashable, Sendable, RawRepresentable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Base primitives every runtime must support.
    public static let surface = Capability(rawValue: "navimap.capability.surface")
    public static let camera = Capability(rawValue: "navimap.capability.camera")
    public static let vectorRendering = Capability(rawValue: "navimap.capability.vector")
    public static let entityMarkers = Capability(rawValue: "navimap.capability.entity")

    /// True volumetric depiction of a navigation volume. Not part of the
    /// base set: a runtime without it renders a volume as its footprint
    /// with altitude labels when the component allows that fallback.
    public static let volumeRendering = Capability(rawValue: "navimap.capability.volume")
}

/// A reduced depiction a component may draw when an optional capability is
/// missing. Each case names what is actually drawn, so a report of the
/// fallback is a statement about the picture, never a guess.
public enum DegradationFallback: Sendable, Equatable {
    /// The volume's footprint, with its own lower and upper bounds labelled;
    /// no altitude slice is chosen on the user's behalf.
    case footprintWithAltitudeLabels
}

/// What a component permits when an optional capability is missing.
public enum DegradationPolicy: Sendable, Equatable {
    /// Refuse the component and report it as incompatible: nothing is
    /// drawn, and the refusal is the report.
    case forbid
    /// Draw the named fallback and report the component as degraded.
    case allow(fallback: DegradationFallback)
}

/// A component's capability contract: what it cannot do without, what it
/// can do better with, and what happens when the latter is missing.
public struct CapabilityRequirement: Sendable, Equatable {
    public var required: CapabilitySet
    public var optional: CapabilitySet
    public var degradation: DegradationPolicy

    public init(required: CapabilitySet, optional: CapabilitySet = CapabilitySet(), degradation: DegradationPolicy = .forbid) {
        self.required = required
        self.optional = optional
        self.degradation = degradation
    }

    /// The base primitives only, nothing optional: the contract of every
    /// v0 component that predates capability extensions.
    public static let basePrimitives = CapabilityRequirement(required: .basePrimitives)
}

public struct CapabilitySet: Hashable, Sendable {
    public var capabilities: Set<Capability>

    public init(_ capabilities: Set<Capability> = []) {
        self.capabilities = capabilities
    }

    public init(_ capabilities: Capability...) {
        self.capabilities = Set(capabilities)
    }

    public var isEmpty: Bool { capabilities.isEmpty }

    public func contains(_ capability: Capability) -> Bool {
        capabilities.contains(capability)
    }

    public func isSuperset(of other: CapabilitySet) -> Bool {
        capabilities.isSuperset(of: other.capabilities)
    }

    /// What `required` needs that this set lacks — the negotiation gap that
    /// becomes a `capabilityIncompatible` issue when non-empty.
    ///
    /// Reading note: the result is the gap RELATIVE TO `required`
    /// (`required − self`), not what `self` is missing in general — the
    /// receiver is the offered set, the argument is the demand.
    public func missing(from required: CapabilitySet) -> CapabilitySet {
        CapabilitySet(required.capabilities.subtracting(capabilities))
    }

    /// The v0 base set (every conforming runtime supports these).
    public static let basePrimitives = CapabilitySet(
        .surface, .camera, .vectorRendering, .entityMarkers
    )
}

/// Public negotiation outcome. v0 components require only
/// base primitives, so live reports are trivially satisfied — the shape is
/// public now so later capability extensions slot in without an API break.
public struct CapabilityReport: Sendable, Equatable {
    /// What the active runtime offers.
    public var supported: CapabilitySet
    /// Components drawn in their fallback depiction, keyed to the optional
    /// capabilities the runtime lacks for them. An entry exists exactly when
    /// the component's presentation reported a fallback: the report is a
    /// projection of what was drawn, not a separate judgement.
    public var degraded: [ComponentID: CapabilitySet]
    /// Components refused at scene construction (fail-fast).
    public var incompatible: [ComponentID: CapabilitySet]

    public init(
        supported: CapabilitySet,
        degraded: [ComponentID: CapabilitySet] = [:],
        incompatible: [ComponentID: CapabilitySet] = [:]
    ) {
        self.supported = supported
        self.degraded = degraded
        self.incompatible = incompatible
    }
}
