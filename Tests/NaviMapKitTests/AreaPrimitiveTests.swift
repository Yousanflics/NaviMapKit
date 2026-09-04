//
//  AreaPrimitiveTests.swift
//  NaviMapKitTests
//
//  Area primitive through the executor and the fake driver: areas are keyed
//  per volume, so an update that drops one volume removes only that one,
//  unmount and convergence remove exactly what the ledger holds, and a
//  surface reset forgets everything.
//

import Foundation
import NaviMapCore
@testable import NaviMapKit
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing

private let areaStyle = AreaStyle(
    fill: RenderColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 0.3),
    outline: RenderColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1),
    outlineWidth: 1.5
)

private func square(_ size: Double = 0.1) -> PolygonGeometry {
    PolygonGeometry(outer: HorizontalRing([
        HorizontalCoordinate(latitude: 37.0, longitude: -122.0),
        HorizontalCoordinate(latitude: 37.0, longitude: -122.0 + size),
        HorizontalCoordinate(latitude: 37.0 + size, longitude: -122.0 + size),
        HorizontalCoordinate(latitude: 37.0 + size, longitude: -122.0),
    ]))
}

/// Test component declaring one area per address.
private struct AreaTestComponent: SceneComponent {
    var id: String
    var addresses: [String]

    var componentID: ComponentID { ComponentID("test.areas.\(id)") }

    var definitionSignature: DefinitionSignature {
        DefinitionSignature("areas/\(id)/\(addresses.joined(separator: ","))")
    }

    var presentation: PresentationFragment {
        PresentationFragment(operations: addresses.map { address in
            .upsertArea(
                AreaID(componentID: componentID, address: address),
                square(),
                areaStyle
            )
        })
    }
}

@MainActor
struct AreaPrimitiveTests {
    private let epoch = SceneEpoch(attachGeneration: 1, scopeGeneration: 1)

    private func areaID(_ component: AreaTestComponent, _ address: String) -> AreaID {
        AreaID(componentID: component.componentID, address: address)
    }

    private func removals(in plan: RenderPlan) -> [AreaID] {
        plan.operations.compactMap {
            if case .removeArea(let id) = $0 { return id }
            return nil
        }
    }

    private func upserts(in plan: RenderPlan) -> [AreaID] {
        plan.operations.compactMap {
            if case .upsertArea(let id, _, _) = $0 { return id }
            return nil
        }
    }

    // Failure paths first: what must be removed, and only that.

    @Test func updateDroppingOneVolumeRemovesOnlyThatArea() {
        let executor = RenderPlanExecutor()
        let full = AreaTestComponent(id: "class-b", addresses: ["core", "shelf-1", "shelf-2"])
        _ = executor.makeRenderPlan(
            from: ReconcilePlan(epoch: epoch, revision: SceneRevision(1), operations: [.mount(AnySceneComponent(full))]),
            components: [AnySceneComponent(full)]
        )
        let reduced = AreaTestComponent(id: "class-b", addresses: ["core", "shelf-2"])
        let plan = executor.makeRenderPlan(
            from: ReconcilePlan(epoch: epoch, revision: SceneRevision(2), operations: [.update(AnySceneComponent(reduced))]),
            components: [AnySceneComponent(reduced)]
        )
        #expect(removals(in: plan) == [areaID(full, "shelf-1")])
        #expect(upserts(in: plan) == [areaID(full, "core"), areaID(full, "shelf-2")])
    }

    @Test func unmountRemovesEveryAreaTheComponentInstalled() {
        let executor = RenderPlanExecutor()
        let component = AreaTestComponent(id: "tfr", addresses: ["a", "b"])
        _ = executor.makeRenderPlan(
            from: ReconcilePlan(epoch: epoch, revision: SceneRevision(1), operations: [.mount(AnySceneComponent(component))]),
            components: [AnySceneComponent(component)]
        )
        let plan = executor.makeRenderPlan(
            from: ReconcilePlan(epoch: epoch, revision: SceneRevision(2), operations: [.unmount(component.componentID)]),
            components: []
        )
        #expect(removals(in: plan) == [areaID(component, "a"), areaID(component, "b")])
        // A second unmount has nothing left to remove: the ledger was cleared.
        let again = executor.makeRenderPlan(
            from: ReconcilePlan(epoch: epoch, revision: SceneRevision(3), operations: [.unmount(component.componentID)]),
            components: []
        )
        #expect(removals(in: again).isEmpty)
    }

