//
//  CapabilityAndSignalTests.swift
//  NaviMapKitTests
//
//  Typed capability negotiation and
//  the surface-signal forwarding the viewport/delegate layer consumes.
//

import NaviMapCore
import NaviMapKit
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing

@MainActor
struct CapabilityAndSignalTests {
    private func drain(until condition: () -> Bool) async throws {
        for _ in 0 ..< 10_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "condition not reached after bounded drain")
    }

    @Test func capabilitySetOperations() {
        let partial = CapabilitySet(.surface, .camera)
        #expect(!partial.isSuperset(of: .basePrimitives))
        #expect(
            partial.missing(from: .basePrimitives)
                == CapabilitySet(.vectorRendering, .entityMarkers)
        )
        #expect(CapabilitySet.basePrimitives.missing(from: partial).isEmpty)
    }

    @Test func incompatibleComponentIsRefusedAndReported() async throws {
        let store = NaviMapSceneStore()
        // A runtime that cannot render entity markers.
        let driver = FakeSurfaceDriver(manifest: CapabilityManifest(
            supported: CapabilitySet(.surface, .camera, .vectorRendering)
        ))
        try await store.attach(driver: driver, host: FakeSurfaceHost())

        var refusals: [(ComponentID, CapabilitySet)] = []
        store.onCapabilityRefusal = { refusals.append(($0, $1)) }

        let needsEntities = AnySceneComponent(
            componentID: ComponentID("ownship"),
            definitionSignature: DefinitionSignature("s1"),
            capabilityRequirement: .basePrimitives
        )
        let basemapOnly = AnySceneComponent(
            componentID: ComponentID("basemap"),
            definitionSignature: DefinitionSignature("s1"),
            capabilityRequirement: CapabilityRequirement(required: CapabilitySet(.surface, .vectorRendering))
        )
        store.setComponents([needsEntities, basemapOnly])

        // Fail-fast, reported, excluded — never silently dropped.
        #expect(store.reconciler.desired?.components == [basemapOnly])
        #expect(refusals.count == 1)
        #expect(refusals.first?.0 == ComponentID("ownship"))
        #expect(refusals.first?.1 == CapabilitySet(.entityMarkers))
        #expect(
            store.capabilityReport?.incompatible[ComponentID("ownship")]
                == CapabilitySet(.entityMarkers)
        )

        // Refusal fires once per component, not once per publish.
        store.setComponents([needsEntities, basemapOnly])
        #expect(refusals.count == 1)
    }

    @Test func surfaceSignalsAreForwarded() async throws {
        let store = NaviMapSceneStore()
        let driver = FakeSurfaceDriver()
        try await store.attach(driver: driver, host: FakeSurfaceHost())

        var signals: [SurfaceSignal] = []
        store.onSurfaceSignal = { signals.append($0) }

        let pose = CameraPose(
            center: NavigationPosition(latitude: 1, longitude: 2, vertical: .unknown),
            scale: MapScale(metersPerPoint: 30)
        )
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.userInteractionBegan)
        driver.emitSurfaceEvent(.cameraIdle(pose))
        try await drain { signals.count == 3 }
        #expect(signals == [.becameReady, .userInteractionBegan, .cameraIdle(pose)])
    }

    @Test func entityHitsMapThroughTheStore() async throws {
        let store = NaviMapSceneStore()
        let driver = FakeSurfaceDriver()
        try await store.attach(driver: driver, host: FakeSurfaceHost())
        driver.scriptedEntityHits = [.ownship]
        let hits = await store.entityHits(at: ScreenPoint(x: 10, y: 20))
        #expect(hits == [.ownship])
        #expect(driver.entityHitQueries == [ScreenPoint(x: 10, y: 20)])
    }

    @Test func handleQueryIsEmptyWhenUnattached() async {
        let handle = NaviMapHandle()
        let features = await handle.features(at: ScreenPoint(x: 0, y: 0))
        #expect(features.isEmpty)
    }
}
