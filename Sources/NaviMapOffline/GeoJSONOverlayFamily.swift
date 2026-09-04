//
//  GeoJSONOverlayFamily.swift
//  NaviMapOffline
//
//  The GeoJSON overlay content family: a generation directory holding a
//  manifest and one GeoJSON feature collection. Validation checks the
//  manifest against the entry file (checksum), the shape of both (schema),
//  and completeness against the declared feature count (coverage); an
//  empty collection declared as empty is valid content. Every feature must
//  carry a renderable geometry: a null geometry and geometry collections
//  are rejected as coverage failures in this version. The family also
//  derives the render mount from a directory, which the manager does on the
//  preparation actor whenever a generation is handed out.
//

import CryptoKit
import Foundation
import NaviMapCore

/// The manifest every content family writes into its generation directory.
package struct ContentManifest: Codable, Sendable, Equatable {
    package static let fileName = "manifest.json"
    package static let currentSchemaVersion = 1

    package var schemaVersion: Int
    package var family: String
    /// Entry file name, relative to the generation directory.
    package var entry: String
    /// Hex SHA-256 of the entry file.
    package var sha256: String
    /// Features the entry file must contain; zero is a valid declaration.
    package var featureCount: Int

    package init(schemaVersion: Int = ContentManifest.currentSchemaVersion,
                 family: String, entry: String, sha256: String, featureCount: Int) {
        self.schemaVersion = schemaVersion
        self.family = family
        self.entry = entry
        self.sha256 = sha256
        self.featureCount = featureCount
    }

    package static func read(from directory: URL, fileSystem: any ContentFileSystem) throws(RejectionReason) -> ContentManifest {
        let data: Data
        do {
            data = try fileSystem.read(at: directory.appendingPathComponent(fileName))
        } catch {
            throw .schema
        }
        guard let manifest = try? JSONDecoder().decode(ContentManifest.self, from: data),
              manifest.schemaVersion == currentSchemaVersion,
              !manifest.entry.isEmpty, !manifest.entry.contains("/"), manifest.featureCount >= 0
        else { throw .schema }
        return manifest
    }

    package static func hexSHA256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

package enum GeoJSONOverlayFamily {
    package static let identifier = "geojson-overlay"

    /// Validates a generation directory; runs on the preparation actor.
    package struct Validator: GenerationValidating {
        package init() {}

        package func validate(directory: URL, fileSystem: any ContentFileSystem) throws(RejectionReason) {
            let manifest = try ContentManifest.read(from: directory, fileSystem: fileSystem)
            guard manifest.family == identifier else { throw .schema }
            let data: Data
            do {
                data = try fileSystem.read(at: directory.appendingPathComponent(manifest.entry))
            } catch {
                throw .schema
            }
            guard ContentManifest.hexSHA256(of: data) == manifest.sha256.lowercased() else { throw .checksum }
            let features = try GeoJSONOverlayFamily.features(in: data)
            guard features.count == manifest.featureCount else { throw .coverage }
            for feature in features {
                guard GeoJSONOverlayFamily.isValidGeometry(feature["geometry"]) else { throw .coverage }
            }
        }
    }

    /// Derives the mount from a validated directory; runs on the
    /// preparation actor. Only the manifest is read.
    package struct Mounter: ContentMounting {
        package init() {}

        package func mount(for directory: URL, fileSystem: any ContentFileSystem) throws -> ContentMount {
            let manifest: ContentManifest
            do {
                manifest = try ContentManifest.read(from: directory, fileSystem: fileSystem)
            } catch {
                throw GenerationFailure.fileSystem("manifest unreadable at \(directory.path)")
            }
            guard manifest.family == identifier else {
                throw GenerationFailure.fileSystem("not a \(identifier) generation at \(directory.path)")
            }
            return .geoJSON(directory: directory, entry: directory.appendingPathComponent(manifest.entry))
        }
    }

    /// Writes a generation directory in the family's shape from a feature
    /// collection; the manifest is derived from the data. This packages, it
    /// does not validate: the validator decides whether the result is
    /// acceptable content.
    package static func write(featureCollection data: Data, into directory: URL,
                              fileSystem: any ContentFileSystem) throws {
        let features = try features(in: data)
        let manifest = ContentManifest(
            family: identifier, entry: "features.geojson",
            sha256: ContentManifest.hexSHA256(of: data), featureCount: features.count
        )
        try fileSystem.write(data, to: directory.appendingPathComponent(manifest.entry))
        try fileSystem.write(JSONEncoder().encode(manifest), to: directory.appendingPathComponent(ContentManifest.fileName))
    }

    // MARK: Schema

    static func features(in data: Data) throws(RejectionReason) -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "FeatureCollection",
              let features = object["features"] as? [[String: Any]]
        else { throw .schema }
        for feature in features where feature["type"] as? String != "Feature" {
            throw .schema
        }
        return features
    }

    static func isValidGeometry(_ value: Any?) -> Bool {
        guard let geometry = value as? [String: Any], let type = geometry["type"] as? String else { return false }
        // Geometry collections are not accepted by this version of the family.
        guard let coordinates = geometry["coordinates"] else { return false }
        switch type {
        case "Point": return isPosition(coordinates)
        case "MultiPoint", "LineString": return isPositionList(coordinates, minimum: type == "LineString" ? 2 : 1)
        case "MultiLineString": return (coordinates as? [Any])?.allSatisfy { isPositionList($0, minimum: 2) } ?? false
        case "Polygon": return isRingList(coordinates)
        case "MultiPolygon": return (coordinates as? [Any])?.allSatisfy { isRingList($0) } ?? false
        default: return false
        }
    }

    private static func isPosition(_ value: Any) -> Bool {
        guard let numbers = value as? [Double], numbers.count >= 2 else { return false }
        return abs(numbers[1]) <= 90 && abs(numbers[0]) <= 180
    }

    private static func isPositionList(_ value: Any, minimum: Int) -> Bool {
        guard let list = value as? [Any], list.count >= minimum else { return false }
        return list.allSatisfy(isPosition)
    }

    private static func isRingList(_ value: Any) -> Bool {
        guard let rings = value as? [Any], !rings.isEmpty else { return false }
        return rings.allSatisfy { isPositionList($0, minimum: 4) }
    }
}
