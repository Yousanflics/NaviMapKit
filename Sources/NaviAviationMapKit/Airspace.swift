//
//  Airspace.swift
//  NaviAviationMapKit
//
//  Airspace and temporary restrictions as a declared scene component: an
//  ordered collection of navigation volumes, drawn as filled footprints
//  with altitude labels on runtimes without volumetric rendering. Malformed
//  volumes are left out and reported; the valid ones render as declared.
//

import Foundation
import NaviMapCore
import NaviMapKit
import NaviMapScene

/// One volume in an airspace declaration with the application's stable
/// address for it. Declaration order is drawing order; the address keys
/// the volume's render identity so a change to one volume never re-sends
/// the others.
public struct AirspaceVolume: Sendable, Equatable {
    public var address: String
    public var volume: NavigationVolume

    public init(address: String, volume: NavigationVolume) {
        self.address = address
        self.volume = volume
    }
}

/// Presentation category of an airspace collection. Only what is not
/// already carried by the volumes themselves: whether a volume is
/// temporary follows from its effectivity, and its confidence from its
/// data quality, and both shape the depiction without a second declaration.
public enum VolumeAppearance: Sendable, Equatable {
    /// Controlled airspace (for example class B, C, or D).
    case controlled
    /// A restricted area: entry needs permission.
    case restricted
    /// A prohibited area: entry is forbidden.
    case prohibited
    /// A danger area: hazardous activity within.
    case danger
}

/// Airspace and temporary restrictions declared by the application.
///
/// The collection is the unit of lifecycle: its identity is `id`, and a
/// volume joining or leaving the collection is an update. Each volume is
/// drawn as its footprint with its own lower and upper bounds labelled
/// whenever the runtime cannot render volumes; the depiction is reported
/// as degraded, or the whole collection is refused when `capability` is
/// `.forbid`. A volume outside the scene's represented-time cursor is not
/// drawn; one with unknown validity or unknown bounds is drawn. A volume
/// with an empty or duplicate address, a degenerate ring, or mixed
/// coordinate reference systems is not drawn and is reported through the
/// delegate as a rejected declaration, while the other volumes render.
public struct AirspaceVolumes: Sendable {
    public var id: String
    public var volumes: [AirspaceVolume]
    public var appearance: VolumeAppearance
    public var capability: DegradationPolicy

    public init(
        _ id: String,
        volumes: [AirspaceVolume],
        appearance: VolumeAppearance,
        capability: DegradationPolicy = .allow(fallback: .footprintWithAltitudeLabels)
    ) {
        self.id = id
        self.volumes = volumes
        self.appearance = appearance
        self.capability = capability
    }

    package var element: NavigationSceneElement {
        NavigationSceneElement(kind: .component(AnySceneComponent(AirspaceVolumesComponent(
            id: id, volumes: volumes, appearance: appearance, capability: capability
        ))))
    }
}

public extension NavigationSceneBuilder {
    static func buildExpression(_ airspace: AirspaceVolumes) -> [NavigationSceneElement] {
        [airspace.element]
    }
}

// MARK: - Component (package)

