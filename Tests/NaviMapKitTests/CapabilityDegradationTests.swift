//
//  CapabilityDegradationTests.swift
//  NaviMapKitTests
//
//  The degradation report is a projection of what a component drew: a
//  component that falls back is reported, a component that draws its full
//  depiction is not, and a component that forbids degrading is refused.
//

import Foundation
import NaviMapCore
@testable import NaviMapKit
import NaviMapRuntime
import NaviMapScene
import NaviMapTesting
import Testing

/// Draws the fallback when volume rendering is not offered.
private struct HonestVolumeComponent: SceneComponent {
    var policy: DegradationPolicy = .allow(fallback: .footprintWithAltitudeLabels)

    var componentID: ComponentID { ComponentID("test.volume.honest") }
    var definitionSignature: DefinitionSignature { DefinitionSignature("honest") }
    var presentation: PresentationFragment { PresentationFragment() }
    var capabilityRequirement: CapabilityRequirement {
        CapabilityRequirement(required: .basePrimitives, optional: CapabilitySet(.volumeRendering), degradation: policy)
    }

    func presentation(at cursor: RepresentedTime?, offering: CapabilitySet) -> PresentationFragment {
        if offering.contains(.volumeRendering) {
            return PresentationFragment()
        }
        return PresentationFragment(appliedFallback: .footprintWithAltitudeLabels)
    }
}

/// Ignores the offering and always draws its full depiction.
private struct StubbornVolumeComponent: SceneComponent {
    var componentID: ComponentID { ComponentID("test.volume.stubborn") }
    var definitionSignature: DefinitionSignature { DefinitionSignature("stubborn") }
    var presentation: PresentationFragment { PresentationFragment() }
    var capabilityRequirement: CapabilityRequirement {
        CapabilityRequirement(required: .basePrimitives, optional: CapabilitySet(.volumeRendering), degradation: .allow(fallback: .footprintWithAltitudeLabels))
    }
}

/// Falls back no matter what is offered: a component defect.
private struct AlwaysFallbackComponent: SceneComponent {
    var componentID: ComponentID { ComponentID("test.volume.always") }
    var definitionSignature: DefinitionSignature { DefinitionSignature("always") }
    var presentation: PresentationFragment { PresentationFragment(appliedFallback: .footprintWithAltitudeLabels) }
    var capabilityRequirement: CapabilityRequirement {
        CapabilityRequirement(required: .basePrimitives, optional: CapabilitySet(.volumeRendering), degradation: .allow(fallback: .footprintWithAltitudeLabels))
    }

    func presentation(at cursor: RepresentedTime?, offering: CapabilitySet) -> PresentationFragment {
        presentation
    }
}

/// Needs a capability no runtime offers.
private struct ImpossibleComponent: SceneComponent {
    var componentID: ComponentID { ComponentID("test.impossible") }
    var definitionSignature: DefinitionSignature { DefinitionSignature("impossible") }
    var presentation: PresentationFragment { PresentationFragment() }
    var capabilityRequirement: CapabilityRequirement {
        CapabilityRequirement(required: CapabilitySet(.surface, .camera, .vectorRendering, .entityMarkers, Capability(rawValue: "test.capability.none")))
    }
}

