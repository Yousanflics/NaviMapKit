//
//  NavigationSceneTests.swift
//  NaviMapSceneTests
//

import NaviMapCore
import NaviMapScene
import NaviMapTesting
import Testing

struct NavigationSceneTests {
    @Test func componentEqualityIsIdentityPlusSignature() {
        // equality = componentID + definitionSignature, exactly
        // the reconciler's judgment inputs.
        let a = AnySceneComponent(
            componentID: ComponentID("airspace"),
            definitionSignature: DefinitionSignature("v1")
        )
        let sameDefinition = AnySceneComponent(
            componentID: ComponentID("airspace"),
            definitionSignature: DefinitionSignature("v1")
        )
        let changedDefinition = AnySceneComponent(
            componentID: ComponentID("airspace"),
            definitionSignature: DefinitionSignature("v2")
        )

        #expect(a == sameDefinition)
        #expect(a != changedDefinition)
    }

    @Test func builderProducesEquatableSnapshots() {
        let make = {
            SceneSnapshotBuilder()
                .epoch(attach: 3, scope: 7)
                .revision(42)
                .component(id: "ownship", signature: "s1")
                .build()
        }
        #expect(make() == make())
        #expect(make().revision == SceneRevision(42))
    }
}
