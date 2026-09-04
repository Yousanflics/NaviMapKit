//
//  NavigationScene.swift
//  NaviMapScene
//
//  Public v0 snapshot/delta shapes: pure Sendable values —
//  the only forms that cross actors. Epoch rejection semantics.
//

import Foundation
import NaviMapCore

/// Value-semantic erasure of a scene component.
///
/// Equality is componentID + definitionSignature — exactly the reconciler's
/// judgment inputs. The presentation payload is a Sendable
/// closure and NEVER participates in equality; this `==` is hand-written on
/// purpose and must not be replaced by a synthesized one (the pledge:
/// SwiftFormat's redundantEquatable removed the interim version while the
/// struct was closure-free — with the payload present it is load-bearing).
public struct AnySceneComponent: Sendable, Equatable {
    public var componentID: ComponentID
    public var definitionSignature: DefinitionSignature
    /// Contribution to the render plan, expressed in the provider-neutral
    /// primitives. Parameterized by the scene's current represented-time
    /// cursor and by the capabilities the runtime offers, so the same
    /// function decides both what is drawn and what is reported.
    package var makePresentation: @Sendable (RepresentedTime?, CapabilitySet) -> PresentationFragment
    /// Cursor-parameterized signature derivation. `definitionSignature`
    /// stores the base (realtime) evaluation and remains the equality
    /// basis; the engine re-derives via this closure when the cursor moves,
    /// so temporal components reconcile through the ordinary signature
    /// rule — never a bypass.
    package var makeSignature: @Sendable (RepresentedTime?) -> DefinitionSignature
    /// The next instant after a reference at which the erased component's
    /// depiction changes on its own; nil when nothing is scheduled.
    package var makeNextTransition: @Sendable (RepresentedTime) -> Date?
    /// The erased component's capability contract.
    package var capabilityRequirement: CapabilityRequirement

    /// Capabilities the erased component needs.
    package var requiredCapabilities: CapabilitySet { capabilityRequirement.required }
    /// Capabilities the erased component draws better with.
    package var optionalCapabilities: CapabilitySet { capabilityRequirement.optional }
    /// The erased component's policy when an optional capability is missing.
    package var degradation: DegradationPolicy { capabilityRequirement.degradation }

    public init(_ component: some SceneComponent) {
        componentID = component.componentID
        definitionSignature = component.definitionSignature
        makePresentation = { component.presentation(at: $0, offering: $1) }
        makeSignature = { component.definitionSignature(at: $0) }
        makeNextTransition = { component.nextTransition(after: $0) }
        capabilityRequirement = component.capabilityRequirement
    }

    package init(
        componentID: ComponentID,
        definitionSignature: DefinitionSignature,
        makePresentation: @escaping @Sendable (RepresentedTime?, CapabilitySet) -> PresentationFragment = { _, _ in PresentationFragment() },
        capabilityRequirement: CapabilityRequirement = .basePrimitives
    ) {
        self.componentID = componentID
        self.definitionSignature = definitionSignature
        self.makePresentation = makePresentation
        makeSignature = { _ in definitionSignature }
        makeNextTransition = { _ in nil }
        self.capabilityRequirement = capabilityRequirement
    }

    /// Publish-time evaluation: a copy whose stored signature is derived at
    /// the given cursor. The reconciler then sees a changed signature for
    /// temporal components and emits an ordinary update.
    package func evaluated(at cursor: RepresentedTime?) -> AnySceneComponent {
        var copy = self
        copy.definitionSignature = makeSignature(cursor)
        return copy
    }

    public static func == (lhs: AnySceneComponent, rhs: AnySceneComponent) -> Bool {
        lhs.componentID == rhs.componentID
            && lhs.definitionSignature == rhs.definitionSignature
    }
}

/// A component's render-plan contribution: the base-primitive operations it
/// wants applied. Capability-extension payloads join later.
public struct PresentationFragment: Sendable, Equatable {
    package var operations: [SceneRenderOp]
    /// The fallback depiction these operations draw, if any. nil means the
    /// full depiction was drawn; it is a structural absence, not an unknown.
    /// The degradation report is derived from this field and nowhere else.
    package var appliedFallback: DegradationFallback?
    /// Declared elements the component left out because they are malformed,
    /// by address. The rejection report is derived from this field and
    /// nowhere else, so an element is reported exactly when it is not drawn.
    package var rejectedDeclarations: [RejectedDeclaration]

