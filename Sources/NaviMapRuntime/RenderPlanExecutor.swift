//
//  RenderPlanExecutor.swift
//  NaviMapRuntime
//
//  Translates a ReconcilePlan into the provider-neutral RenderPlan.
//  Stateful only for inverses: unmount carries just the
//  ComponentID, so the executor remembers which entity markers each
//  component installed in order to emit their removals. This is the sole
//  bridge from scene ops to runtime ops — no other path builds RenderPlans
//

import NaviMapCore
import NaviMapScene

@MainActor
package final class RenderPlanExecutor {
    /// Entity markers installed per component (for unmount inversion).
    private var installedEntities: [ComponentID: [EntityID]] = [:]
    /// Path-owning components (for unmount inversion).
    private var installedPaths: Set<ComponentID> = []
    /// Content bindings installed per component (for unmount inversion:
    /// an unmounted binding component unbinds its content).
    private var installedContentSources: [ComponentID: Set<ContentID>] = [:]
    /// Areas installed per component (for update and unmount inversion:
    /// only the areas a component stops declaring are removed).
    private var installedAreas: [ComponentID: [AreaID]] = [:]

    package init() {}

    /// Called on surface rebuild: the driver's runtime state is gone, so the
    /// inversion ledger must reset with it.
    package func surfaceDidReset() {
        installedEntities = [:]
        installedPaths = []
        installedContentSources = [:]
        installedAreas = [:]
    }

    /// `offering` is the runtime's supported capability set; it reaches each
    /// component's presentation so the depiction drawn here is the same one
    /// the store reported on.
    package func makeRenderPlan(
        from plan: ReconcilePlan,
        components: [AnySceneComponent],
        cursor: RepresentedTime? = nil,
        offering: CapabilitySet = .basePrimitives
    ) -> RenderPlan {
        // Identities are unique here: the store de-duplicates every
        // declaration at its entry, so this cannot trap.
        let componentsByID = Dictionary(
            uniqueKeysWithValues: components.map { ($0.componentID, $0) }
        )
        var operations: [RenderOp] = []

        for op in plan.operations {
            switch op {
            case .mount(let component), .update(let component):
                guard let current = componentsByID[component.componentID] else { continue }
                let fragment = current.makePresentation(cursor, offering)
                var entities: [EntityID] = []
                var installsPath = false
                var contentSources: Set<ContentID> = []
                var areas: [AreaID] = []
                for sceneOp in fragment.operations {
                    switch sceneOp {
                    case .setBasemapOperational:
                        operations.append(.setBasemap(.operational))
                    case .upsertEntityMarker(let entityID, let position, let label):
                        operations.append(.upsertEntityMarker(entityID, position, label: label))
                        entities.append(entityID)
                    case .removeEntityMarker(let entityID):
                        operations.append(.removeEntityMarker(entityID))
                    case .upsertPath(let componentID, let positions):
                        operations.append(.upsertPath(componentID, positions))
                        installsPath = true
                    case .removePath(let componentID):
                        operations.append(.removePath(componentID))
                    case .setContentSource(let contentID, let location):
                        operations.append(.setContentSource(contentID, location))
                        if location != .none { contentSources.insert(contentID) }
                    case .upsertArea(let areaID, let geometry, let style):
                        operations.append(.upsertArea(areaID, geometry, style))
                        areas.append(areaID)
                    case .removeArea(let areaID):
                        operations.append(.removeArea(areaID))
                    }
                }
                // Areas dropped between updates are removed explicitly; the
                // ones still declared were just re-sent.
                for gone in installedAreas[component.componentID] ?? [] where !areas.contains(gone) {
                    operations.append(.removeArea(gone))
                }
                installedAreas[component.componentID] = areas
                for gone in installedContentSources[component.componentID] ?? []
                    where !contentSources.contains(gone) {
                    operations.append(.setContentSource(gone, .none))
                }
                installedContentSources[component.componentID] = contentSources
                // Update inversion ledger: entities dropped between updates
                // are removed explicitly.
                let previous = installedEntities[component.componentID] ?? []
                for gone in previous where !entities.contains(gone) {
                    operations.append(.removeEntityMarker(gone))
                }
                installedEntities[component.componentID] = entities
                if installsPath {
                    installedPaths.insert(component.componentID)
                } else if installedPaths.remove(component.componentID) != nil {
                    operations.append(.removePath(component.componentID))
                }

            case .unmount(let componentID):
                for entityID in installedEntities[componentID] ?? [] {
                    operations.append(.removeEntityMarker(entityID))
                }
                installedEntities[componentID] = nil
                for areaID in installedAreas[componentID] ?? [] {
                    operations.append(.removeArea(areaID))
                }
                installedAreas[componentID] = nil
                if installedPaths.remove(componentID) != nil {
                    operations.append(.removePath(componentID))
                }
                for contentID in (installedContentSources[componentID] ?? []).sorted(by: { $0.rawValue < $1.rawValue }) {
                    operations.append(.setContentSource(contentID, .none))
                }
                installedContentSources[componentID] = nil
            }
        }

        // Convergence against stale applies: a plan the driver applied but
        // the reconciler rejected (a late acknowledgement) installed state
        // the reconciler's mounted view never recorded, so no unmount will
        // ever be emitted for it. The ledger knows; anything it holds for a
        // component absent from the desired scene is removed here.
        let desiredIDs = Set(componentsByID.keys)
        for componentID in installedEntities.keys.sorted(by: { $0.rawValue < $1.rawValue })
            where !desiredIDs.contains(componentID) {
            for entityID in installedEntities[componentID] ?? [] {
                operations.append(.removeEntityMarker(entityID))
            }
            installedEntities[componentID] = nil
        }
        for componentID in installedPaths.sorted(by: { $0.rawValue < $1.rawValue })
            where !desiredIDs.contains(componentID) {
            operations.append(.removePath(componentID))
            installedPaths.remove(componentID)
        }
        for componentID in installedContentSources.keys.sorted(by: { $0.rawValue < $1.rawValue })
            where !desiredIDs.contains(componentID) {
            for contentID in (installedContentSources[componentID] ?? []).sorted(by: { $0.rawValue < $1.rawValue }) {
                operations.append(.setContentSource(contentID, .none))
            }
            installedContentSources[componentID] = nil
        }
        for componentID in installedAreas.keys.sorted(by: { $0.rawValue < $1.rawValue })
            where !desiredIDs.contains(componentID) {
            for areaID in installedAreas[componentID] ?? [] {
                operations.append(.removeArea(areaID))
            }
            installedAreas[componentID] = nil
        }

        return RenderPlan(epoch: plan.epoch, revision: plan.revision, operations: operations)
    }
}