    @Test func convergenceRemovesAreasOfComponentsAbsentFromTheDesiredScene() {
        let executor = RenderPlanExecutor()
        let component = AreaTestComponent(id: "stale", addresses: ["x"])
        _ = executor.makeRenderPlan(
            from: ReconcilePlan(epoch: epoch, revision: SceneRevision(1), operations: [.mount(AnySceneComponent(component))]),
            components: [AnySceneComponent(component)]
        )
        // The reconciler never recorded the mount (a rejected late apply), so
        // no unmount arrives; the desired scene simply lacks the component.
        let plan = executor.makeRenderPlan(
            from: ReconcilePlan(epoch: epoch, revision: SceneRevision(2), operations: []),
            components: []
        )
        #expect(removals(in: plan) == [areaID(component, "x")])
    }

    @Test func surfaceResetForgetsInstalledAreas() {
        let executor = RenderPlanExecutor()
        let component = AreaTestComponent(id: "reset", addresses: ["x"])
        _ = executor.makeRenderPlan(
            from: ReconcilePlan(epoch: epoch, revision: SceneRevision(1), operations: [.mount(AnySceneComponent(component))]),
            components: [AnySceneComponent(component)]
        )
        executor.surfaceDidReset()
        let plan = executor.makeRenderPlan(
            from: ReconcilePlan(epoch: epoch, revision: SceneRevision(2), operations: [.unmount(component.componentID)]),
            components: []
        )
        #expect(removals(in: plan).isEmpty)
    }

    // Happy paths.

    @Test func mountEmitsOneUpsertPerVolumeInDeclarationOrder() {
        let executor = RenderPlanExecutor()
        let component = AreaTestComponent(id: "order", addresses: ["n", "e", "s"])
        let plan = executor.makeRenderPlan(
            from: ReconcilePlan(epoch: epoch, revision: SceneRevision(1), operations: [.mount(AnySceneComponent(component))]),
            components: [AnySceneComponent(component)]
        )
        #expect(upserts(in: plan) == [areaID(component, "n"), areaID(component, "e"), areaID(component, "s")])
        #expect(removals(in: plan).isEmpty)
    }

    @Test func fakeDriverHoldsAreasUntilRemoved() async throws {
        let driver = FakeSurfaceDriver()
        let id = AreaID(componentID: ComponentID("c"), address: "v")
        _ = try await driver.apply(RenderPlan(
            epoch: epoch, revision: SceneRevision(1),
            operations: [.upsertArea(id, square(), areaStyle)]
        ))
        #expect(driver.renderedAreas[id] == FakeSurfaceDriver.RenderedArea(geometry: square(), style: areaStyle))
        _ = try await driver.apply(RenderPlan(
            epoch: epoch, revision: SceneRevision(2),
            operations: [.upsertArea(id, square(0.2), areaStyle)]
        ))
        #expect(driver.renderedAreas[id]?.geometry == square(0.2))
        _ = try await driver.apply(RenderPlan(
            epoch: epoch, revision: SceneRevision(3),
            operations: [.removeArea(id), .removeArea(AreaID(componentID: ComponentID("c"), address: "never"))]
        ))
        #expect(driver.renderedAreas.isEmpty)
    }

    @Test func areaIdentityIsInjectionProof() {
        let a = AreaID(componentID: ComponentID("c"), address: "x/y")
        let b = AreaID(componentID: ComponentID("c/x"), address: "y")
        #expect(a != b)
        #expect(a.rawValue != b.rawValue)
    }
}
