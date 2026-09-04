//
//  OfflineFakes.swift
//  NaviMapTesting
//
//  Deterministic doubles for the offline state machine (in-memory
//  file system, real SQLite registry, scripted acknowledgements). The file
//  system keeps a flat path map so a "restart" is simply a new manager over
//  the same instance; the confirmer scripts one outcome per activation.
//

import Foundation
import NaviMapCore
import NaviMapOffline
import os

package final class InMemoryContentFileSystem: ContentFileSystem, Sendable {
    private enum Node: Sendable {
        case directory
        case file(Data)
        case link(URL)
    }

    private let nodes = OSAllocatedUnfairLock<[String: Node]>(initialState: [:])

    package init() {}

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    package func createDirectory(at url: URL) throws {
        MainThreadIOContract.assertOffMainThread("content-fs.createDirectory")
        nodes.withLock { nodes in
            var path = Self.key(url)
            while path != "/" {
                if nodes[path] == nil { nodes[path] = .directory }
                path = (path as NSString).deletingLastPathComponent
            }
        }
    }

    package func moveItem(at source: URL, to destination: URL) throws {
        MainThreadIOContract.assertOffMainThread("content-fs.moveItem")
        try createDirectory(at: destination.deletingLastPathComponent())
        let from = Self.key(source)
        let to = Self.key(destination)
        try nodes.withLock { nodes in
            guard nodes[from] != nil else { throw GenerationFailure.fileSystem("missing \(from)") }
            guard nodes[to] == nil else { throw GenerationFailure.fileSystem("exists \(to)") }
            for (path, node) in nodes where path == from || path.hasPrefix(from + "/") {
                nodes[to + path.dropFirst(from.count)] = node
                nodes[path] = nil
            }
        }
    }

    package func removeItem(at url: URL) throws {
        MainThreadIOContract.assertOffMainThread("content-fs.removeItem")
        let target = Self.key(url)
        nodes.withLock { nodes in
            for path in nodes.keys where path == target || path.hasPrefix(target + "/") {
                nodes[path] = nil
            }
        }
    }

    package func itemExists(at url: URL) -> Bool {
        MainThreadIOContract.assertOffMainThread("content-fs.itemExists")
        return nodes.withLock { $0[Self.key(url)] != nil }
    }

    package func contentsOfDirectory(at url: URL) throws -> [URL] {
        MainThreadIOContract.assertOffMainThread("content-fs.contentsOfDirectory")
        let directory = Self.key(url)
        return nodes.withLock { nodes in
            nodes.keys
                .filter { ($0 as NSString).deletingLastPathComponent == directory && $0 != directory }
                .sorted()
                .map { URL(fileURLWithPath: $0) }
        }
    }

    package func write(_ data: Data, to url: URL) throws {
        MainThreadIOContract.assertOffMainThread("content-fs.write")
        try createDirectory(at: url.deletingLastPathComponent())
        nodes.withLock { $0[Self.key(url)] = .file(data) }
    }

    package func read(at url: URL) throws -> Data {
        MainThreadIOContract.assertOffMainThread("content-fs.read")
        return try nodes.withLock { nodes in
            guard case .file(let data)? = nodes[Self.key(url)] else {
                throw GenerationFailure.fileSystem("missing \(url.path)")
            }
            return data
        }
    }

    package func replaceSymbolicLink(at url: URL, destination: URL) throws {
        MainThreadIOContract.assertOffMainThread("content-fs.replaceSymbolicLink")
        try createDirectory(at: url.deletingLastPathComponent())
        nodes.withLock { $0[Self.key(url)] = .link(destination.standardizedFileURL) }
    }

    /// Test inspection: where a link points, nil when absent.
    package func linkDestination(at url: URL) -> URL? {
        nodes.withLock { nodes in
            if case .link(let destination)? = nodes[Self.key(url)] { return destination }
            return nil
        }
    }
}

package final class ScriptedActivationConfirmer: ActivationConfirming, Sendable {
    package enum Step: Sendable {
        case rendered
        case deferredUntilRegionalRender
        /// Never answers; yields to the manager's bounded wait (cancels).
        case never
        /// Never answers and ignores cancellation until `release()` —
        /// simulates a process that dies mid-activation.
        case holdUntilReleased
        case fail(ActivationConfirmationFailure)
    }

    private struct State: Sendable {
        var script: [Step] = []
        var confirmations: [ActivatedGeneration] = []
        var rollbacks: [ActivatedGeneration?] = []
        var held: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package init(script: [Step] = []) {
        state.withLock { $0.script = script }
    }

    package var confirmations: [ActivatedGeneration] { state.withLock { $0.confirmations } }
    package var rollbacks: [ActivatedGeneration?] { state.withLock { $0.rollbacks } }

    package func confirmActivation(of generation: ActivatedGeneration) async throws -> ActivationConfirmation {
        let step = state.withLock { state -> Step in
            state.confirmations.append(generation)
            return state.script.isEmpty ? .rendered : state.script.removeFirst()
        }
        switch step {
        case .rendered:
            return .rendered
        case .deferredUntilRegionalRender:
            return .deferredUntilRegionalRender
        case .never:
            try await Task.sleep(for: .seconds(3600))
            return .rendered
        case .holdUntilReleased:
            await withCheckedContinuation { continuation in
                state.withLock { $0.held.append(continuation) }
            }
            throw CancellationError()
        case .fail(let failure):
            throw GenerationFailure.confirmationFailed(generation.generationID, failure)
        }
    }

    package func submitRollback(for contentID: ContentID, to previous: ActivatedGeneration?) async {
        state.withLock { $0.rollbacks.append(previous) }
    }

    /// Lets every held confirmation finish (as a cancellation).
    package func release() {
        let held = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            let held = state.held
            state.held = []
            return held
        }
        held.forEach { $0.resume() }
    }
}

package struct ClosureGenerationValidator: GenerationValidating {
    private let body: @Sendable (URL, any ContentFileSystem) throws(RejectionReason) -> Void

    package init(_ body: @escaping @Sendable (URL, any ContentFileSystem) throws(RejectionReason) -> Void) {
        self.body = body
    }

    package func validate(directory: URL, fileSystem: any ContentFileSystem) throws(RejectionReason) {
        try body(directory, fileSystem)
    }
}

/// Mounts any directory as a GeoJSON overlay whose entry is `payload.bin`
/// unless a body is supplied; tests that need derivation failures throw.
package struct ClosureContentMounter: ContentMounting {
    private let body: @Sendable (URL, any ContentFileSystem) throws -> ContentMount

    package init(_ body: @escaping @Sendable (URL, any ContentFileSystem) throws -> ContentMount = { directory, _ in
        .geoJSON(directory: directory, entry: directory.appendingPathComponent("payload.bin"))
    }) {
        self.body = body
    }

    package func mount(for directory: URL, fileSystem: any ContentFileSystem) throws -> ContentMount {
        try body(directory, fileSystem)
    }
}
