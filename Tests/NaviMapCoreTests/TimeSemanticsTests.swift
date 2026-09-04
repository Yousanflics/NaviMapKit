//
//  TimeSemanticsTests.swift
//  NaviMapCoreTests
//

import Foundation
import NaviMapCore
import Testing

struct TimeSemanticsTests {
    @Test func namedDegradationPreservesTheInstant() {
        // The audit path: explicit, greppable, value-preserving.
        let installed = InstalledAt(instant: Date(timeIntervalSince1970: 64_800))
        let degraded = ObservedAt(assumingObservation: installed)
        #expect(degraded.instant == installed.instant)
    }

    @Test func validityUnknownIsDistinctFromPermanent() {
        // review B2: unknown must never collapse into permanent.
        #expect(ValidityPeriod.unknown != ValidityPeriod.permanent)
        let interval = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3_600)
        #expect(ValidityPeriod.interval(interval) != ValidityPeriod.permanent)
    }

    @Test func temporalExtentNilsCarryStructuralSemantics() {
        // represented == nil → atemporal; cycle == nil → no cycle concept.
        // Both are structural states (Optional discipline), asserted here so
        // a future change to non-optional forms shows up as a test edit.
        let extent = TemporalExtent(validity: .permanent)
        #expect(extent.represented == nil)
        #expect(extent.cycle == nil)
    }

    @Test func freshnessUnknownIsAnExplicitCase() {
        let unknown = DataFreshness.unknown
        #expect(unknown != .current)
        if case .unknown = unknown {} else {
            Issue.record("unknown must be a first-class case")
        }
    }
}
