//
//  SceneContent.swift
//  NaviMapKit
//
//  Public v0 scene content: NavigationBasemap and
//  Ownship, composed through a result builder. Content values are erased to
//  NavigationSceneElement — an opaque value whose behavior lives behind
//  package access, so the public surface commits to WHAT can be declared,
//  not HOW it renders.
//
//  v0 keeps the builder to concrete `buildExpression` overloads (exactly the
//  frozen content types) instead of a public conformance protocol — the
//  extension point is a deliberate decision, not an accidental v0 API.
//

import NaviMapCore
import NaviMapOffline
import NaviMapScene

/// Opaque, erased scene content item produced by the builder.
public struct NavigationSceneElement: Sendable {
    package enum Kind: Sendable {
        /// A static component: rendered as-declared until the declaration changes.
        case component(AnySceneComponent)
        /// An entity fed by a position stream: the view layer pumps the
        /// stream and re-derives the component per position.
        case entityStream(
            entityID: EntityID,
            positions: AsyncStream<NavigationPosition>,
            makeComponent: @Sendable (NavigationPosition) -> AnySceneComponent
        )
        /// Locally authoritative content: its current activated generation
        /// is bound into the scene by the map's content pipeline.
        case offlineContent(ContentID, ContentAuthority)
        /// A collection fed by a stream of whole groups: each emission is
        /// the complete set of derived components for the collection, so a
        /// member that stops appearing is unmounted with the next group and
        /// the stream itself never enters any signature. When the stream
        /// finishes, the last group stays in the scene; finishing is not an
        /// empty emission.
        case collectionStream(
            collectionID: String,
            groups: AsyncStream<[AnySceneComponent]>
        )
    }

    package var kind: Kind

    package init(kind: Kind) {
        self.kind = kind
    }
}

@resultBuilder
public enum NavigationSceneBuilder {
    public static func buildExpression(_ basemap: NavigationBasemap) -> [NavigationSceneElement] {
        [basemap.element]
    }

    public static func buildExpression(_ ownship: Ownship) -> [NavigationSceneElement] {
        [ownship.element]
    }

    public static func buildExpression(_ path: RoutePath) -> [NavigationSceneElement] {
        [path.element]
    }

    public static func buildExpression(_ overlay: OfflineOverlay) -> [NavigationSceneElement] {
        [overlay.element]
    }

    public static func buildBlock(_ parts: [NavigationSceneElement]...) -> [NavigationSceneElement] {
        parts.flatMap { $0 }
    }

    public static func buildOptional(_ part: [NavigationSceneElement]?) -> [NavigationSceneElement] {
        part ?? []
    }

    public static func buildEither(first: [NavigationSceneElement]) -> [NavigationSceneElement] {
        first
    }

    public static func buildEither(second: [NavigationSceneElement]) -> [NavigationSceneElement] {
        second
    }
}

/// The operational basemap (v0's single style; base primitive).
public struct NavigationBasemap: Sendable {
    public enum Style: Sendable, Equatable {
        case operational
    }

    public var style: Style

    public init(_ style: Style) {
        self.style = style
    }

    package var element: NavigationSceneElement {
        NavigationSceneElement(kind: .component(AnySceneComponent(BasemapComponent(style: style))))
    }
}

/// The scene's own aircraft/vessel/vehicle, fed by any position stream —
/// the SDK never talks to any location framework itself.
public struct Ownship: Sendable {
    public var source: AsyncStream<NavigationPosition>

    public init(source: AsyncStream<NavigationPosition>) {
        self.source = source
    }

    package var element: NavigationSceneElement {
        NavigationSceneElement(kind: .entityStream(
            entityID: .ownship,
            positions: source,
            makeComponent: { position in
                AnySceneComponent(OwnshipComponent(position: position))
            }
        ))
    }
}

/// A route/track polyline through the given positions (admitted to public
/// v0 by the pilot's ideal code). Styling is runtime-default in v0; a
/// styling face is a later decision.
///
/// Endpoint labels: when set, the first/last positions render labeled
/// markers
/// (dot + text) alongside the line.
public struct RoutePath: Sendable {
    public var positions: [NavigationPosition]
    public var startLabel: String?
    public var endLabel: String?

    public init(_ positions: [NavigationPosition], startLabel: String? = nil, endLabel: String? = nil) {
        self.positions = positions
        self.startLabel = startLabel
        self.endLabel = endLabel
    }

