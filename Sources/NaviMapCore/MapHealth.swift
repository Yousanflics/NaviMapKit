//
//  MapHealth.swift
//  NaviMapCore
//
//  Health and failure vocabulary. Principle: safety
//  failures are reported explicitly, never silently degraded. v0 populates
//  the surface/capability legs; the content leg's states are defined now
//  (pure values) and filled by the content pipeline.
//

/// Stable identity of an offline/content generation family.
public struct ContentID: Hashable, Sendable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum ContentHealth: Sendable, Equatable {
    case fresh
    case stale
    case expired
    /// Explicit case — absence of freshness metadata is a state, not nil
    case unknown
}

public enum SurfaceLossReason: Sendable, Equatable {
    /// The driver was detached (scene teardown or re-attach).
    case detached
    /// The platform reclaimed the rendering surface.
    case surfaceReclaimed
}

public enum SurfaceDegradationReason: Sendable, Equatable {
    /// Applies acknowledge but slower than the bounded wait; rendering
    /// continues with the last acknowledged state.
    case acknowledgementTimeout
}

public enum SurfaceHealth: Sendable, Equatable {
    case running
    case degraded(SurfaceDegradationReason)
    case lost(SurfaceLossReason)
}

public struct OperationalMapHealth: Sendable, Equatable {
    public var surface: SurfaceHealth
    public var content: [ContentID: ContentHealth]
    public var capabilities: CapabilityReport

    public init(
        surface: SurfaceHealth,
        content: [ContentID: ContentHealth] = [:],
        capabilities: CapabilityReport
    ) {
        self.surface = surface
        self.content = content
        self.capabilities = capabilities
    }
}

/// Operational failures the app must see. v0 carries the
/// cases with live emission paths; `contentActivationFailed` joins with the
/// pipeline so its payload is designed against the real activation
/// machinery, not a placeholder.
/// Why a content generation could not be activated. Shaped by the
/// activation protocol's real failure paths: the render acknowledgement
/// never arrived in the bounded wait, the confirmation itself failed, or
/// validation rejected the generation before activation.
public enum ActivationFailure: Sendable, Equatable {
    case acknowledgementTimedOut
    case confirmationFailed(ActivationConfirmationFailure)
    case rejected(RejectionReason)
}

/// Why validation rejected a generation before activation: the three
/// classes of check every content family performs.
public enum RejectionReason: Error, Sendable, Equatable {
    /// The entry file's digest does not match the manifest.
    case checksum
    /// The manifest is missing or unreadable, or the manifest or the entry
    /// file does not have the family's shape.
    case schema
    /// The content is incomplete against what the manifest declares, or a
    /// feature's geometry is not valid.
    case coverage
}

/// Why the render confirmation of an activated generation failed, typed
/// so the report carries the mechanism rather than a description.
public enum ActivationConfirmationFailure: Sendable, Equatable {
    /// The surface driver rejected or failed to apply the binding plan.
    case applyRejected
    /// The scene epoch changed before the binding was acknowledged
    /// (detach or re-attach); a stale epoch never confirms.
    case epochChanged
    /// No surface was attached when the activation was submitted.
    case surfaceNotAttached
}

/// Why one element of a declared component could not be drawn. Declared
/// content is judged by the component that declares it, not by a content
/// family validator, so it has its own vocabulary.
public enum DeclarationDefect: Sendable, Hashable {
    /// A ring of the element's footprint has fewer than three vertices.
    case degenerateRing
    /// The element's footprint mixes coordinate reference systems.
    case mixedReferenceSystems
    /// The element's address is already used by an earlier element of the
    /// same declaration; the earlier one is drawn, this one is not.
    case duplicateAddress
    /// The element has an empty address. An identity is never made up for
    /// it, so the element is not drawn.
    case emptyAddress
    /// A reported quantity lies outside its meaningful range, for example a
    /// negative ground speed; the element is not drawn.
    case valueOutOfRange
}

public enum MapOperationalIssue: Error, Sendable, Equatable {
    case capabilityIncompatible(component: ComponentID, missing: CapabilitySet)
    case surfaceLost(reason: SurfaceLossReason)
    /// A content generation failed to activate and was rolled back (or
    /// rejected); rendering continues on the previous generation.
    case contentActivationFailed(ContentID, ActivationFailure)
    /// One element of a declared component is malformed and is not drawn;
    /// the component's other elements render as declared. Reported once per
    /// element and defect while the declaration stands.
    case declarationRejected(component: ComponentID, address: String, DeclarationDefect)
    /// A component drew a fallback depiction although the runtime offered
    /// every capability it declared optional. The depiction is reduced,
    /// but no missing capability explains it, so it is a defect of the
    /// component rather than a degradation and is reported as such.
    case unexpectedFallback(component: ComponentID, DegradationFallback)
    /// Two declared components share one identity. The first declared is
    /// kept and every later one is left out of the scene; reported once
    /// while the duplicate persists. A scene-level conflict: neither
    /// component owns the rejection.
    case duplicateComponent(ComponentID)
}
