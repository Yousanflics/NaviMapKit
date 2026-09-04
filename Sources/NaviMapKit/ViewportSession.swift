//
//  ViewportSession.swift
//  NaviMapKit
//
//  Viewport persistence: a single small JSON file written
//  atomically. Public types stay Codable-free — this DTO is the only
//  serialized shape, versioned for forward migration. Write moments are
//  deliberate: automatic flush on didEnterBackground (inside a background
//  task, wired by the view layer) plus the explicit `flushViewport()` on the
//  handle — not on every camera tick.
//
//  Threading: every disk access here passes through the main-thread I/O
//  contract hook. The synchronous `load`/`save`/`clear` are the raw
//  operations; callers on the main actor use the `OffMain` variants, which
//  run them on one serial utility queue (FIFO, so a later write can never
//  be overtaken by an earlier one).
//

import Foundation
import NaviMapCore

/// What a session restore needs: the viewport intent, plus the last pose the
/// camera actually held so a `follow` viewport can show the last region
/// before the first GPS fix arrives (restore-before-GPS).
package struct ViewportSession: Equatable, Sendable {
    package var viewport: NavigationViewport
    package var lastCameraPose: CameraPose?

    package init(viewport: NavigationViewport, lastCameraPose: CameraPose? = nil) {
        self.viewport = viewport
        self.lastCameraPose = lastCameraPose
    }
}

private struct PersistedCamera: Codable {
    var latitude: Double
    var longitude: Double
    var metersPerPoint: Double
    var bearingDegreesTrue: Double
    var pitchDegrees: Double
}

private struct PersistedSession: Codable {
    // Bump on breaking shape changes; unknown versions are discarded (a
    // stale viewport is cosmetic — never worth a crash or a migration).
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var kind: String // "free" | "follow"
    var freeCamera: PersistedCamera?
    var followEntityID: String?
    var followOrientation: String?
    var followMetersPerPoint: Double?
    var lastCamera: PersistedCamera?
}