    package var element: NavigationSceneElement {
        NavigationSceneElement(kind: .component(
            AnySceneComponent(RoutePathComponent(
                positions: positions, startLabel: startLabel, endLabel: endLabel
            ))
        ))
    }
}

// MARK: - Concrete components (package)

package struct BasemapComponent: SceneComponent {
    package var style: NavigationBasemap.Style

    package var componentID: ComponentID {
        ComponentID("navimap.component.basemap")
    }

    // Hand-built signature over every stored property.
    package var definitionSignature: DefinitionSignature {
        DefinitionSignature("basemap/\(style)")
    }

    package var presentation: PresentationFragment {
        PresentationFragment(operations: [.setBasemapOperational])
    }
}

package struct RoutePathComponent: SceneComponent {
    package var positions: [NavigationPosition]
    package var startLabel: String?
    package var endLabel: String?

    package init(positions: [NavigationPosition], startLabel: String? = nil, endLabel: String? = nil) {
        self.positions = positions
        self.startLabel = startLabel
        self.endLabel = endLabel
    }

    package var componentID: ComponentID {
        ComponentID("navimap.component.routepath")
    }

    /// The signature ENCODES the positions AND the endpoint labels (canonical
    /// digest): a late-resolving route, an edited fix, or a changed endpoint
    /// label is a definition change and must trigger an update — identity
    /// (the id above) and definition equality are separate requirements by
    /// design. The digest is a stable FNV-1a over a fixed-
    /// precision canonical string, deterministic across launches — the
    /// reconciler is never left to guess.
    package var definitionSignature: DefinitionSignature {
        DefinitionSignature(
            "routepath/\(positions.count)/\(Self.canonicalDigest(of: positions))/\(Self.encodeLabel(startLabel))/\(Self.encodeLabel(endLabel))"
        )
    }

    /// Injection-proof label field: length-prefixed so a
    /// label containing the field separator cannot shift fields, with an
    /// explicit nil marker distinct from the empty string. Same signature
    /// discipline as the positions digest — no double standard.
    package static func encodeLabel(_ label: String?) -> String {
        guard let label else { return "nil" }
        return "\(label.utf8.count):\(label)"
    }

    package var presentation: PresentationFragment {
        var operations: [SceneRenderOp] = [.upsertPath(componentID, positions)]
        if let startLabel, let first = positions.first {
            operations.append(.upsertEntityMarker(
                EntityID("navimap.entity.routepath.start"), first, label: startLabel
            ))
        }
        if let endLabel, let last = positions.last, positions.count >= 2 {
            operations.append(.upsertEntityMarker(
                EntityID("navimap.entity.routepath.end"), last, label: endLabel
            ))
        }
        return PresentationFragment(operations: operations)
    }

    package static func canonicalDigest(of positions: [NavigationPosition]) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325 // FNV-1a offset basis
        for position in positions {
            let canonical = String(
                format: "%.6f,%.6f;",
                position.horizontal.latitude,
                position.horizontal.longitude
            )
            for byte in canonical.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3 // FNV prime
            }
        }
        return String(hash, radix: 16)
    }
}

package struct OwnshipComponent: SceneComponent {
    package var position: NavigationPosition

    package var componentID: ComponentID {
        ComponentID("navimap.component.ownship")
    }

    // Hand-built signature over every stored property (interim; identity
    // versus definition): position is the whole definition, so every field
    // participates.
    package var definitionSignature: DefinitionSignature {
        let h = position.horizontal
        return DefinitionSignature(
            "ownship/\(h.latitude)/\(h.longitude)/\(h.crs)/\(position.vertical)/\(position.uncertainty)"
        )
    }

    package var presentation: PresentationFragment {
        PresentationFragment(operations: [.upsertEntityMarker(.ownship, position, label: nil)])
    }
}

/// An offline overlay: locally authoritative GeoJSON content identified by
/// the application. The map renders whichever generation is currently
/// activated for the content identity, reports its freshness against the
/// declared authority policy, and renders nothing until a generation has
/// been staged and activated through the handle's content access.
public struct OfflineOverlay: Sendable {
    public var contentID: ContentID
    public var authority: ContentAuthority

    public init(_ contentID: ContentID, authority: ContentAuthority) {
        self.contentID = contentID
        self.authority = authority
    }

    package var element: NavigationSceneElement {
        NavigationSceneElement(kind: .offlineContent(contentID, authority))
    }
}