    package init(
        operations: [SceneRenderOp] = [],
        appliedFallback: DegradationFallback? = nil,
        rejectedDeclarations: [RejectedDeclaration] = []
    ) {
        self.operations = operations
        self.appliedFallback = appliedFallback
        self.rejectedDeclarations = rejectedDeclarations
    }

    /// Components with no direct render contribution (pure state carriers).
    public static let empty = PresentationFragment()
}

/// One malformed element of a declared component: its address within the
/// declaration and the defect that keeps it from being drawn.
package struct RejectedDeclaration: Sendable, Hashable {
    package var address: String
    package var defect: DeclarationDefect

    package init(address: String, defect: DeclarationDefect) {
        self.address = address
        self.defect = defect
    }
}

/// Scene-level mirror of the runtime's base primitives, kept in Scene so
/// components do not depend on the Runtime layer (dependency direction:
/// Runtime depends on Scene). RenderPlanExecutor translates these 1:1.
package enum SceneRenderOp: Sendable, Equatable {
    case setBasemapOperational
    /// Marker keyed by id; an optional text label renders alongside (the
    /// entity-marker primitive extended by explicit decision).
    case upsertEntityMarker(EntityID, NavigationPosition, label: String?)
    case removeEntityMarker(EntityID)
    /// Route/track polyline keyed by its owning component (a base
    /// primitive: every runtime must render polylines).
    case upsertPath(ComponentID, [NavigationPosition])
    case removePath(ComponentID)
    /// Binds a content identity to its activated generation (or to none).
    /// A base primitive by explicit decision: offline authority is a
    /// founding feature, so every runtime must accept the binding.
    case setContentSource(ContentID, ContentSourceLocation)
    /// Filled area keyed per volume within its owning component (a base
    /// primitive by explicit decision: polygon fill is a baseline capability
    /// of every candidate runtime). A component that declares several
    /// volumes emits one operation per volume, so a change to one volume
    /// never re-sends the others.
    case upsertArea(AreaID, PolygonGeometry, AreaStyle)
    case removeArea(AreaID)
}

/// Color in the render plan, components in 0...1.
package struct RenderColor: Sendable, Equatable {
    package var red: Double
    package var green: Double
    package var blue: Double
    package var alpha: Double

    package init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Appearance of a filled area: fill and outline. Text belongs to markers,
/// not to the area itself.
package struct AreaStyle: Sendable, Equatable {
    package var fill: RenderColor
    package var outline: RenderColor
    package var outlineWidth: Double

    package init(fill: RenderColor, outline: RenderColor, outlineWidth: Double) {
        self.fill = fill
        self.outline = outline
        self.outlineWidth = outlineWidth
    }
}

/// Scene-level represented-time cursor. `cursor == nil`
/// means realtime — a structural state, not an unknown.
public struct SceneTimeline: Sendable, Equatable {
    public var cursor: RepresentedTime?

    public init(cursor: RepresentedTime? = nil) {
        self.cursor = cursor
    }

    public static let realtime = SceneTimeline()
}

/// Immutable desired scene state — the only shape that crosses actors.
public struct NavigationSceneSnapshot: Sendable, Equatable {
    public var epoch: SceneEpoch
    public var revision: SceneRevision
    public var components: [AnySceneComponent]
    public var timeline: SceneTimeline

    public init(
        epoch: SceneEpoch,
        revision: SceneRevision,
        components: [AnySceneComponent],
        timeline: SceneTimeline = .realtime
    ) {
        self.epoch = epoch
        self.revision = revision
        self.components = components
        self.timeline = timeline
    }
}

public enum SceneChange: Sendable, Equatable {
    case upsert(AnySceneComponent)
    case remove(ComponentID)
    case timeline(SceneTimeline)
}

/// Incremental change between two revisions. A delta whose `baseRevision`
/// does not match the store's current revision triggers a full-snapshot
/// self-heal — dropped deltas are design-intended behavior
/// under the bounded buffer.
public struct NavigationSceneDelta: Sendable, Equatable {
    public var baseRevision: SceneRevision
    public var revision: SceneRevision
    public var changes: [SceneChange]

    public init(baseRevision: SceneRevision, revision: SceneRevision, changes: [SceneChange]) {
        self.baseRevision = baseRevision
        self.revision = revision
        self.changes = changes
    }
}
