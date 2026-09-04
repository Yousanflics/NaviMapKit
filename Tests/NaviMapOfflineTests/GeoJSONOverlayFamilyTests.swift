//
//  GeoJSONOverlayFamilyTests.swift
//  NaviMapOfflineTests
//
//  The first content family's contract: the three validation checks each
//  reject with their own typed reason, an empty collection declared as
//  empty is valid content, and the mount is derived from the manifest
//  alone. Runs against the in-memory file system on the preparation actor.
//

import Foundation
import NaviMapCore
import NaviMapOffline
import NaviMapTesting
import Testing

@ContentPreparationActor
private enum Fixture {
    static let directory = URL(fileURLWithPath: "/content-root/content/obstacles/generations/g1", isDirectory: true)

    static func collection(_ features: [String]) -> Data {
        Data("""
        {"type":"FeatureCollection","features":[\(features.joined(separator: ","))]}
        """.utf8)
    }

    static let point = """
    {"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[-122.38,37.62]}}
    """
    static let line = """
    {"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[-122.4,37.6],[-122.3,37.7]]}}
    """
    static let badGeometry = """
    {"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[200,95]}}
    """
    /// A collection wrapping an invalid geometry: rejecting it proves the
    /// collection branch does not bypass the geometry check.
    static let collectionWithBadMember = """
    {"type":"Feature","properties":{},"geometry":{"type":"GeometryCollection","geometries":[{"type":"Point","coordinates":[200,95]}]}}
    """
    static let collectionWithoutMembers = """
    {"type":"Feature","properties":{},"geometry":{"type":"GeometryCollection"}}
    """
    static let nullGeometry = """
    {"type":"Feature","properties":{},"geometry":null}
    """

    static func write(_ data: Data, manifest: ContentManifest? = nil) throws -> InMemoryContentFileSystem {
        MainThreadIOViolationRecorder.install()
        let fileSystem = InMemoryContentFileSystem()
        if let manifest {
            try fileSystem.write(data, to: directory.appendingPathComponent(manifest.entry))
            try fileSystem.write(JSONEncoder().encode(manifest), to: directory.appendingPathComponent(ContentManifest.fileName))
        } else {
            try GeoJSONOverlayFamily.write(featureCollection: data, into: directory, fileSystem: fileSystem)
        }
        return fileSystem
    }

    static func rejection(_ fileSystem: InMemoryContentFileSystem) -> RejectionReason? {
        do {
            try GeoJSONOverlayFamily.Validator().validate(directory: directory, fileSystem: fileSystem)
            return nil
        } catch {
            return error
        }
    }
}

@Suite(.serialized)
@ContentPreparationActor
struct GeoJSONOverlayFamilyTests {
    @Test func wellFormedCollectionValidatesAndMounts() throws {
        let fileSystem = try Fixture.write(Fixture.collection([Fixture.point, Fixture.line]))
        #expect(Fixture.rejection(fileSystem) == nil)
        let mount = try GeoJSONOverlayFamily.Mounter().mount(for: Fixture.directory, fileSystem: fileSystem)
        #expect(mount == .geoJSON(directory: Fixture.directory, entry: Fixture.directory.appendingPathComponent("features.geojson")))
        // The family's own writer produced a manifest the validator accepts.
        let manifest = try ContentManifest.read(from: Fixture.directory, fileSystem: fileSystem)
        #expect(manifest.featureCount == 2)
        #expect(manifest.family == GeoJSONOverlayFamily.identifier)
    }

    /// No obstacles in a region is real content, not a failure.
    @Test func emptyCollectionDeclaredEmptyIsValid() throws {
        let fileSystem = try Fixture.write(Fixture.collection([]))
        #expect(Fixture.rejection(fileSystem) == nil)
    }

    @Test func digestMismatchIsAChecksumRejection() throws {
        let data = Fixture.collection([Fixture.point])
        let manifest = ContentManifest(family: GeoJSONOverlayFamily.identifier, entry: "features.geojson",
                                       sha256: String(repeating: "0", count: 64), featureCount: 1)
        let fileSystem = try Fixture.write(data, manifest: manifest)
        #expect(Fixture.rejection(fileSystem) == .checksum)
    }

    @Test func wrongFamilyOrUnparsableEntryIsASchemaRejection() throws {
        let data = Fixture.collection([Fixture.point])
        let wrongFamily = ContentManifest(family: "tile-archive", entry: "features.geojson",
                                          sha256: ContentManifest.hexSHA256(of: data), featureCount: 1)
        #expect(try Fixture.rejection(Fixture.write(data, manifest: wrongFamily)) == .schema)

        let garbage = Data("not geojson".utf8)
        let manifest = ContentManifest(family: GeoJSONOverlayFamily.identifier, entry: "features.geojson",
                                       sha256: ContentManifest.hexSHA256(of: garbage), featureCount: 0)
        #expect(try Fixture.rejection(Fixture.write(garbage, manifest: manifest)) == .schema)

        // No manifest at all.
        let bare = InMemoryContentFileSystem()
        try bare.write(data, to: Fixture.directory.appendingPathComponent("features.geojson"))
        #expect(Fixture.rejection(bare) == .schema)
    }

    @Test func truncationOrInvalidGeometryIsACoverageRejection() throws {
        // Declared two features, file holds one: truncated.
        let one = Fixture.collection([Fixture.point])
        let truncated = ContentManifest(family: GeoJSONOverlayFamily.identifier, entry: "features.geojson",
                                        sha256: ContentManifest.hexSHA256(of: one), featureCount: 2)
        #expect(try Fixture.rejection(Fixture.write(one, manifest: truncated)) == .coverage)

        // Count matches but a geometry is outside the valid range.
        let bad = Fixture.collection([Fixture.badGeometry])
        let counted = ContentManifest(family: GeoJSONOverlayFamily.identifier, entry: "features.geojson",
                                      sha256: ContentManifest.hexSHA256(of: bad), featureCount: 1)
        #expect(try Fixture.rejection(Fixture.write(bad, manifest: counted)) == .coverage)
    }

    /// Geometry collections are refused in this version, and the refusal
    /// must hold for a collection that hides an invalid member, for one
    /// with no members at all, and for a feature without geometry.
    @Test func geometryCollectionsAndNullGeometryAreCoverageRejections() throws {
        for feature in [Fixture.collectionWithBadMember, Fixture.collectionWithoutMembers, Fixture.nullGeometry] {
            let data = Fixture.collection([feature])
            let manifest = ContentManifest(family: GeoJSONOverlayFamily.identifier, entry: "features.geojson",
                                           sha256: ContentManifest.hexSHA256(of: data), featureCount: 1)
            let fileSystem = try Fixture.write(data, manifest: manifest)
            #expect(Fixture.rejection(fileSystem) == .coverage)
        }
    }

    @Test func mountDerivationFailsWithoutAManifest() throws {
        let bare = InMemoryContentFileSystem()
        #expect(throws: GenerationFailure.self) {
            _ = try GeoJSONOverlayFamily.Mounter().mount(for: Fixture.directory, fileSystem: bare)
        }
    }
}
