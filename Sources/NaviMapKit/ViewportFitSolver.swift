//
//  ViewportFitSolver.swift
//  NaviMapKit
//
//  Pure fit math (testable without a surface): positions + padding + view
//  size → CameraPose. Applications previously hand-rolled this against a
//  provider camera API behind a valid-size wait; here the math is SDK-owned
//  and the wait is the coordinator's gate.
//
//  v0 limitation (documented): the bounding box is computed on raw
//  longitudes — a route crossing the antimeridian fits the long way around.
//  Flagged for the navigation phase where dateline-aware framing
//  becomes a requirement.
//

import Foundation
import NaviMapCore

package enum ViewportFitSolver {
    /// Meters per degree of latitude (spherical approximation).
    private static let metersPerDegreeLatitude = 111_320.0

    /// Returns nil when the fit cannot be computed (no positions, or the
    /// view has no real size yet — callers gate on layout).
    package static func pose(
        for fit: ViewportFit,
        viewWidth: Double,
        viewHeight: Double
    ) -> CameraPose? {
        guard viewWidth > 0, viewHeight > 0, !fit.positions.isEmpty else { return nil }

        let coordinates = fit.positions.map(\.horizontal)
        let minLat = coordinates.map(\.latitude).min()!
        let maxLat = coordinates.map(\.latitude).max()!
        let minLon = coordinates.map(\.longitude).min()!
        let maxLon = coordinates.map(\.longitude).max()!
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let center = NavigationPosition(
            latitude: centerLat, longitude: centerLon, vertical: .unknown
        )

        // Padding reduces the available viewport; the resulting pose carries
        // zero padding so the inset is not applied twice.
        let availableWidth = viewWidth - fit.padding.leading - fit.padding.trailing
        let availableHeight = viewHeight - fit.padding.top - fit.padding.bottom
        guard availableWidth > 0, availableHeight > 0 else { return nil }

        let latSpanMeters = (maxLat - minLat) * metersPerDegreeLatitude
        let lonSpanMeters = (maxLon - minLon) * metersPerDegreeLatitude
            * cos(centerLat * .pi / 180)

        var metersPerPoint = max(
            latSpanMeters / availableHeight,
            lonSpanMeters / availableWidth
        )
        // No fittable extent (single or coincident positions): explicit
        // fallback, never a degenerate zero-scale fit.
        if !metersPerPoint.isFinite || metersPerPoint <= 0 {
            metersPerPoint = fit.fallbackScale.metersPerPoint
        }
        if let closest = fit.closestScale {
            metersPerPoint = max(metersPerPoint, closest.metersPerPoint)
        }

        return CameraPose(
            center: center,
            scale: MapScale(metersPerPoint: metersPerPoint),
            bearing: .north
        )
    }
}
