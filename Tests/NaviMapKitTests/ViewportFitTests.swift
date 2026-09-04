//
//  ViewportFitTests.swift
//  NaviMapKitTests
//
//  Pure fit math: span-based scale, padding reduction,
//  the closestScale floor, explicit fallback degeneration, and the gate
//  conditions that must return nil. Plus the RoutePath signature rule —
//  positions ARE the definition.
//

import NaviMapCore
@testable import NaviMapKit
import Testing

struct ViewportFitTests {
    private func position(_ lat: Double, _ lon: Double) -> NavigationPosition {
        NavigationPosition(latitude: lat, longitude: lon, vertical: .unknown)
    }

    @Test func twoPointFitDerivesScaleFromSpan() throws {
        // 1° of latitude ≈ 111,320 m across a 1000×500pt viewport, no padding:
        // latitude span dominates → ~111,320 / 500 ≈ 222.6 m/pt.
        let fit = ViewportFit(positions: [position(37.0, -122.0), position(38.0, -122.0)])
        let pose = try #require(ViewportFitSolver.pose(for: fit, viewWidth: 1000, viewHeight: 500))
        #expect(abs(pose.scale.metersPerPoint - 111_320.0 / 500.0) < 0.5)
        #expect(abs(pose.center.horizontal.latitude - 37.5) < 0.000001)
        #expect(pose.center.horizontal.longitude == -122.0)
        #expect(pose.center.vertical == .unknown)
    }

    @Test func paddingReducesAvailableViewport() throws {
        let bare = ViewportFit(positions: [position(37.0, -122.0), position(38.0, -122.0)])
        let padded = ViewportFit(
            positions: bare.positions,
            padding: .symmetric(horizontal: 56, vertical: 80)
        )
        let barePose = try #require(ViewportFitSolver.pose(for: bare, viewWidth: 1000, viewHeight: 500))
        let paddedPose = try #require(ViewportFitSolver.pose(for: padded, viewWidth: 1000, viewHeight: 500))
        // Less available height (500-160=340) → coarser scale, and the pose
        // itself carries zero padding (no double application).
        #expect(paddedPose.scale.metersPerPoint > barePose.scale.metersPerPoint)
        #expect(abs(paddedPose.scale.metersPerPoint - 111_320.0 / 340.0) < 0.5)
        #expect(paddedPose.padding == .zero)
    }

    @Test func closestScaleIsAFloor() throws {
        // A tiny extent would compute a very fine scale; the floor holds it.
        let fit = ViewportFit(
            positions: [position(37.0, -122.0), position(37.001, -122.0)],
            closestScale: MapScale(metersPerPoint: 40)
        )
        let pose = try #require(ViewportFitSolver.pose(for: fit, viewWidth: 1000, viewHeight: 500))
        #expect(pose.scale.metersPerPoint == 40)
    }

    @Test func singlePositionUsesExplicitFallback() throws {
        let fit = ViewportFit(
            positions: [position(37.6191, -122.3816)],
            fallbackScale: MapScale(metersPerPoint: 99)
        )
        let pose = try #require(ViewportFitSolver.pose(for: fit, viewWidth: 1000, viewHeight: 500))
        #expect(pose.scale.metersPerPoint == 99)
        #expect(pose.center.horizontal.latitude == 37.6191)
    }

    @Test func coincidentPositionsUseFallbackNotZero() throws {
        let fit = ViewportFit(positions: [position(37.0, -122.0), position(37.0, -122.0)])
        let pose = try #require(ViewportFitSolver.pose(for: fit, viewWidth: 1000, viewHeight: 500))
        #expect(pose.scale.metersPerPoint == fit.fallbackScale.metersPerPoint)
    }

