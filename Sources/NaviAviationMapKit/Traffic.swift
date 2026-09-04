//
//  Traffic.swift
//  NaviAviationMapKit
//
//  Traffic as a streamed collection of moving entities: each emission is
//  the complete set of targets, drawn as labelled markers with any
//  declared predicted path, marked stale and then dropped by the
//  application's staleness policy against the scene's evaluation
//  reference. Malformed targets are left out and reported.
//

import Foundation
import NaviMapCore
import NaviMapKit
import NaviMapScene

/// One traffic target with the application's stable address for it. The
/// address keys the target's render identity within the collection; the
/// entity's own `id` takes no part in identity and is not compared for
/// updates.
public struct TrafficTarget: Sendable, Equatable {
    public var address: String
    public var entity: MovingEntity

    public init(address: String, entity: MovingEntity) {
        self.address = address
        self.entity = entity
    }
}

/// Presentation category of a traffic collection. v0 has one depiction;
/// the type exists so a second can be added without changing call sites.
public enum TrafficAppearance: Sendable, Equatable {
    case standard
}

/// Traffic declared by the application as a stream of whole target sets.
///
/// Each emission replaces the collection: a target absent from the next
/// set is unmounted. A target is drawn as a marker labelled with its
/// address and altitude; a declared predicted path is drawn as a line. A
/// target older than `staleness.staleAfter` at the scene's evaluation
/// reference is labelled stale; one older than `staleness.dropAfter` is
/// not drawn. Unknown altitude, heading, or speed is shown, never
/// filtered. A target with an empty or duplicate address, or a quantity
/// outside its range, is left out and reported through the delegate.
public struct TrafficTargets: Sendable {
    public var id: String
    public var source: AsyncStream<[TrafficTarget]>
    public var staleness: StalenessPolicy
    public var appearance: TrafficAppearance

    public init(
        _ id: String,
        source: AsyncStream<[TrafficTarget]>,
        staleness: StalenessPolicy,
        appearance: TrafficAppearance = .standard
    ) {
        self.id = id
        self.source = source
        self.staleness = staleness
        self.appearance = appearance
    }

