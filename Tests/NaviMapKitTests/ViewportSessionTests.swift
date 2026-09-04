//
//  ViewportSessionTests.swift
//  NaviMapKitTests
//
//  Viewport persistence round-trips: both viewport kinds,
//  the last-camera-pose restore payload, schema-version discard, and
//  torn/garbage-file tolerance.
//

import Foundation
import NaviMapCore
import NaviMapKit
import NaviMapTesting
import Testing

struct ViewportSessionTests {
    private func makeStore() -> ViewportSessionStore {
        MainThreadIOViolationRecorder.install()
        return ViewportSessionStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("navimapkit-tests-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("viewport-session.json")
        )
    }

    private var pose: CameraPose {
        CameraPose(
            center: NavigationPosition(latitude: 37.6191, longitude: -122.3816, vertical: .unknown),
            scale: MapScale(metersPerPoint: 42),
            bearing: Bearing(degreesTrue: 137.5),
            pitchDegrees: 15
        )
    }

    @Test func freeViewportRoundTrips() async throws {
        let store = makeStore()
        let before = MainThreadIOViolationRecorder.shared
            .violations(operationPrefix: "viewport-session").count
        await store.saveOffMain(ViewportSession(viewport: .free(pose), lastCameraPose: pose))
        let loaded = try #require(await store.loadOffMain())
        #expect(loaded.viewport == .free(pose))
        #expect(loaded.lastCameraPose == pose)
        await store.clearOffMain()
        // The off-main road is silent under the contract hook.
        #expect(
            MainThreadIOViolationRecorder.shared
                .violations(operationPrefix: "viewport-session").count == before
        )
    }

    @Test func followViewportRoundTrips() async throws {
        let store = makeStore()
        let configuration = FollowConfiguration(
            orientation: .courseUp, scale: MapScale(metersPerPoint: 55)
        )
        await store.saveOffMain(ViewportSession(
            viewport: .follow(.ownship, configuration),
            lastCameraPose: pose
        ))
        let loaded = try #require(await store.loadOffMain())
        #expect(loaded.viewport == .follow(.ownship, configuration))
        #expect(loaded.lastCameraPose == pose)
        await store.clearOffMain()
    }

    /// The hook covers this surface: every raw operation reports when run
    /// on the main thread. (Behaviour is unchanged; the report is the
    /// contract's evidence.)
    @MainActor
    @Test func rawOperationsOnTheMainThreadAreReported() {
        let store = makeStore()
        let recorder = MainThreadIOViolationRecorder.shared
        let scope = "viewport-session-tests.raw-main-thread"
        MainThreadIOViolationRecorder.$scope.withValue(scope) {
            store.save(ViewportSession(viewport: .free(pose)))
            _ = store.load()
            store.clear()
        }
        let reported = recorder.violations(operationPrefix: "viewport-session", scope: scope)
        #expect(
            reported.map(\.operation)
                == ["viewport-session.save", "viewport-session.load", "viewport-session.clear"]
        )
    }

    @Test func missingFileLoadsNil() {
        let store = makeStore()
        #expect(store.load() == nil)
    }

    @Test func garbageFileLoadsNil() throws {
        let store = makeStore()
        defer { store.clear() }
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json{{{".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
    }

    @Test func unknownSchemaVersionIsDiscarded() throws {
        let store = makeStore()
        defer { store.clear() }
        store.save(ViewportSession(viewport: .free(pose)))
        var json = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: store.fileURL)
        ) as? [String: Any])
        json["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)
        #expect(store.load() == nil)
    }
}
