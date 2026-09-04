//
//  AirspaceVolumesTests.swift
//  NaviAviationMapKitTests
//
//  The airspace component leaves malformed volumes out and reports them,
//  keeps the valid ones, evaluates effectivity against the scene cursor,
//  draws unknown bounds and unknown validity conservatively, and records
//  the footprint depiction as the fallback it is.
//

import Foundation
@testable import NaviAviationMapKit
import NaviMapCore
import NaviMapScene
import Testing

private func ring(_ size: Double = 0.1, at origin: (Double, Double) = (37.6, -122.4), crs: CoordinateReferenceSystem = .wgs84) -> HorizontalRing {
    HorizontalRing([
        HorizontalCoordinate(latitude: origin.0, longitude: origin.1, crs: crs),
        HorizontalCoordinate(latitude: origin.0, longitude: origin.1 + size, crs: crs),
        HorizontalCoordinate(latitude: origin.0 + size, longitude: origin.1 + size, crs: crs),
        HorizontalCoordinate(latitude: origin.0 + size, longitude: origin.1, crs: crs),
    ])
}

private func volume(
    ring: HorizontalRing = ring(),
    lower: VerticalCoordinate = .msl(.init(value: 0, unit: .feet)),
    upper: VerticalCoordinate = .flightLevel(100),
    validity: ValidityPeriod = .permanent,
    quality: DataQuality = .authoritative
) -> NavigationVolume {
    NavigationVolume(
        footprint: .polygon(PolygonGeometry(outer: ring)),
        lower: lower, upper: upper,
        effectivity: TemporalExtent(validity: validity),
        mode: .exclusion, quality: quality
    )
}

struct AirspaceVolumesTests {
    private func component(_ volumes: [AirspaceVolume], capability: DegradationPolicy = .allow(fallback: .footprintWithAltitudeLabels)) -> AirspaceVolumesComponent {
        AirspaceVolumesComponent(id: "sfo", volumes: volumes, appearance: .controlled, capability: capability)
    }

    private func drawnAddresses(_ fragment: PresentationFragment) -> [String] {
        fragment.operations.compactMap {
            if case let .upsertArea(id, _, _) = $0 { return id.address }
            return nil
        }
    }

    private func labels(_ fragment: PresentationFragment) -> [String] {
        fragment.operations.compactMap {
            if case let .upsertEntityMarker(_, _, label) = $0 { return label }
            return nil
        }
    }

    // Failure paths first.

