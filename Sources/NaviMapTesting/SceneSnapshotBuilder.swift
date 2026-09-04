//
//  SceneSnapshotBuilder.swift
//  NaviMapTesting
//
//  Fluent builder for test snapshots.
//

import NaviMapCore
import NaviMapScene

package struct SceneSnapshotBuilder: Sendable {
    private var epoch = SceneEpoch(attachGeneration: 1, scopeGeneration: 1)
    private var revision = SceneRevision(1)
    private var components: [AnySceneComponent] = []

    package init() {}

    package func epoch(attach: UInt64, scope: UInt64) -> Self {
        var copy = self
        copy.epoch = SceneEpoch(attachGeneration: attach, scopeGeneration: scope)
        return copy
    }

    package func revision(_ value: UInt64) -> Self {
        var copy = self
        copy.revision = SceneRevision(value)
        return copy
    }

    package func component(id: String, signature: String) -> Self {
        var copy = self
        copy.components.append(AnySceneComponent(
            componentID: ComponentID(id),
            definitionSignature: DefinitionSignature(signature)
        ))
        return copy
    }

    package func build() -> NavigationSceneSnapshot {
        NavigationSceneSnapshot(epoch: epoch, revision: revision, components: components)
    }
}
