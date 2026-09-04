//
//  NavigationVolumeTests.swift
//  NaviMapCoreTests
//

import Foundation
import NaviMapCore
import Testing

struct NavigationVolumeTests {
    private func square(_ size: Double = 0.1, at origin: (Double, Double) = (37.0, -122.0)) -> HorizontalRing {
        HorizontalRing([
            HorizontalCoordinate(latitude: origin.0, longitude: origin.1),
            HorizontalCoordinate(latitude: origin.0, longitude: origin.1 + size),
            HorizontalCoordinate(latitude: origin.0 + size, longitude: origin.1 + size),
            HorizontalCoordinate(latitude: origin.0 + size, longitude: origin.1),
        ])
    }

    private func volume(
        lower: VerticalCoordinate = .msl(.init(value: 0, unit: .feet)),
        upper: VerticalCoordinate = .flightLevel(180),
        quality: DataQuality = .authoritative
    ) -> NavigationVolume {
        NavigationVolume(
            footprint: .polygon(PolygonGeometry(outer: square())),
            lower: lower,
            upper: upper,
            effectivity: TemporalExtent(validity: .permanent),
            mode: .exclusion,
            quality: quality
        )
    }

    // Failure paths first: unknown and degenerate declarations must stay
    // explicit and visible before any happy path is asserted.
    @Test func unknownBoundsAreExplicitAndReported() {
        #expect(volume(lower: .unknown).hasUnknownVerticalBound)
        #expect(volume(upper: .unknown).hasUnknownVerticalBound)
        #expect(volume(lower: .unknown, upper: .unknown).hasUnknownVerticalBound)
        #expect(!volume().hasUnknownVerticalBound)
        #expect(DataQuality.unknown == DataQuality.unknown)
        #expect(DataQuality.unknown != .authoritative)
    }

    @Test func degeneracyIsReadableNotRejected() {
        let line = HorizontalRing([
            HorizontalCoordinate(latitude: 37.0, longitude: -122.0),
            HorizontalCoordinate(latitude: 37.1, longitude: -122.0),
        ])
        #expect(line.isDegenerate)
        #expect(!square().isDegenerate)
        #expect(PolygonGeometry(outer: line).isDegenerate)
        #expect(PolygonGeometry(outer: square(), holes: [line]).isDegenerate)
        #expect(!PolygonGeometry(outer: square()).isDegenerate)
        #expect(HorizontalGeometry.polygon(PolygonGeometry(outer: line)).isDegenerate)
        // A degenerate ring still constructs a volume: malformed declarations
        // stay visible to validation instead of vanishing at construction.
        let degenerate = NavigationVolume(
            footprint: .polygon(PolygonGeometry(outer: line)),
            lower: .unknown,
            upper: .unknown,
            effectivity: TemporalExtent(validity: .unknown),
            mode: .exclusion,
            quality: .unknown
        )
        #expect(degenerate.footprint.isDegenerate)
        #expect(degenerate.hasUnknownVerticalBound)
    }

    @Test func mixedReferenceSystemsAreReadableNotRejected() {
        let local = CoordinateReferenceSystem.identified("EPSG:32610")
        let mixedRing = HorizontalRing([
            HorizontalCoordinate(latitude: 37.0, longitude: -122.0),
            HorizontalCoordinate(latitude: 37.0, longitude: -121.9, crs: local),
            HorizontalCoordinate(latitude: 37.1, longitude: -121.9),
        ])
        #expect(mixedRing.hasMixedReferenceSystems)
        #expect(!square().hasMixedReferenceSystems)
        #expect(!HorizontalRing([]).hasMixedReferenceSystems)
        // A hole in another system than the outer ring is mixed even when
        // each ring is internally consistent.
        let localHole = HorizontalRing([
            HorizontalCoordinate(latitude: 37.02, longitude: -121.98, crs: local),
            HorizontalCoordinate(latitude: 37.02, longitude: -121.97, crs: local),
            HorizontalCoordinate(latitude: 37.03, longitude: -121.97, crs: local),
        ])
        #expect(PolygonGeometry(outer: square(), holes: [localHole]).hasMixedReferenceSystems)
        #expect(!PolygonGeometry(outer: square(), holes: [square(0.01, at: (37.02, -121.98))]).hasMixedReferenceSystems)
        #expect(HorizontalGeometry.polygon(PolygonGeometry(outer: mixedRing)).hasMixedReferenceSystems)
        // Still constructs: the property is for validation to read.
        let mixed = NavigationVolume(
            footprint: .polygon(PolygonGeometry(outer: mixedRing)),
            lower: .unknown, upper: .unknown,
            effectivity: TemporalExtent(validity: .unknown),
            mode: .exclusion, quality: .unknown
        )
        #expect(mixed.footprint.hasMixedReferenceSystems)
    }

    @Test func volumesCompareByValueAcrossEveryField() {
        #expect(volume() == volume())
        #expect(volume(upper: .flightLevel(240)) != volume())
        #expect(volume(quality: .advisory) != volume())
        var moved = volume()
        moved.mode = .inclusion
        #expect(moved != volume())
        var later = volume()
        later.effectivity = TemporalExtent(validity: .unknown)
        #expect(later != volume())
    }

    @Test func holesTakePartInEquality() {
        let plain = PolygonGeometry(outer: square())
        let withHole = PolygonGeometry(outer: square(), holes: [square(0.01, at: (37.02, -121.98))])
        #expect(plain != withHole)
        #expect(withHole == PolygonGeometry(outer: square(), holes: [square(0.01, at: (37.02, -121.98))]))
        #expect(HorizontalGeometry.polygon(plain) != .polygon(withHole))
    }

    @Test func effectivityCarriesTheTemporalEnvelope() {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3_600)
        var timed = volume()
        timed.effectivity = TemporalExtent(validity: .interval(interval))
        #expect(timed.effectivity.validity == .interval(interval))
        #expect(timed.effectivity.represented == nil)
        #expect(timed.effectivity.cycle == nil)
    }
}
