//
//  AppDatabase.swift
//  Arc Viewer
//
//  GRDB persistence layer: a WAL-backed DatabasePool (concurrent reads while a
//  single writer runs), the schema migrations, and the FTS5 full-text index.
//
//  Design notes
//  ------------
//  * `DatabasePool` (not `DatabaseQueue`) so search reads never block on the
//    indexer's writes — readers see the last committed WAL snapshot.
//  * The main `entry` table is the source of truth and holds the searchable
//    text columns. `entry_ft` is an **external-content** FTS5 table: it stores
//    only the inverted index (no copy of the text) and is kept in sync with
//    `entry` by triggers that GRDB generates via `synchronize(withTable:)`.
//    `snippet()`/`highlight()` read the original text back from `entry`.
//  * Auxiliary B-tree indexes accelerate the non-FTS sorts/filters
//    (domain, entryDate, responseTime, dataSize).
//  * One database file per cache directory (keyed by a hash of its path) so
//    switching cache folders never mixes entries.
//

import Foundation
import GRDB
import CryptoKit

nonisolated final class AppDatabase: Sendable {
    let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Opens (creating if needed) the index database for a given cache directory.
    static func make(forCacheDirectory cacheDir: URL) throws -> AppDatabase {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("ArcViewer/Index", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Stable per-cache filename. NOTE: String.hashValue is randomized per
        // process, so it must NOT be used here — use a stable digest instead,
        // otherwise every launch gets a fresh DB and re-indexes from scratch.
        let digest = SHA256.hash(data: Data(cacheDir.path.utf8))
        let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let dbURL = folder.appendingPathComponent("cache-\(key).sqlite")

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")   // WAL + NORMAL: fast & crash-safe
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA mmap_size = 67108864")   // 64 MB mmap (keeps RSS modest)
            try db.execute(sql: "PRAGMA cache_size = -8000")     // ~8 MB page cache
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let pool = try DatabasePool(path: dbURL.path, configuration: config)
        try migrator.migrate(pool)
        return AppDatabase(dbPool: pool)
    }

    /// Test/in-memory database.
    static func makeInMemory() throws -> AppDatabase {
        let pool = try DatabaseQueue()
        try migrator.migrate(pool)
        return AppDatabase(dbPool: try DatabasePool(path: ":memory:"))
    }

    // MARK: - Migrations

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // During development, wipe & rebuild if the schema changes.
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1.createSchema") { db in
            try db.create(table: "entry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("rawKey", .text).notNull().unique(onConflict: .replace)
                t.column("url", .text).notNull().defaults(to: "")
                t.column("domain", .text).notNull().defaults(to: "")
                t.column("path", .text).notNull().defaults(to: "")
                t.column("method", .text).notNull().defaults(to: "GET")
                t.column("mime", .text)
                t.column("contentEncoding", .text)
                t.column("statusLine", .text)
                t.column("requestTime", .double)
                t.column("responseTime", .double)
                t.column("entryDate", .double)
                t.column("dataSize", .integer).notNull().defaults(to: 0)
                t.column("isText", .boolean).notNull().defaults(to: false)
                t.column("signature", .text).notNull().defaults(to: "")
                t.column("headers", .text)
                t.column("content", .text)
                t.column("bodyLocator", .text)
                t.column("sourceFile", .text)   // disk identity (Simple Cache): fast mtime-skip
                t.column("statusCode", .integer)
                t.column("indexedAt", .double).notNull().defaults(to: 0)
            }

            // Auxiliary indexes for non-FTS sorting/filtering.
            try db.create(index: "idx_entry_domain", on: "entry", columns: ["domain"])
            try db.create(index: "idx_entry_entryDate", on: "entry", columns: ["entryDate"])
            try db.create(index: "idx_entry_responseTime", on: "entry", columns: ["responseTime"])
            try db.create(index: "idx_entry_dataSize", on: "entry", columns: ["dataSize"])
            try db.create(index: "idx_entry_mime", on: "entry", columns: ["mime"])
            try db.create(index: "idx_entry_status", on: "entry", columns: ["statusCode"])

            // FTS5 external-content table, synchronized with `entry`.
            try db.create(virtualTable: "entry_ft", using: FTS5()) { t in
                t.synchronize(withTable: "entry")
                t.tokenizer = .unicode61()      // case/diacritics-insensitive
                t.column("url")
                t.column("domain")
                t.column("path")
                t.column("mime")
                t.column("headers")
                t.column("content")
            }
        }

        return migrator
    }

    // MARK: - Convenience reads

    func entryCount() async throws -> Int {
        try await dbPool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry") ?? 0 }
    }

    /// rawKey -> (id, signature) for incremental change detection.
    func existingSignatures() async throws -> [String: (id: Int64, signature: String)] {
        try await dbPool.read { db in
            var map: [String: (Int64, String)] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT id, rawKey, signature FROM entry")
            while let row = try rows.next() {
                let rawKey: String = row["rawKey"]
                map[rawKey] = (row["id"], row["signature"])
            }
            return map
        }
    }

    func fetchEntry(rawKey: String) async throws -> IndexedEntry? {
        try await dbPool.read { db in
            try IndexedEntry.filter(Column("rawKey") == rawKey).fetchOne(db)
        }
    }

    /// Removes all indexed entries (the FTS index is cleared via triggers).
    func clear() async throws {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM entry")
        }
    }
}