    @Test func gateConditionsReturnNil() {
        let fit = ViewportFit(positions: [position(37.0, -122.0), position(38.0, -122.0)])
        #expect(ViewportFitSolver.pose(for: fit, viewWidth: 0, viewHeight: 500) == nil)
        #expect(ViewportFitSolver.pose(for: fit, viewWidth: 1000, viewHeight: 0) == nil)
        #expect(ViewportFitSolver.pose(
            for: ViewportFit(positions: []), viewWidth: 1000, viewHeight: 500
        ) == nil)
        // Padding consuming the whole viewport is a gate, not a crash.
        #expect(ViewportFitSolver.pose(
            for: ViewportFit(positions: fit.positions, padding: .symmetric(horizontal: 600, vertical: 0)),
            viewWidth: 1000, viewHeight: 500
        ) == nil)
    }

    // MARK: RoutePath signature encodes positions

    @Test func routePathSignatureTracksPositions() {
        let a = [position(37.0, -122.0), position(38.0, -121.0)]
        let same = [position(37.0, -122.0), position(38.0, -121.0)]
        let moved = [position(37.0, -122.0), position(38.0, -121.5)]

        let sigA = RoutePathComponent(positions: a).definitionSignature
        #expect(sigA == RoutePathComponent(positions: same).definitionSignature)
        #expect(sigA != RoutePathComponent(positions: moved).definitionSignature)
        // Same identity throughout: a route change is an UPDATE, never a
        // remount.
        #expect(
            RoutePathComponent(positions: a).componentID
                == RoutePathComponent(positions: moved).componentID
        )
    }

    @Test func routePathSignatureEncodesEndpointLabels() {
        let positions = [position(37.0, -122.0), position(38.0, -121.0)]
        let unlabeled = RoutePathComponent(positions: positions)
        let labeled = RoutePathComponent(positions: positions, startLabel: "KSFO", endLabel: "KLAX")
        let relabeled = RoutePathComponent(positions: positions, startLabel: "KSFO", endLabel: "KSAN")
        // Same identity; labels are definition — a
        // changed endpoint label must reconcile as an update.
        #expect(unlabeled.componentID == labeled.componentID)
        #expect(unlabeled.definitionSignature != labeled.definitionSignature)
        #expect(labeled.definitionSignature != relabeled.definitionSignature)
    }

    @Test func labelEncodingResistsInjectionAndNilAmbiguity() {
        let positions = [position(37.0, -122.0), position(38.0, -121.0)]
        // nil vs empty string are different definitions.
        #expect(
            RoutePathComponent(positions: positions, startLabel: nil).definitionSignature
                != RoutePathComponent(positions: positions, startLabel: "").definitionSignature
        )
        // The review's collision pair: a label containing the separator must
        // not shift fields ("X/","" vs "X","/").
        #expect(
            RoutePathComponent(positions: positions, startLabel: "X/", endLabel: "").definitionSignature
                != RoutePathComponent(positions: positions, startLabel: "X", endLabel: "/").definitionSignature
        )
    }

    @Test func routePathPresentationEmitsLabeledEndpoints() {
        let positions = [position(37.0, -122.0), position(38.0, -121.0)]
        let ops = RoutePathComponent(
            positions: positions, startLabel: "KSFO", endLabel: "KLAX"
        ).presentation.operations
        #expect(ops.count == 3)
        #expect(ops.contains(.upsertEntityMarker(
            EntityID("navimap.entity.routepath.start"), positions[0], label: "KSFO"
        )))
        #expect(ops.contains(.upsertEntityMarker(
            EntityID("navimap.entity.routepath.end"), positions[1], label: "KLAX"
        )))
        // Unlabeled route emits only the line; a single-position route never
        // emits an end marker even when labeled.
        #expect(RoutePathComponent(positions: positions).presentation.operations.count == 1)
        #expect(RoutePathComponent(
            positions: [positions[0]], startLabel: "A", endLabel: "B"
        ).presentation.operations.count == 2)
    }

    @Test func canonicalDigestIsDeterministic() {
        let positions = [position(37.619123456, -122.381656789), position(38.5, -121.5)]
        let first = RoutePathComponent.canonicalDigest(of: positions)
        let second = RoutePathComponent.canonicalDigest(of: positions)
        #expect(first == second)
        #expect(!first.isEmpty)
    }
}