@MainActor
struct CapabilityDegradationTests {
    private func drain(until condition: () -> Bool) async throws {
        for _ in 0 ..< 10_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "condition not reached after bounded drain")
    }

    private func makeReadyStore(supported: CapabilitySet = .basePrimitives) async throws -> (NaviMapSceneStore, FakeSurfaceDriver) {
        let store = NaviMapSceneStore()
        let driver = FakeSurfaceDriver(manifest: CapabilityManifest(supported: supported))
        try await store.attach(driver: driver, host: FakeSurfaceHost())
        driver.emitSurfaceEvent(.loadStarted(surfaceGeneration: 1))
        driver.emitSurfaceEvent(.becameReady(surfaceGeneration: 1))
        try await drain { store.reconciler.actual.isSurfaceReady }
        return (store, driver)
    }

    // Failure paths first.

    @Test func forbiddenDegradationRefusesTheComponent() async throws {
        let (store, _) = try await makeReadyStore()
        var refusals: [(ComponentID, CapabilitySet)] = []
        store.onCapabilityRefusal = { refusals.append(($0, $1)) }
        let component = HonestVolumeComponent(policy: .forbid)
        store.setComponents([AnySceneComponent(component)])
        #expect(refusals.count == 1)
        #expect(refusals.first?.0 == component.componentID)
        #expect(refusals.first?.1 == CapabilitySet(.volumeRendering))
        #expect(store.capabilityReport?.incompatible[component.componentID] == CapabilitySet(.volumeRendering))
        #expect(store.capabilityReport?.degraded.isEmpty == true)
        #expect(store.reconciler.desired?.components.isEmpty ?? true)
    }

    @Test func requiredGapStillRefusesRegardlessOfPolicy() async throws {
        let (store, _) = try await makeReadyStore()
        let component = ImpossibleComponent()
        store.setComponents([AnySceneComponent(component)])
        #expect(store.capabilityReport?.incompatible[component.componentID] == CapabilitySet(Capability(rawValue: "test.capability.none")))
        #expect(store.reconciler.desired?.components.isEmpty ?? true)
    }

    @Test func reportNeverClaimsAFallbackThatWasNotDrawn() async throws {
        let (store, _) = try await makeReadyStore()
        var changes = 0
        store.onDegradationChanged = { changes += 1 }
        store.setComponents([AnySceneComponent(StubbornVolumeComponent())])
        #expect(store.capabilityReport?.degraded.isEmpty == true)
        #expect(store.capabilityReport?.incompatible.isEmpty == true)
        #expect(store.reconciler.desired?.components.count == 1)
        #expect(changes == 0)
    }

    @Test func fallbackWithEveryCapabilityOfferedIsAComponentDefectNotADegradation() async throws {
        let everything = CapabilitySet(.surface, .camera, .vectorRendering, .entityMarkers, .volumeRendering)
        let (store, _) = try await makeReadyStore(supported: everything)
        var defects: [(ComponentID, DegradationFallback)] = []
        store.onUnexpectedFallback = { defects.append(($0, $1)) }
        let component = AlwaysFallbackComponent()
        store.setComponents([AnySceneComponent(component)])
        store.setComponents([AnySceneComponent(component)])
        #expect(store.capabilityReport?.degraded.isEmpty == true)
        #expect(defects.count == 1)
        #expect(defects.first?.0 == component.componentID)
        #expect(defects.first?.1 == .footprintWithAltitudeLabels)
    }

    // Happy paths.

    @Test func drawnFallbackIsReportedAsDegraded() async throws {
        let (store, driver) = try await makeReadyStore()
        var changes = 0
        store.onDegradationChanged = { changes += 1 }
        let component = HonestVolumeComponent()
        store.setComponents([AnySceneComponent(component)])
        #expect(store.capabilityReport?.degraded[component.componentID] == CapabilitySet(.volumeRendering))
        #expect(store.capabilityReport?.incompatible.isEmpty == true)
        #expect(changes == 1)
        try await drain { store.reconciler.actual.appliedRevision == store.lastPublishedRevision }
        #expect(driver.appliedPlans.count >= 1)
        // Re-declaring the same component does not re-announce.
        store.setComponents([AnySceneComponent(component)])
        #expect(changes == 1)
    }

    @Test func offeredCapabilityClearsTheDegradation() async throws {
        let (store, _) = try await makeReadyStore(supported: CapabilitySet(.surface, .camera, .vectorRendering, .entityMarkers, .volumeRendering))
        let component = HonestVolumeComponent()
        store.setComponents([AnySceneComponent(component)])
        #expect(store.capabilityReport?.degraded.isEmpty == true)
        #expect(store.reconciler.desired?.components.count == 1)
    }

    @Test func removingTheComponentClearsItsDegradation() async throws {
        let (store, _) = try await makeReadyStore()
        let component = HonestVolumeComponent()
        store.setComponents([AnySceneComponent(component)])
        #expect(store.capabilityReport?.degraded[component.componentID] != nil)
        var changes = 0
        store.onDegradationChanged = { changes += 1 }
        store.setComponents([])
        #expect(store.capabilityReport?.degraded.isEmpty == true)
        #expect(changes == 1)
    }
}