    package var element: NavigationSceneElement {
        let id = id
        let staleness = staleness
        let appearance = appearance
        let groups = AsyncStream<[AnySceneComponent]> { continuation in
            let task = Task {
                for await targets in source {
                    continuation.yield(Self.components(for: targets, collectionID: id, staleness: staleness, appearance: appearance))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return NavigationSceneElement(kind: .collectionStream(collectionID: "navimap.collection.traffic.\(id)", groups: groups))
    }

    /// One component per well-formed target, in declaration order. A target
    /// with an empty or duplicate address cannot be given an identity, so
    /// its defect is carried by a stand-in component that draws nothing and
    /// reports the rejection under the collection's own identity.
    package static func components(
        for targets: [TrafficTarget],
        collectionID: String,
        staleness: StalenessPolicy,
        appearance: TrafficAppearance
    ) -> [AnySceneComponent] {
        var components: [AnySceneComponent] = []
        var rejected: [RejectedDeclaration] = []
        var seen: Set<String> = []
        for target in targets {
            if target.address.isEmpty {
                rejected.append(RejectedDeclaration(address: target.address, defect: .emptyAddress))
                continue
            }
            if !seen.insert(target.address).inserted {
                rejected.append(RejectedDeclaration(address: target.address, defect: .duplicateAddress))
                continue
            }
            components.append(AnySceneComponent(TrafficTargetComponent(
                collectionID: collectionID, target: target, staleness: staleness, appearance: appearance
            )))
        }
        if !rejected.isEmpty {
            components.append(AnySceneComponent(TrafficCollectionDefectsComponent(collectionID: collectionID, rejected: rejected)))
        }
        return components
    }
}

public extension NavigationSceneBuilder {
    static func buildExpression(_ traffic: TrafficTargets) -> [NavigationSceneElement] {
        [traffic.element]
    }
}

// MARK: - Components (package)

/// Reports address defects of a traffic collection; draws nothing.
package struct TrafficCollectionDefectsComponent: SceneComponent {
    package var collectionID: String
    package var rejected: [RejectedDeclaration]

    package var componentID: ComponentID { ComponentID("navimap.component.traffic.\(collectionID).defects") }

    package var definitionSignature: DefinitionSignature {
        DefinitionSignature("traffic-defects/\(rejected.map { "\($0.address.utf8.count):\($0.address)/\($0.defect)" }.joined(separator: "|"))")
    }

    package var presentation: PresentationFragment {
        PresentationFragment(rejectedDeclarations: rejected)
    }
}

/// One traffic target. Identity is the collection plus the target's
/// address; the signature covers the declaration except the observation
/// time and the track samples, plus the discrete freshness state derived
/// at the evaluation reference, so a report that changes nothing is a
/// no-op and crossing a staleness boundary is an ordinary update.
package struct TrafficTargetComponent: SceneComponent {
    package var collectionID: String
    package var target: TrafficTarget
    package var staleness: StalenessPolicy
    package var appearance: TrafficAppearance

    package init(collectionID: String, target: TrafficTarget, staleness: StalenessPolicy, appearance: TrafficAppearance) {
        self.collectionID = collectionID
        self.target = target
        self.staleness = staleness
        self.appearance = appearance
    }

    package var componentID: ComponentID {
        ComponentID("navimap.component.traffic.\(collectionID).\(target.address.utf8.count):\(target.address)")
    }

    package var entityID: EntityID {
        EntityID("navimap.entity.traffic.\(collectionID).\(target.address.utf8.count):\(target.address)")
    }

    /// Freshness of the report at the reference. With no reference there is
    /// no age to judge; the report is treated as fresh.
    package enum Freshness: Sendable, Equatable {
        case fresh
        case stale
        case dropped
    }

    package func freshness(at reference: RepresentedTime?) -> Freshness {
        guard let reference else { return .fresh }
        let age = reference.instant.timeIntervalSince(target.entity.state.observedAt.instant)
        if age >= Self.seconds(staleness.dropAfter) { return .dropped }
        if age >= Self.seconds(staleness.staleAfter) { return .stale }
        return .fresh
    }

    /// The reported quantities the depiction cannot make sense of.
    package var defect: DeclarationDefect? {
        let state = target.entity.state
        if case let .metersPerSecond(speed) = state.groundSpeed, speed < 0 { return .valueOutOfRange }
        if case let .declared(path) = target.entity.prediction, path.count == 1 { return .valueOutOfRange }
        return nil
    }

    package var definitionSignature: DefinitionSignature { definitionSignature(at: nil) }

    package func definitionSignature(at reference: RepresentedTime?) -> DefinitionSignature {
        let entity = target.entity
        let state = entity.state
        var canonical = "\(Self.field(collectionID))/\(Self.field(target.address))/\(entity.kind)/\(appearance)/\(freshness(at: reference))"
        canonical += "/\(Self.position(state.position))/\(Self.direction(state.heading))/\(Self.direction(state.course))/\(state.groundSpeed)/\(state.verticalRate)/\(state.turnRate)"
        canonical += "/\(entity.track.capacity)/\(Self.prediction(entity.prediction))/\(staleness.staleAfter)/\(staleness.dropAfter)"
        return DefinitionSignature("traffic/\(Self.fnv1a(canonical))")
    }

    package var presentation: PresentationFragment { presentation(at: nil) }

    package func presentation(at reference: RepresentedTime?) -> PresentationFragment {
        if let defect {
            return PresentationFragment(rejectedDeclarations: [RejectedDeclaration(address: target.address, defect: defect)])
        }
        let freshness = freshness(at: reference)
        guard freshness != .dropped else { return PresentationFragment() }
        var operations: [SceneRenderOp] = [
            .upsertEntityMarker(entityID, target.entity.state.position, label: Self.label(for: target, freshness: freshness)),
        ]
        if case let .declared(path) = target.entity.prediction, path.count >= 2 {
            operations.append(.upsertPath(componentID, path))
        }
        return PresentationFragment(operations: operations)
    }

    /// The next staleness boundary of this report after the reference.
    package func nextTransition(after reference: RepresentedTime) -> Date? {
        let observed = target.entity.state.observedAt.instant
        let boundaries = [
            observed.addingTimeInterval(Self.seconds(staleness.staleAfter)),
            observed.addingTimeInterval(Self.seconds(staleness.dropAfter)),
        ]
        return boundaries.filter { $0 > reference.instant }.min()
    }

    // MARK: Depiction

    package static func label(for target: TrafficTarget, freshness: Freshness) -> String {
        let altitude = switch target.entity.state.position.vertical {
        case let .msl(m): "\(Int(m.converted(to: .feet).value.rounded())) ft"
        case let .agl(m): "\(Int(m.converted(to: .feet).value.rounded())) ft AGL"
        case let .ellipsoidal(m): "\(Int(m.converted(to: .feet).value.rounded())) ft HAE"
        case let .flightLevel(level): "FL\(level)"
        case let .chartDatum(m): "\(Int(m.converted(to: .feet).value.rounded())) ft CD"
        case let .depth(m): "\(Int(m.converted(to: .feet).value.rounded())) ft depth"
        case .unknown: "ALT UNK"
        }
        let suffix = freshness == .stale ? " STALE" : ""
        return "\(target.address) \(altitude)\(suffix)"
    }

    // MARK: Canonical forms

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    private static func field(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }

    private static func position(_ position: NavigationPosition) -> String {
        let vertical = switch position.vertical {
        case let .msl(m): "msl:\(m.converted(to: .meters).value)"
        case let .agl(m): "agl:\(m.converted(to: .meters).value)"
        case let .ellipsoidal(m): "hae:\(m.converted(to: .meters).value)"
        case let .flightLevel(level): "fl:\(level)"
        case let .chartDatum(m): "cd:\(m.converted(to: .meters).value)"
        case let .depth(m): "depth:\(m.converted(to: .meters).value)"
        case .unknown: "unknown"
        }
        return String(format: "%.6f,%.6f,", position.horizontal.latitude, position.horizontal.longitude) + vertical
    }

    /// Directions enter the signature normalized to [0, 360): the stored
    /// value is the observation as reported, but the signature asks whether
    /// the depiction must change, and 0 and 360 point the same way.
    private static func direction(_ direction: Direction) -> String {
        switch direction {
        case let .degreesTrue(degrees):
            let normalized = degrees.truncatingRemainder(dividingBy: 360)
            return String(format: "deg:%.3f", normalized < 0 ? normalized + 360 : normalized)
        case .unknown:
            return "unknown"
        }
    }

    private static func prediction(_ prediction: PredictedPath) -> String {
        switch prediction {
        case .none: "none"
        case let .declared(path): "declared:" + path.map { Self.position($0) }.joined(separator: ";")
        }
    }

    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