package struct AirspaceVolumesComponent: SceneComponent {
    package var id: String
    package var volumes: [AirspaceVolume]
    package var appearance: VolumeAppearance
    package var capability: DegradationPolicy

    package init(id: String, volumes: [AirspaceVolume], appearance: VolumeAppearance, capability: DegradationPolicy) {
        self.id = id
        self.volumes = volumes
        self.appearance = appearance
        self.capability = capability
    }

    package var componentID: ComponentID {
        ComponentID("navimap.component.airspace.\(id)")
    }

    package var capabilityRequirement: CapabilityRequirement {
        CapabilityRequirement(
            required: .basePrimitives,
            optional: CapabilitySet(.volumeRendering),
            degradation: capability
        )
    }

    /// Every stored field enters the signature: a volume whose floor,
    /// ceiling, footprint, effectivity, mode, or quality changes is a
    /// different volume to a pilot, and the depiction must update.
    package var definitionSignature: DefinitionSignature {
        definitionSignature(at: nil)
    }

    package func definitionSignature(at cursor: RepresentedTime?) -> DefinitionSignature {
        var canonical = "airspace/\(Self.field(id))/\(appearance)/\(capability)/\(Self.field(cursorKey(cursor)))"
        for entry in volumes {
            canonical += "|\(Self.field(entry.address));\(Self.canonical(entry.volume))"
        }
        return DefinitionSignature("airspace/\(volumes.count)/\(Self.fnv1a(canonical))")
    }

    package var presentation: PresentationFragment {
        presentation(at: nil, offering: .basePrimitives)
    }

    package func presentation(at cursor: RepresentedTime?) -> PresentationFragment {
        presentation(at: cursor, offering: .basePrimitives)
    }

    package func presentation(at cursor: RepresentedTime?, offering: CapabilitySet) -> PresentationFragment {
        // The footprint depiction is the only one v0 can draw: it is the
        // named fallback whenever volumetric rendering is absent.
        let appliedFallback: DegradationFallback? = offering.contains(.volumeRendering) ? nil : .footprintWithAltitudeLabels
        var operations: [SceneRenderOp] = []
        var rejected: [RejectedDeclaration] = []
        var seen: Set<String> = []
        for entry in volumes {
            if entry.address.isEmpty {
                rejected.append(RejectedDeclaration(address: entry.address, defect: .emptyAddress))
                continue
            }
            if !seen.insert(entry.address).inserted {
                rejected.append(RejectedDeclaration(address: entry.address, defect: .duplicateAddress))
                continue
            }
            let footprint = entry.volume.footprint
            if footprint.isDegenerate {
                rejected.append(RejectedDeclaration(address: entry.address, defect: .degenerateRing))
                continue
            }
            if footprint.hasMixedReferenceSystems {
                rejected.append(RejectedDeclaration(address: entry.address, defect: .mixedReferenceSystems))
                continue
            }
            guard Self.isEffective(entry.volume.effectivity, at: cursor) else { continue }
            guard case let .polygon(polygon) = footprint else { continue }
            let areaID = AreaID(componentID: componentID, address: entry.address)
            operations.append(.upsertArea(areaID, polygon, Self.style(for: entry.volume, appearance: appearance)))
            operations.append(.upsertEntityMarker(
                EntityID("navimap.entity.airspace.\(id).\(entry.address)"),
                Self.labelPosition(of: polygon),
                label: Self.altitudeLabel(lower: entry.volume.lower, upper: entry.volume.upper)
            ))
        }
        return PresentationFragment(operations: operations, appliedFallback: appliedFallback, rejectedDeclarations: rejected)
    }

    // MARK: Effectivity

    /// A volume is drawn unless the reference instant falls outside a known
    /// validity interval: an expired or not-yet-effective restriction is
    /// not drawn, in realtime and in replay alike. Unknown and permanent
    /// validity are drawn. The scene store always supplies the reference
    /// (the cursor, or its clock sampled at publish); a nil reference means
    /// no instant was given at all and is treated as unknown, so nothing is
    /// excluded on its account.
    ///
    /// A validity interval is half-open: effective from its start up to,
    /// but not including, its end, so the instant a restriction ends is
    /// the first instant it is no longer drawn.
    package static func isEffective(_ effectivity: TemporalExtent, at reference: RepresentedTime?) -> Bool {
        guard let reference, case let .interval(interval) = effectivity.validity else { return true }
        return reference.instant >= interval.start && reference.instant < interval.end
    }

    /// The earliest validity boundary after the reference among the
    /// declared volumes: the next instant the drawn set can change.
    package func nextTransition(after reference: RepresentedTime) -> Date? {
        var next: Date?
        for entry in volumes {
            guard case let .interval(interval) = entry.volume.effectivity.validity else { continue }
            for boundary in [interval.start, interval.end] where boundary > reference.instant {
                if next.map({ boundary < $0 }) ?? true { next = boundary }
            }
        }
        return next
    }

    private func cursorKey(_ reference: RepresentedTime?) -> String {
        guard reference != nil else { return "unreferenced" }
        // Only the drawn set depends on the reference, so the signature keys
        // on which volumes are effective rather than on the instant itself.
        return volumes.map { Self.isEffective($0.volume.effectivity, at: reference) ? "1" : "0" }.joined()
    }

    // MARK: Depiction

    package static func style(for volume: NavigationVolume, appearance: VolumeAppearance) -> AreaStyle {
        let (red, green, blue) = switch appearance {
        case .controlled: (0.16, 0.42, 0.87)
        case .restricted: (0.80, 0.25, 0.20)
        case .prohibited: (0.62, 0.05, 0.10)
        case .danger: (0.85, 0.45, 0.05)
        }
        let fillAlpha: Double = volume.quality == .advisory ? 0.12 : 0.25
        let temporary = if case .interval = volume.effectivity.validity { true } else { false }
        return AreaStyle(
            fill: RenderColor(red: red, green: green, blue: blue, alpha: fillAlpha),
            outline: RenderColor(red: red, green: green, blue: blue, alpha: 0.9),
            outlineWidth: temporary ? 2.5 : 1.5
        )
    }

    /// The label sits at the mean of the outer ring's vertices, which is
    /// inside every convex footprint and a stable place for concave ones.
    package static func labelPosition(of polygon: PolygonGeometry) -> NavigationPosition {
        let vertices = polygon.outer.vertices
        let count = Double(vertices.count)
        let latitude = vertices.reduce(0) { $0 + $1.latitude } / count
        let longitude = vertices.reduce(0) { $0 + $1.longitude } / count
        return NavigationPosition(
            horizontal: HorizontalCoordinate(latitude: latitude, longitude: longitude, crs: vertices[0].crs),
            vertical: .unknown,
            uncertainty: .unknown
        )
    }

    /// Lower and upper bounds as a pilot reads them; an unknown bound is
    /// spelled out rather than omitted.
    package static func altitudeLabel(lower: VerticalCoordinate, upper: VerticalCoordinate) -> String {
        "\(text(lower)) - \(text(upper))"
    }

    private static func text(_ vertical: VerticalCoordinate) -> String {
        switch vertical {
        case let .msl(measurement):
            let feet = Int(measurement.converted(to: .feet).value.rounded())
            return feet == 0 ? "SFC" : "\(feet) ft"
        case let .agl(measurement):
            return "\(Int(measurement.converted(to: .feet).value.rounded())) ft AGL"
        case let .ellipsoidal(measurement):
            return "\(Int(measurement.converted(to: .feet).value.rounded())) ft HAE"
        case let .flightLevel(level):
            return "FL\(level)"
        case let .chartDatum(measurement):
            return "\(Int(measurement.converted(to: .feet).value.rounded())) ft CD"
        case let .depth(measurement):
            return "\(Int(measurement.converted(to: .feet).value.rounded())) ft depth"
        case .unknown:
            return "UNK"
        }
    }

    // MARK: Canonical forms

    private static func field(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }

    private static func canonical(_ volume: NavigationVolume) -> String {
        var text = ""
        switch volume.footprint {
        case let .polygon(polygon):
            text += "P" + ring(polygon.outer)
            for hole in polygon.holes { text += "H" + ring(hole) }
        }
        text += ";\(vertical(volume.lower));\(vertical(volume.upper));\(temporal(volume.effectivity));\(volume.mode);\(volume.quality)"
        return text
    }

    private static func ring(_ ring: HorizontalRing) -> String {
        ring.vertices.map { String(format: "%.6f,%.6f,%@", $0.latitude, $0.longitude, crs($0.crs)) }.joined(separator: " ")
    }

    private static func crs(_ crs: CoordinateReferenceSystem) -> String {
        switch crs {
        case .wgs84: "wgs84"
        case let .identified(name): field(name)
        }
    }

    private static func vertical(_ vertical: VerticalCoordinate) -> String {
        switch vertical {
        case let .msl(m): "msl:\(m.converted(to: .meters).value)"
        case let .agl(m): "agl:\(m.converted(to: .meters).value)"
        case let .ellipsoidal(m): "hae:\(m.converted(to: .meters).value)"
        case let .flightLevel(level): "fl:\(level)"
        case let .chartDatum(m): "cd:\(m.converted(to: .meters).value)"
        case let .depth(m): "depth:\(m.converted(to: .meters).value)"
        case .unknown: "unknown"
        }
    }

    private static func temporal(_ extent: TemporalExtent) -> String {
        let validity = switch extent.validity {
        case .permanent: "permanent"
        case .unknown: "unknown"
        case let .interval(interval): "\(interval.start.timeIntervalSince1970)-\(interval.end.timeIntervalSince1970)"
        }
        let represented = extent.represented.map { "\($0.instant.timeIntervalSince1970)" } ?? "none"
        let cycle = extent.cycle.map { "\(field($0.identifier))@\($0.effectiveFrom.timeIntervalSince1970)" } ?? "none"
        return "\(validity)/\(represented)/\(cycle)"
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