    @Test func malformedVolumesAreLeftOutAndReportedWhileValidOnesDraw() {
        let twoPoints = HorizontalRing([
            HorizontalCoordinate(latitude: 37.6, longitude: -122.4),
            HorizontalCoordinate(latitude: 37.7, longitude: -122.4),
        ])
        let mixed = HorizontalRing([
            HorizontalCoordinate(latitude: 37.6, longitude: -122.4),
            HorizontalCoordinate(latitude: 37.6, longitude: -122.3, crs: .identified("EPSG:32610")),
            HorizontalCoordinate(latitude: 37.7, longitude: -122.3),
        ])
        let fragment = component([
            AirspaceVolume(address: "core", volume: volume()),
            AirspaceVolume(address: "", volume: volume()),
            AirspaceVolume(address: "core", volume: volume(ring: ring(0.5))),
            AirspaceVolume(address: "line", volume: volume(ring: twoPoints)),
            AirspaceVolume(address: "mixed", volume: volume(ring: mixed)),
            AirspaceVolume(address: "shelf", volume: volume(ring: ring(0.2))),
        ]).presentation(at: nil, offering: .basePrimitives)
        #expect(drawnAddresses(fragment) == ["core", "shelf"])
        #expect(fragment.rejectedDeclarations == [
            RejectedDeclaration(address: "", defect: .emptyAddress),
            RejectedDeclaration(address: "core", defect: .duplicateAddress),
            RejectedDeclaration(address: "line", defect: .degenerateRing),
            RejectedDeclaration(address: "mixed", defect: .mixedReferenceSystems),
        ])
        // The duplicate that was kept is the first one declared.
        let kept = fragment.operations.compactMap { op -> PolygonGeometry? in
            if case let .upsertArea(id, geometry, _) = op, id.address == "core" { return geometry }
            return nil
        }
        #expect(kept == [PolygonGeometry(outer: ring())])
    }

    @Test func volumeOutsideTheCursorIsNotDrawnAndNotReported() {
        let past = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3_600)
        let component = component([
            AirspaceVolume(address: "expired", volume: volume(validity: .interval(past))),
            AirspaceVolume(address: "always", volume: volume()),
        ])
        let cursor = RepresentedTime(instant: Date(timeIntervalSince1970: 86_400))
        let fragment = component.presentation(at: cursor, offering: .basePrimitives)
        #expect(drawnAddresses(fragment) == ["always"])
        #expect(fragment.rejectedDeclarations.isEmpty)
        // Half-open: drawn at the start instant, no longer drawn at the end.
        #expect(drawnAddresses(component.presentation(at: RepresentedTime(instant: past.start), offering: .basePrimitives)) == ["expired", "always"])
        #expect(drawnAddresses(component.presentation(at: RepresentedTime(instant: past.end), offering: .basePrimitives)) == ["always"])
        let inside = component.presentation(at: RepresentedTime(instant: Date(timeIntervalSince1970: 1_800)), offering: .basePrimitives)
        #expect(drawnAddresses(inside) == ["expired", "always"])
        // The drawn set changing with the cursor is a signature change.
        #expect(component.definitionSignature(at: cursor) != component.definitionSignature(at: RepresentedTime(instant: Date(timeIntervalSince1970: 1_800))))
    }

    @Test func unknownValidityAndUnknownBoundsAreDrawn() {
        let fragment = component([
            AirspaceVolume(address: "when", volume: volume(validity: .unknown)),
            AirspaceVolume(address: "floor", volume: volume(lower: .unknown, upper: .unknown)),
        ]).presentation(at: RepresentedTime(instant: Date()), offering: .basePrimitives)
        #expect(drawnAddresses(fragment) == ["when", "floor"])
        #expect(labels(fragment) == ["SFC - FL100", "UNK - UNK"])
    }

    @Test func notYetEffectiveVolumeIsNotDrawnEither() {
        let future = DateInterval(start: Date(timeIntervalSince1970: 10_000), duration: 3_600)
        let component = component([AirspaceVolume(address: "soon", volume: volume(validity: .interval(future)))])
        let before = component.presentation(at: RepresentedTime(instant: Date(timeIntervalSince1970: 5_000)), offering: .basePrimitives)
        #expect(drawnAddresses(before).isEmpty)
        #expect(before.rejectedDeclarations.isEmpty)
        let during = component.presentation(at: RepresentedTime(instant: Date(timeIntervalSince1970: 12_000)), offering: .basePrimitives)
        #expect(drawnAddresses(during) == ["soon"])
    }

    @Test func missingReferenceExcludesNothing() {
        // The store always supplies a reference; without one there is no
        // instant to judge against, so the interval is treated as unknown.
        let past = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3_600)
        let fragment = component([
            AirspaceVolume(address: "expired", volume: volume(validity: .interval(past))),
        ]).presentation(at: nil, offering: .basePrimitives)
        #expect(drawnAddresses(fragment) == ["expired"])
    }

    @Test func nextTransitionIsTheEarliestBoundaryAfterTheReference() {
        let first = DateInterval(start: Date(timeIntervalSince1970: 1_000), duration: 1_000)
        let second = DateInterval(start: Date(timeIntervalSince1970: 1_500), duration: 100)
        let component = component([
            AirspaceVolume(address: "a", volume: volume(validity: .interval(first))),
            AirspaceVolume(address: "b", volume: volume(validity: .interval(second))),
            AirspaceVolume(address: "c", volume: volume()),
        ])
        #expect(component.nextTransition(after: RepresentedTime(instant: Date(timeIntervalSince1970: 0))) == first.start)
        #expect(component.nextTransition(after: RepresentedTime(instant: Date(timeIntervalSince1970: 1_200))) == second.start)
        #expect(component.nextTransition(after: RepresentedTime(instant: Date(timeIntervalSince1970: 1_550))) == second.end)
        #expect(component.nextTransition(after: RepresentedTime(instant: Date(timeIntervalSince1970: 1_700))) == first.end)
        #expect(component.nextTransition(after: RepresentedTime(instant: Date(timeIntervalSince1970: 9_000))) == nil)
        #expect(self.component([AirspaceVolume(address: "c", volume: volume())]).nextTransition(after: RepresentedTime(instant: Date())) == nil)
    }

    // Happy paths.

    @Test func footprintIsRecordedAsTheFallbackWithoutVolumeRendering() {
        let component = component([AirspaceVolume(address: "core", volume: volume())])
        let base = component.presentation(at: nil, offering: .basePrimitives)
        #expect(base.appliedFallback == .footprintWithAltitudeLabels)
        let volumetric = component.presentation(at: nil, offering: CapabilitySet(.surface, .camera, .vectorRendering, .entityMarkers, .volumeRendering))
        #expect(volumetric.appliedFallback == nil)
        #expect(component.capabilityRequirement == CapabilityRequirement(
            required: .basePrimitives, optional: CapabilitySet(.volumeRendering),
            degradation: .allow(fallback: .footprintWithAltitudeLabels)
        ))
        #expect(self.component([], capability: .forbid).capabilityRequirement.degradation == .forbid)
    }

    @Test func signatureCoversEveryFieldAndOrder() {
        let a = component([AirspaceVolume(address: "core", volume: volume())])
        #expect(a.definitionSignature == component([AirspaceVolume(address: "core", volume: volume())]).definitionSignature)
        #expect(a.definitionSignature != component([AirspaceVolume(address: "core", volume: volume(upper: .flightLevel(180)))]).definitionSignature)
        #expect(a.definitionSignature != component([AirspaceVolume(address: "core", volume: volume(lower: .unknown))]).definitionSignature)
        #expect(a.definitionSignature != component([AirspaceVolume(address: "core", volume: volume(quality: .advisory))]).definitionSignature)
        #expect(a.definitionSignature != component([AirspaceVolume(address: "other", volume: volume())]).definitionSignature)
        #expect(a.definitionSignature != component([AirspaceVolume(address: "core", volume: volume())], capability: .forbid).definitionSignature)
        let ab = component([AirspaceVolume(address: "a", volume: volume()), AirspaceVolume(address: "b", volume: volume(ring: ring(0.2)))])
        let ba = component([AirspaceVolume(address: "b", volume: volume(ring: ring(0.2))), AirspaceVolume(address: "a", volume: volume())])
        #expect(ab.definitionSignature != ba.definitionSignature)
        #expect(drawnAddresses(ba.presentation(at: nil, offering: .basePrimitives)) == ["b", "a"])
    }

    @Test func depictionDerivesTemporaryAndAdvisoryFromTheVolume() {
        let interval = DateInterval(start: Date(), duration: 3_600)
        let permanent = AirspaceVolumesComponent.style(for: volume(), appearance: .restricted)
        let temporary = AirspaceVolumesComponent.style(for: volume(validity: .interval(interval)), appearance: .restricted)
        let advisory = AirspaceVolumesComponent.style(for: volume(quality: .advisory), appearance: .restricted)
        #expect(temporary.outlineWidth > permanent.outlineWidth)
        #expect(advisory.fill.alpha < permanent.fill.alpha)
        #expect(AirspaceVolumesComponent.style(for: volume(), appearance: .controlled).fill != permanent.fill)
        #expect(AirspaceVolumesComponent.altitudeLabel(lower: .msl(.init(value: 1_200, unit: .feet)), upper: .agl(.init(value: 500, unit: .feet))) == "1200 ft - 500 ft AGL")
        let label = AirspaceVolumesComponent.labelPosition(of: PolygonGeometry(outer: ring()))
        #expect(abs(label.horizontal.latitude - 37.65) < 1e-9)
        #expect(abs(label.horizontal.longitude - -122.35) < 1e-9)
        #expect(label.vertical == .unknown)
    }
}
