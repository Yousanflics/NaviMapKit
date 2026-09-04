//
//  SurfaceDriving.swift
//  NaviMapRuntime
//
//  Driver contract (`package` access). Ack semantics: the
//  driver confirms the plan has entered its render state — sources/layers
//  installed and a first frame scheduled. Epoch-mismatched acks are dropped
//  by the caller. This target stays UIKit-free
//  portability): the platform host is an opaque protocol the concrete
//  driver downcasts.
//

import NaviMapCore
import NaviMapScene

/// Opaque platform surface host. `_PrimaryVectorRuntime` provides the UIKit
/// conformance; NaviMapTesting provides a headless one. Runtime itself never
/// imports UIKit.
@MainActor
package protocol SurfaceHosting: AnyObject {}

/// Basemap selection understood by every runtime (v0: the operational style).
package enum BasemapStyle: Sendable, Equatable {
    case operational
}

/// Provider-neutral render primitives — the base set every runtime must
/// support. Higher capabilities arrive as capability-extension
/// payloads, never by widening this enum ad hoc.
package enum RenderOp: Sendable, Equatable {
    case setBasemap(BasemapStyle)
    case upsertEntityMarker(EntityID, NavigationPosition, label: String?)
    case removeEntityMarker(EntityID)
    case upsertPath(ComponentID, [NavigationPosition])
    case removePath(ComponentID)
    /// Content binding (base set, third explicit extension): the runtime
    /// records which local directory is current for the content identity
    /// and acknowledges once that binding is in effect for rendering.
    case setContentSource(ContentID, ContentSourceLocation)
    /// Filled area (base set, fourth explicit extension): polygon fill is a
    /// baseline capability of every candidate runtime, so it joins the base
    /// set rather than a capability extension. Keyed per volume within the
    /// owning component; the executor removes only the areas a component
    /// stops declaring. The manifest gains no entry.
    case upsertArea(AreaID, PolygonGeometry, AreaStyle)
    case removeArea(AreaID)
}

package struct RenderPlan: Sendable, Equatable {
    package var epoch: SceneEpoch
    package var revision: SceneRevision
    package var operations: [RenderOp]

    package init(epoch: SceneEpoch, revision: SceneRevision, operations: [RenderOp] = []) {
        self.epoch = epoch
        self.revision = revision
        self.operations = operations
    }
}

package struct ApplyAcknowledgement: Sendable, Equatable {
    package var epoch: SceneEpoch
    package var appliedRevision: SceneRevision

    package init(epoch: SceneEpoch, appliedRevision: SceneRevision) {
        self.epoch = epoch
        self.appliedRevision = appliedRevision
    }
}

package struct CapabilityManifest: Sendable, Equatable {
    /// Typed capability vocabulary — replaced the -interim
    /// stringly set.
    package var supported: CapabilitySet

    package init(supported: CapabilitySet) {
        self.supported = supported
    }
}

package enum SurfaceDriverFailure: Error, Sendable, Equatable {
    case attachRejected
    case applyRejected(SceneRevision)
    case notAttached
    /// The bounded frame wait elapsed without a rendered frame.
    case acknowledgementTimedOut(SceneRevision)
}

/// Surface lifecycle events the scene layer consumes to drive ReconcilerCore
/// readiness (surfaceLoadStarted / surfaceBecameReady analogs), plus the
/// camera/interaction facts the viewport layer needs:
/// a user gesture beginning is what breaks `.follow`, and camera-idle
/// carries the settled pose for `NavigationViewportState` output.
package enum SurfaceEvent: Sendable, Equatable {
    case loadStarted(surfaceGeneration: UInt64)
    case becameReady(surfaceGeneration: UInt64)
    /// The user began interacting with the surface (pan/pinch/rotate).
    case userInteractionBegan
    /// The camera settled at a pose (after gesture, animation, or set).
    case cameraIdle(CameraPose)
}

@MainActor
package protocol MapSurfaceDriving: AnyObject {
    var manifest: CapabilityManifest { get }
    /// Surface lifecycle events; one stream per attach.
    var surfaceEvents: AsyncStream<SurfaceEvent> { get }
    func attach(to host: any SurfaceHosting, epoch: SceneEpoch) async throws
    func apply(_ plan: RenderPlan) async throws -> ApplyAcknowledgement
    /// Camera is driver-owned; viewport intents arrive here.
    /// `animated: false` is the restore path's hard requirement.
    func updateCamera(_ pose: CameraPose, animated: Bool)
    /// The pose the camera currently holds (nil before attach). Scale is the
    /// provider zoom mapped back to meters/point — provider zoom itself
    /// never crosses this boundary.
    func currentCamera() -> CameraPose?
    /// Entity markers rendered at a view-space point (the query primitive
    /// behind `features(at:)`).
    func entityHits(at point: ScreenPoint) async -> [EntityID]
    func detach() async
}
