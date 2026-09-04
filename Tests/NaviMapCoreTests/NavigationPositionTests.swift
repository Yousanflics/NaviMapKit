//
//  NavigationPositionTests.swift
//  NaviMapCoreTests
//

import Foundation
import NaviMapCore
import Testing

struct NavigationPositionTests {
    @Test func convenienceInitDefaultsAreTheFrozenSemantics() {
        // Frozen with the acceptance example: CRS=WGS84, uncertainty=.unknown
        // (explicit case, not omitted).
        let position = NavigationPosition(
            latitude: 37.6191,
            longitude: -122.3816,
            vertical: .msl(.init(value: 1_200, unit: .feet))
        )
        #expect(position.horizontal.crs == .wgs84)
        #expect(position.uncertainty == .unknown)
    }

    @Test func verticalUnknownIsExplicitAndComparable() {
        #expect(VerticalCoordinate.unknown == VerticalCoordinate.unknown)
        #expect(VerticalCoordinate.unknown != .flightLevel(350))
    }

    @Test func measurementBackedCasesCompareByValue() {
        let a = VerticalCoordinate.msl(.init(value: 1_200, unit: .feet))
        let b = VerticalCoordinate.msl(.init(value: 1_200, unit: .feet))
        #expect(a == b)
    }
}