package struct ViewportSessionStore: Sendable {
    private enum Location: Sendable {
        /// Application Support/NaviMapKit/viewport-session.json, resolved
        /// only when the store performs I/O: even the home-directory lookup
        /// stats the file system, so nothing is resolved at construction.
        case applicationDefault
        case path(String)
    }

    private let location: Location

    /// Resolved on demand; callers on the main actor never read it.
    package var path: String {
        switch location {
        case .path(let path): path
        case .applicationDefault: NSHomeDirectory() + "/Library/Application Support/NaviMapKit/viewport-session.json"
        }
    }

    /// Forming a file URL standardizes the path with a stat; formed only
    /// where the store performs I/O.
    package var fileURL: URL { URL(fileURLWithPath: path, isDirectory: false) }

    package init(fileURL: URL) {
        location = .path(fileURL.path)
    }

    package init(path: String) {
        location = .path(path)
    }

    private init(location: Location) {
        self.location = location
    }

    /// Application Support/NaviMapKit/viewport-session.json — per-app,
    /// deterministic, no global mutable state.
    /// The application's session file. Construction performs no lookup at
    /// all; the location is resolved on the I/O queue.
    package static var `default`: ViewportSessionStore {
        ViewportSessionStore(location: .applicationDefault)
    }

    package func load() -> ViewportSession? {
        MainThreadIOContract.assertOffMainThread("viewport-session.load")
        guard let data = try? Data(contentsOf: fileURL),
              let persisted = try? JSONDecoder().decode(PersistedSession.self, from: data),
              persisted.schemaVersion == PersistedSession.currentSchemaVersion
        else { return nil }

        let lastPose = persisted.lastCamera.map(Self.pose(from:))
        switch persisted.kind {
        case "free":
            guard let camera = persisted.freeCamera else { return nil }
            return ViewportSession(viewport: .free(Self.pose(from: camera)), lastCameraPose: lastPose)
        case "follow":
            guard let rawEntity = persisted.followEntityID,
                  let rawOrientation = persisted.followOrientation,
                  let orientation = FollowConfiguration.Orientation(rawValue: rawOrientation)
            else { return nil }
            var configuration = FollowConfiguration(orientation: orientation)
            if let metersPerPoint = persisted.followMetersPerPoint {
                configuration.scale = MapScale(metersPerPoint: metersPerPoint)
            }
            return ViewportSession(
                viewport: .follow(EntityID(rawEntity), configuration),
                lastCameraPose: lastPose
            )
        default:
            return nil
        }
    }

    /// Atomic write (temp file + rename via `.atomic`): a kill mid-write
    /// leaves the previous session intact, never a torn file.
    package func save(_ session: ViewportSession) {
        MainThreadIOContract.assertOffMainThread("viewport-session.save")
        var persisted = PersistedSession(
            schemaVersion: PersistedSession.currentSchemaVersion,
            kind: "free"
        )
        switch session.viewport {
        case .free(let pose):
            persisted.kind = "free"
            persisted.freeCamera = Self.persisted(from: pose)
        case .follow(let entityID, let configuration):
            persisted.kind = "follow"
            persisted.followEntityID = entityID.rawValue
            persisted.followOrientation = configuration.orientation.rawValue
            persisted.followMetersPerPoint = configuration.scale.metersPerPoint
        case .fit:
            // Fit persists its RESULT, never the intent: the pose
            // the fit produced. Before the size gate has produced one there
            // is nothing true to write — keep the previous session file.
            guard let effective = session.lastCameraPose else { return }
            persisted.kind = "free"
            persisted.freeCamera = Self.persisted(from: effective)
        }
        persisted.lastCamera = session.lastCameraPose.map(Self.persisted(from:))

        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    package func clear() {
        MainThreadIOContract.assertOffMainThread("viewport-session.clear")
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Off-main execution (main-thread I/O contract)

    /// One serial queue for all viewport-session I/O in the process: writes
    /// stay ordered and the main thread never touches the file.
    private static let ioQueue = DispatchQueue(
        label: "navimapkit.viewport-session", qos: .utility
    )

    package func loadOffMain() async -> ViewportSession? {
        await withCheckedContinuation { continuation in
            Self.ioQueue.async { continuation.resume(returning: load()) }
        }
    }

    /// Enqueue the write and return immediately (the flush moments that
    /// cannot await: view teardown, the public `flushViewport()`).
    package func scheduleSave(_ session: ViewportSession) {
        Self.ioQueue.async { save(session) }
    }

    /// Enqueue the write and wait for it to finish (the background-task
    /// flush, which must know when the file is safe).
    package func saveOffMain(_ session: ViewportSession) async {
        await withCheckedContinuation { continuation in
            Self.ioQueue.async {
                save(session)
                continuation.resume()
            }
        }
    }

    package func clearOffMain() async {
        await withCheckedContinuation { continuation in
            Self.ioQueue.async {
                clear()
                continuation.resume()
            }
        }
    }

    private static func pose(from camera: PersistedCamera) -> CameraPose {
        CameraPose(
            // A camera center's vertical is not part of the 2.5D pose;
            // restoring it as the explicit `.unknown` case is honest, not a
            // degradation.
            center: NavigationPosition(
                latitude: camera.latitude,
                longitude: camera.longitude,
                vertical: .unknown
            ),
            scale: MapScale(metersPerPoint: camera.metersPerPoint),
            bearing: Bearing(degreesTrue: camera.bearingDegreesTrue),
            pitchDegrees: camera.pitchDegrees
        )
    }

    private static func persisted(from pose: CameraPose) -> PersistedCamera {
        PersistedCamera(
            latitude: pose.center.horizontal.latitude,
            longitude: pose.center.horizontal.longitude,
            metersPerPoint: pose.scale.metersPerPoint,
            bearingDegreesTrue: pose.bearing.degreesTrue,
            pitchDegrees: pose.pitchDegrees
        )
    }
}
