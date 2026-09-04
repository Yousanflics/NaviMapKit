//
//  FakeSurfaceDriver.swift
//  NaviMapTesting
//
//  Scriptable surface driver for reconciler/offline tests: each applied
//  plan consumes the next scripted step —
//  acknowledge (optionally after a suspension), fail, or hang until cancelled.
//  Deterministic by construction: no wall-clock sleeps; delays are explicit
//  continuations the test resumes.
//

import NaviMapCore
import NaviMapRuntime
import NaviMapScene

/// Headless surface host for tests (Runtime never sees UIKit).
@MainActor
package final class FakeSurfaceHost: SurfaceHosting {
    package init() {}
}

@MainActor
package final class FakeSurfaceDriver: MapSurfaceDriving {
    package enum ScriptStep: Sendable {
        /// Acknowledge immediately.
        case acknowledge
        /// Suspend until the test calls `resumePending()`, then acknowledge.
        case acknowledgeWhenResumed
        /// Throw `SurfaceDriverFailure.applyRejected`.
        case fail
    }

    package enum AttachScriptStep: Sendable {
        case succeed
        /// Throw `SurfaceDriverFailure.attachRejected` — driver contract
        /// tests need attach-failure injection.
        case fail
    }

    package private(set) var manifest: CapabilityManifest
    package private(set) var attachedEpochs: [SceneEpoch] = []
    package private(set) var appliedPlans: [RenderPlan] = []
    package private(set) var detachCount = 0
    /// Scriptable surface lifecycle events: tests drive readiness through the
    /// same channel the real driver uses — no DEBUG readiness backdoor.
    package var surfaceEvents: AsyncStream<SurfaceEvent> { eventStream }

    private var eventStream: AsyncStream<SurfaceEvent>
    private var eventContinuation: AsyncStream<SurfaceEvent>.Continuation
    private var script: [ScriptStep]
    private var attachScript: [AttachScriptStep]
    private var pending: [CheckedContinuation<Void, Never>] = []

    package init(
        manifest: CapabilityManifest = CapabilityManifest(supported: .basePrimitives),
        script: [ScriptStep] = [],
        attachScript: [AttachScriptStep] = []
    ) {
        self.manifest = manifest
        self.script = script
        self.attachScript = attachScript
        (eventStream, eventContinuation) = AsyncStream.makeStream(of: SurfaceEvent.self)
    }

    /// Test control: emit a surface lifecycle event as the real driver would.
    package func emitSurfaceEvent(_ event: SurfaceEvent) {
        eventContinuation.yield(event)
    }

    /// Resumes every apply currently suspended on `.acknowledgeWhenResumed`.
    package func resumePending() {
        let continuations = pending
        pending = []
        for continuation in continuations {
            continuation.resume()
        }
    }

    package func attach(to host: any SurfaceHosting, epoch: SceneEpoch) async throws {
        _ = host
        let step = attachScript.isEmpty ? .succeed : attachScript.removeFirst()
        if case .fail = step {
            throw SurfaceDriverFailure.attachRejected
        }
        attachedEpochs.append(epoch)
    }

    /// Content bindings in effect, as a runtime would hold them.
    package private(set) var boundContentSources: [ContentID: ContentSourceLocation] = [:]

    /// Test control: content identities whose binding fails to take effect,
    /// as a provider mount failure would; the apply is rejected.
    package var failingContentBindings: Set<ContentID> = []

    /// One area as a runtime would hold it after an upsert.
    package struct RenderedArea: Sendable, Equatable {
        package var geometry: PolygonGeometry
        package var style: AreaStyle

        package init(geometry: PolygonGeometry, style: AreaStyle) {
            self.geometry = geometry
            self.style = style
        }
    }

    /// Areas in effect, as a runtime would hold them.
    package private(set) var renderedAreas: [AreaID: RenderedArea] = [:]

    package func apply(_ plan: RenderPlan) async throws -> ApplyAcknowledgement {
        appliedPlans.append(plan)
        for operation in plan.operations {
            switch operation {
            case .setContentSource(let contentID, let location):
                if location != .none, failingContentBindings.contains(contentID) {
                    throw SurfaceDriverFailure.applyRejected(plan.revision)
                }
                boundContentSources[contentID] = location == .none ? nil : location
            case .upsertArea(let areaID, let geometry, let style):
                renderedAreas[areaID] = RenderedArea(geometry: geometry, style: style)
            case .removeArea(let areaID):
                renderedAreas[areaID] = nil
            default:
                break
            }
        }
        let step = script.isEmpty ? .acknowledge : script.removeFirst()
        switch step {
        case .acknowledge:
            break
        case .acknowledgeWhenResumed:
            await withCheckedContinuation { continuation in
                pending.append(continuation)
            }
        case .fail:
            throw SurfaceDriverFailure.applyRejected(plan.revision)
        }
        return ApplyAcknowledgement(epoch: plan.epoch, appliedRevision: plan.revision)
    }

    package private(set) var cameraUpdates: [(pose: CameraPose, animated: Bool)] = []
    /// Test control: what `entityHits(at:)` returns next.
    package var scriptedEntityHits: [EntityID] = []
    package private(set) var entityHitQueries: [ScreenPoint] = []

    package func updateCamera(_ pose: CameraPose, animated: Bool) {
        cameraUpdates.append((pose, animated))
    }

    package func currentCamera() -> CameraPose? {
        cameraUpdates.last?.pose
    }

    package func entityHits(at point: ScreenPoint) async -> [EntityID] {
        entityHitQueries.append(point)
        return scriptedEntityHits
    }

    package func detach() async {
        detachCount += 1
        eventContinuation.finish()
        (eventStream, eventContinuation) = AsyncStream.makeStream(of: SurfaceEvent.self)
    }
}
