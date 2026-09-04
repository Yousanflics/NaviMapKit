//
//  SceneIdentityTests.swift
//  NaviMapCoreTests
//

import NaviMapCore
import Testing

struct SceneIdentityTests {
    @Test func revisionOrderingIsMonotonic() {
        #expect(SceneRevision(1) < SceneRevision(2))
        #expect(!(SceneRevision(2) < SceneRevision(2)))
    }

    @Test func epochEqualityCoversBothGenerations() {
        let a = SceneEpoch(attachGeneration: 1, scopeGeneration: 1)
        #expect(a == SceneEpoch(attachGeneration: 1, scopeGeneration: 1))
        #expect(a != SceneEpoch(attachGeneration: 2, scopeGeneration: 1))
        #expect(a != SceneEpoch(attachGeneration: 1, scopeGeneration: 2))
    }
}
