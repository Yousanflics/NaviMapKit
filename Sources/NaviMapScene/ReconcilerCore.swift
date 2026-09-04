//
//  ReconcilerCore.swift
//  NaviMapScene
//
//  The reconciliation core: desired/actual split, generation gating, and
//  revision-guarded accepts/markApplied. Desired state is a component tree,
//  diff output is component-level operations, and readiness is testable
//  through the driver fake — deliberately no DEBUG readiness backdoor.
//
//  this is the ONLY writer of runtime layer state. There is no
//  invalidate/rebuild seam and none may be added.
//

import NaviMapCore

/// One component-level operation. Ordering inside a plan is deterministic:
/// unmounts first (freeing render identities), then mounts, then updates —
/// each group sorted by componentID.
package enum ReconcileOp: Sendable, Equatable {
    case mount(AnySceneComponent)
    case update(AnySceneComponent)
    case unmount(ComponentID)
}

package struct ReconcilePlan: Sendable, Equatable {
    package var epoch: SceneEpoch
    package var revision: SceneRevision
    package var operations: [ReconcileOp]

    package init(epoch: SceneEpoch, revision: SceneRevision, operations: [ReconcileOp]) {
        self.epoch = epoch
        self.revision = revision
        self.operations = operations
    }
}

/// Actual (driver-side) state, expressed in surface vocabulary rather than
/// any provider's style vocabulary.
package struct SurfaceActualState: Sendable, Equatable {
    package var attachGeneration: UInt64
    package var surfaceGeneration: UInt64
    package var isSurfaceReady: Bool
    package var appliedRevision: SceneRevision?

    package static let initial = SurfaceActualState(
        attachGeneration: 0,
        surfaceGeneration: 0,
        isSurfaceReady: false,
        appliedRevision: nil
    )
}

@MainActor
package final class ReconcilerCore {
    package private(set) var desired: NavigationSceneSnapshot?
    package private(set) var actual = SurfaceActualState.initial
    /// Components the surface currently renders (by identity → signature).
    /// Reset on surface rebuild so the whole tree replays.
    package private(set) var mounted: [ComponentID: DefinitionSignature] = [:]

    package init() {}

    /// Attaching bumps the generation and resets readiness and applied
    /// state.
    @discardableResult
    package func attachSurface(initialSurfaceGeneration: UInt64) -> UInt64 {
        actual.attachGeneration &+= 1
        actual.surfaceGeneration = initialSurfaceGeneration
        actual.isSurfaceReady = false
        actual.appliedRevision = nil
        mounted = [:]
        return actual.attachGeneration
    }

    package func updateDesired(_ next: NavigationSceneSnapshot) {
        guard desired != next else { return }
        desired = next
    }

    /// A surface reload began — not ready, applied state void (full replay
    /// will follow).
    package func surfaceLoadStarted(attachGeneration: UInt64, surfaceGeneration: UInt64) {
        guard attachGeneration == actual.attachGeneration,
              surfaceGeneration >= actual.surfaceGeneration
        else { return }
        actual.surfaceGeneration = surfaceGeneration
        actual.isSurfaceReady = false
        actual.appliedRevision = nil
        mounted = [:]
    }

    /// Readiness with stale-generation rejection.
    @discardableResult
    package func surfaceBecameReady(attachGeneration: UInt64, surfaceGeneration: UInt64) -> Bool {
        guard attachGeneration == actual.attachGeneration,
              surfaceGeneration == actual.surfaceGeneration
        else { return false }
        guard !actual.isSurfaceReady else { return false }
        actual.isSurfaceReady = true
        actual.appliedRevision = nil
        mounted = [:]
        return true
    }

    /// Component-level reconcile plan. Returns nil when the surface is not
    /// ready or nothing changed.
    package func reconcilePlan() -> ReconcilePlan? {
        guard actual.isSurfaceReady,
              let desired,
              actual.appliedRevision != desired.revision
        else { return nil }
        let operations = Self.diff(mounted: mounted, desired: desired.components)
        return ReconcilePlan(
            epoch: desired.epoch,
            revision: desired.revision,
            operations: operations
        )
    }

    /// A plan is applicable only against the exact current surface state
    /// and desired revision.
    package func accepts(_ plan: ReconcilePlan) -> Bool {
        actual.isSurfaceReady
            && desired?.epoch == plan.epoch
            && desired?.revision == plan.revision
    }

    /// Revision-guarded apply record; additionally records the mounted tree
    /// that future diffs run against.
    @discardableResult
    package func markApplied(_ plan: ReconcilePlan) -> Bool {
        guard accepts(plan), let desired else { return false }
        actual.appliedRevision = plan.revision
        // Identities are unique: the scene store de-duplicates every
        // declaration at its entry, so this cannot trap.
        mounted = Dictionary(
            uniqueKeysWithValues: desired.components.map {
                ($0.componentID, $0.definitionSignature)
            }
        )
        return true
    }

    /// Pure diff.
    /// id gone → unmount; id new → mount; id same and
    /// signature changed → update; both same → no-op.
    package nonisolated static func diff(
        mounted: [ComponentID: DefinitionSignature],
        desired: [AnySceneComponent]
    ) -> [ReconcileOp] {
        // Identities are unique: the scene store de-duplicates every
        // declaration at its entry, so this cannot trap.
        let desiredByID = Dictionary(
            uniqueKeysWithValues: desired.map { ($0.componentID, $0) }
        )

        let unmounts = mounted.keys
            .filter { desiredByID[$0] == nil }
            .sorted { $0.rawValue < $1.rawValue }
            .map { ReconcileOp.unmount($0) }

        let mounts = desired
            .filter { mounted[$0.componentID] == nil }
            .sorted { $0.componentID.rawValue < $1.componentID.rawValue }
            .map { ReconcileOp.mount($0) }

        let updates = desired
            .filter { component in
                guard let existing = mounted[component.componentID] else { return false }
                return existing != component.definitionSignature
            }
            .sorted { $0.componentID.rawValue < $1.componentID.rawValue }
            .map { ReconcileOp.update($0) }

        return unmounts + mounts + updates
    }
}
