//
//  ContentFileSystem.swift
//  NaviMapOffline
//
//  The directory layout and the file-system seam the
//  generation manager writes through. The seam exists so the state
//  machine's failure paths are testable against an in-memory tree with a
//  real registry; the local implementation is a thin FileManager wrapper
//  whose every call passes the main-thread I/O contract hook.
//

import Foundation
import NaviMapCore

package struct ContentLayout: Sendable, Equatable {
    package var root: URL

    package init(root: URL) {
        self.root = root
    }

    package func contentDirectory(_ contentID: ContentID) -> URL {
        root.appendingPathComponent("content", isDirectory: true)
            .appendingPathComponent(contentID.rawValue, isDirectory: true)
    }

    package func generationsDirectory(_ contentID: ContentID) -> URL {
        contentDirectory(contentID).appendingPathComponent("generations", isDirectory: true)
    }

    package func generationDirectory(_ contentID: ContentID, _ generationID: GenerationID) -> URL {
        generationsDirectory(contentID).appendingPathComponent(generationID.rawValue, isDirectory: true)
    }

    package func stagingDirectory(_ contentID: ContentID) -> URL {
        contentDirectory(contentID).appendingPathComponent("staging", isDirectory: true)
    }

    package func stagingDirectory(_ contentID: ContentID, _ stagingID: UUID) -> URL {
        stagingDirectory(contentID).appendingPathComponent(stagingID.uuidString, isDirectory: true)
    }

    /// The derived pointer: never authoritative,
    /// rebuilt from the registry unconditionally at startup.
    package func currentLink(_ contentID: ContentID) -> URL {
        contentDirectory(contentID).appendingPathComponent("current", isDirectory: false)
    }

    package func directory(for record: GenerationRecord) -> URL {
        switch record.location {
        case .staging(let stagingID):
            stagingDirectory(record.contentID, stagingID)
        case .generations:
            generationDirectory(record.contentID, record.generationID)
        }
    }
}

package protocol ContentFileSystem: Sendable {
    func createDirectory(at url: URL) throws
    /// Atomic rename; the destination must not exist.
    func moveItem(at source: URL, to destination: URL) throws
    /// No error when the item does not exist.
    func removeItem(at url: URL) throws
    func itemExists(at url: URL) -> Bool
    /// Direct children; empty when the directory does not exist.
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func write(_ data: Data, to url: URL) throws
    func read(at url: URL) throws -> Data
    /// Replace (or create) the symbolic link at `url` pointing to
    /// `destination`.
    func replaceSymbolicLink(at url: URL, destination: URL) throws
}

package struct LocalContentFileSystem: ContentFileSystem {
    package init() {}

    package func createDirectory(at url: URL) throws {
        MainThreadIOContract.assertOffMainThread("content-fs.createDirectory")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    package func moveItem(at source: URL, to destination: URL) throws {
        MainThreadIOContract.assertOffMainThread("content-fs.moveItem")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: destination)
    }

    package func removeItem(at url: URL) throws {
        MainThreadIOContract.assertOffMainThread("content-fs.removeItem")
        guard itemExists(at: url) else { return }
        try FileManager.default.removeItem(at: url)
    }

    package func itemExists(at url: URL) -> Bool {
        MainThreadIOContract.assertOffMainThread("content-fs.itemExists")
        return FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    package func contentsOfDirectory(at url: URL) throws -> [URL] {
        MainThreadIOContract.assertOffMainThread("content-fs.contentsOfDirectory")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    package func write(_ data: Data, to url: URL) throws {
        MainThreadIOContract.assertOffMainThread("content-fs.write")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    package func read(at url: URL) throws -> Data {
        MainThreadIOContract.assertOffMainThread("content-fs.read")
        return try Data(contentsOf: url)
    }

    package func replaceSymbolicLink(at url: URL, destination: URL) throws {
        MainThreadIOContract.assertOffMainThread("content-fs.replaceSymbolicLink")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
    }
}
