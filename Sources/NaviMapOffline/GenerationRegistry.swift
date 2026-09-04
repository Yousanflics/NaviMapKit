//
//  GenerationRegistry.swift
//  NaviMapOffline
//
//  The single authority for generation state:
//  a SQLite registry with one writer, the generation manager, on the
//  content-preparation executor. Directory contents and the derived
//  `current` link are reconciled against this table at startup; when they
//  disagree the registry wins. Every entry point asserts the preparation
//  context and passes the main-thread I/O contract hook.
//

import Foundation
import NaviMapCore
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@ContentPreparationActor
package final class GenerationRegistry {
    package static let schemaVersion: Int32 = 2

    package let fileURL: URL
    private var db: OpaquePointer?

    package init(fileURL: URL) throws {
        ContentPreparationActor.assertPreparationContext("content-registry.open")
        self.fileURL = fileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            fileURL.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil
        ) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw GenerationFailure.registry(message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)
        try migrate()
    }

    package func close() {
        ContentPreparationActor.assertPreparationContext("content-registry.close")
        if let db {
            sqlite3_close(db)
        }
        db = nil
    }

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS generations(
            content_id TEXT NOT NULL,
            generation_id TEXT NOT NULL,
            state TEXT NOT NULL,
            location TEXT NOT NULL,
            leased INTEGER NOT NULL DEFAULT 0,
            lease_scope TEXT,
            confirmed INTEGER NOT NULL DEFAULT 0,
            sequence INTEGER NOT NULL,
            installed_at REAL NOT NULL,
            rejection_reason TEXT,
            PRIMARY KEY(content_id, generation_id)
        );
        CREATE TABLE IF NOT EXISTS current_generation(
            content_id TEXT PRIMARY KEY,
            generation_id TEXT NOT NULL
        );
        """)
        let versions = try query("SELECT version FROM schema_version") { Int32(sqlite3_column_int($0, 0)) }
        if versions.isEmpty {
            try exec("INSERT INTO schema_version(version) VALUES (\(Self.schemaVersion))")
        } else if let version = versions.first, version != Self.schemaVersion {
            guard version == 1 else {
                throw GenerationFailure.registry("unsupported registry schema version \(version)")
            }
            // Version 1 predates the persistent rejection reason.
            try exec("ALTER TABLE generations ADD COLUMN rejection_reason TEXT")
            try exec("UPDATE schema_version SET version = \(Self.schemaVersion)")
        }
    }

    // MARK: Records

    package func contentIDs() throws -> [ContentID] {
        ContentPreparationActor.assertPreparationContext("content-registry.contentIDs")
        return try query("SELECT DISTINCT content_id FROM generations ORDER BY content_id") {
            ContentID(Self.text($0, 0))
        }
    }

    package func records(for contentID: ContentID) throws -> [GenerationRecord] {
        ContentPreparationActor.assertPreparationContext("content-registry.records")
        return try query(
            "SELECT \(Self.columns) FROM generations WHERE content_id = ? ORDER BY sequence",
            bindings: [.text(contentID.rawValue)],
            map: Self.record(from:)
        )
    }

    package func record(contentID: ContentID, generationID: GenerationID) throws -> GenerationRecord? {
        ContentPreparationActor.assertPreparationContext("content-registry.record")
        return try query(
            "SELECT \(Self.columns) FROM generations WHERE content_id = ? AND generation_id = ?",
            bindings: [.text(contentID.rawValue), .text(generationID.rawValue)],
            map: Self.record(from:)
        ).first
    }

    /// Assigns the next sequence number and returns the stored record.
    @discardableResult
    package func insert(_ record: GenerationRecord) throws -> GenerationRecord {
        ContentPreparationActor.assertPreparationContext("content-registry.insert")
        let next = try query("SELECT COALESCE(MAX(sequence), 0) + 1 FROM generations") {
            sqlite3_column_int64($0, 0)
        }.first ?? 1
        var stored = record
        stored.sequence = next
        try run(
            """
            INSERT INTO generations(content_id, generation_id, state, location, leased, lease_scope,
                                    confirmed, sequence, installed_at, rejection_reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: Self.bindings(for: stored)
        )
        return stored
    }

    package func update(_ record: GenerationRecord) throws {
        ContentPreparationActor.assertPreparationContext("content-registry.update")
        var bindings = Self.bindings(for: record)
        bindings.removeFirst(2)
        bindings.append(.text(record.contentID.rawValue))
        bindings.append(.text(record.generationID.rawValue))
        try run(
            """
            UPDATE generations SET state = ?, location = ?, leased = ?, lease_scope = ?, confirmed = ?,
                                   sequence = ?, installed_at = ?, rejection_reason = ?
            WHERE content_id = ? AND generation_id = ?
            """,
            bindings: bindings
        )
        guard sqlite3_changes(db) == 1 else {
            throw GenerationFailure.unknownGeneration(record.generationID)
        }
    }

    package func delete(contentID: ContentID, generationID: GenerationID) throws {
        ContentPreparationActor.assertPreparationContext("content-registry.delete")
        try run(
            "DELETE FROM generations WHERE content_id = ? AND generation_id = ?",
            bindings: [.text(contentID.rawValue), .text(generationID.rawValue)]
        )
    }

    // MARK: Current pointer (authoritative; the symlink is derived)

    package func currentGeneration(for contentID: ContentID) throws -> GenerationID? {
        ContentPreparationActor.assertPreparationContext("content-registry.current")
        return try query(
            "SELECT generation_id FROM current_generation WHERE content_id = ?",
            bindings: [.text(contentID.rawValue)]
        ) { GenerationID(Self.text($0, 0)) }.first
    }

    package func setCurrentGeneration(_ generationID: GenerationID?, for contentID: ContentID) throws {
        ContentPreparationActor.assertPreparationContext("content-registry.setCurrent")
        if let generationID {
            try run(
                """
                INSERT INTO current_generation(content_id, generation_id) VALUES (?, ?)
                ON CONFLICT(content_id) DO UPDATE SET generation_id = excluded.generation_id
                """,
                bindings: [.text(contentID.rawValue), .text(generationID.rawValue)]
            )
        } else {
            try run(
                "DELETE FROM current_generation WHERE content_id = ?",
                bindings: [.text(contentID.rawValue)]
            )
        }
    }

    // MARK: Transactions

    /// Immediate transaction: every activation step that must be atomic
    /// runs inside one of these.
    package func transaction<T>(_ body: () throws -> T) throws -> T {
        ContentPreparationActor.assertPreparationContext("content-registry.transaction")
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: SQLite plumbing

    private enum Binding {
        case text(String)
        case optionalText(String?)
        case int(Int64)
        case double(Double)
    }

    private static let columns =
        "content_id, generation_id, state, location, leased, lease_scope, confirmed, sequence, installed_at, rejection_reason"

    private static func bindings(for record: GenerationRecord) -> [Binding] {
        [
            .text(record.contentID.rawValue),
            .text(record.generationID.rawValue),
            .text(record.state.rawValue),
            .text(encode(record.location)),
            .int(record.isLeased ? 1 : 0),
            .optionalText(record.leaseScope),
            .int(record.isConfirmed ? 1 : 0),
            .int(record.sequence),
            .double(record.installedAt.instant.timeIntervalSince1970),
            .optionalText(record.rejectionReason.map(encode)),
        ]
    }

    private static func record(from statement: OpaquePointer) throws -> GenerationRecord {
        guard let state = GenerationState(rawValue: text(statement, 2)),
              let location = decodeLocation(text(statement, 3))
        else {
            throw GenerationFailure.registry("corrupt generation row")
        }
        return GenerationRecord(
            contentID: ContentID(text(statement, 0)),
            generationID: GenerationID(text(statement, 1)),
            state: state,
            location: location,
            isLeased: sqlite3_column_int(statement, 4) != 0,
            leaseScope: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : text(statement, 5),
            isConfirmed: sqlite3_column_int(statement, 6) != 0,
            sequence: sqlite3_column_int64(statement, 7),
            installedAt: InstalledAt(instant: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))),
            rejectionReason: sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : decodeReason(text(statement, 9))
        )
    }

    private static func encode(_ reason: RejectionReason) -> String {
        switch reason {
        case .checksum: "checksum"
        case .schema: "schema"
        case .coverage: "coverage"
        }
    }

    private static func decodeReason(_ raw: String) -> RejectionReason? {
        switch raw {
        case "checksum": .checksum
        case "schema": .schema
        case "coverage": .coverage
        default: nil
        }
    }

    private static func encode(_ location: GenerationLocation) -> String {
        switch location {
        case .staging(let stagingID): "staging:\(stagingID.uuidString)"
        case .generations: "generations"
        }
    }

    private static func decodeLocation(_ raw: String) -> GenerationLocation? {
        if raw == "generations" { return .generations }
        guard raw.hasPrefix("staging:"), let uuid = UUID(uuidString: String(raw.dropFirst("staging:".count))) else {
            return nil
        }
        return .staging(uuid)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw GenerationFailure.registry("registry closed") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorPointer)
            throw GenerationFailure.registry(message)
        }
    }

    private func prepare(_ sql: String, bindings: [Binding]) throws -> OpaquePointer {
        guard let db else { throw GenerationFailure.registry("registry closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw GenerationFailure.registry(String(cString: sqlite3_errmsg(db)))
        }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value):
                sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case .optionalText(let value):
                if let value {
                    sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case .int(let value):
                sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                sqlite3_bind_double(statement, index, value)
            }
        }
        return statement
    }

    private func run(_ sql: String, bindings: [Binding] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw GenerationFailure.registry(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query<T>(
        _ sql: String,
        bindings: [Binding] = [],
        map: (OpaquePointer) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                try rows.append(map(statement))
            } else if status == SQLITE_DONE {
                return rows
            } else {
                throw GenerationFailure.registry(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}
