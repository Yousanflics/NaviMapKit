//
//  SceneComponent.swift
//  NaviMapScene
//
//  Public v0 component contract. Identity and
//  definition equality are two independent requirements — deliberately no
//  default deriving one from the other, so the id-only-equality trap cannot
//  be reintroduced by convenience.
//

import Foundation
import NaviMapCore

/// The protocol requires Sendable — a
/// component crosses actors inside snapshots — and carries the presentation
/// requirement so `AnySceneComponent` derives its render contribution from
/// the component instead of a caller-supplied closure.
public protocol SceneComponent: Sendable {
    /// Mount/unmount lifecycle identity. Same id = the same component's
    /// continued existence.
    var componentID: ComponentID { get }
    /// Full-definition signature derived from every stored property; a change
    /// means the component needs an update. Interim: conformances build it
    /// by hand; the macro/codegen derivation lands with the
    /// first public domain components and the exhaustiveness test in
    /// NaviMapTesting.
    var definitionSignature: DefinitionSignature { get }
    /// The component's render-plan contribution (package: the fragment shape
    /// is internal until the primitive set is public).
    var presentation: PresentationFragment { get }
    /// Capabilities this component needs from the runtime.
    /// Defaults to the base primitives; capability-extension components
    /// override. Negotiation is fail-fast at scene construction: an
    /// unsatisfiable component is refused and reported, never
    /// silently dropped.
    var requiredCapabilities: CapabilitySet { get }
    /// The component's full capability contract: required, optional, and
    /// the policy when an optional capability is missing. The single place
    /// a component declares capabilities; `requiredCapabilities` is derived
    /// from it. Defaults to the base primitives with nothing optional.
    var capabilityRequirement: CapabilityRequirement { get }
    /// Presentation given the capabilities the runtime actually offers. A
    /// component that draws a fallback records it in the fragment; that
    /// record is the only source of the degradation report. Defaults to the
    /// cursor-only presentation, which never falls back.
    func presentation(at cursor: RepresentedTime?, offering: CapabilitySet) -> PresentationFragment
    /// The next instant after `reference` at which this component's
    /// depiction changes on its own, for example a validity interval
    /// beginning or ending; nil when nothing is scheduled. Lets a realtime
    /// scene re-evaluate exactly at that boundary and never otherwise.
    func nextTransition(after reference: RepresentedTime) -> Date?

    /// Temporal evaluation: a component whose rendition
    /// depends on the scene's represented-time cursor derives BOTH its
    /// signature and its presentation from the cursor — a cursor move then
    /// reconciles as an ordinary signature-triggered update. Pure functions;
    /// `nil` cursor means realtime. Atemporal components (the default) keep
    /// their cursor-independent forms and never re-render on cursor moves.
    func definitionSignature(at cursor: RepresentedTime?) -> DefinitionSignature
    func presentation(at cursor: RepresentedTime?) -> PresentationFragment
}

public extension SceneComponent {
    /// Atemporal default: the cursor has no effect (a structural property,
    /// not an unknown).
    func definitionSignature(at cursor: RepresentedTime?) -> DefinitionSignature {
        definitionSignature
    }

    func presentation(at cursor: RepresentedTime?) -> PresentationFragment {
        presentation
    }
}

public extension SceneComponent {
    var capabilityRequirement: CapabilityRequirement { .basePrimitives }
    var requiredCapabilities: CapabilitySet { capabilityRequirement.required }

    func presentation(at cursor: RepresentedTime?, offering: CapabilitySet) -> PresentationFragment {
        presentation(at: cursor)
    }

    /// Atemporal default: nothing changes on its own.
    func nextTransition(after reference: RepresentedTime) -> Date? {
        nil
    }
}
