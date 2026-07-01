//
//  HistoryReader.swift
//  Arc Viewer
//
//  Reads the profile's `History` SQLite DB (visits ⨝ urls), converting the
//  Chrome timestamp to a Date. Port of the reference HistoryAuditor.
//

import Foundation
import GRDB

nonisolated enum HistoryReader {
    /// Default Arc profile (Application Support), where History/Favicons/Local
    /// Storage live — distinct from the cache in ~/Library/Caches.
    static var defaultProfileRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/User Data/Default")
    }

    enum ReadError: LocalizedError {
        case notFound(String)
        var errorDescription: String? {
            switch self { case let .notFound(p): return "Database not found at \(p)" }
        }
    }

    /// The DB is copied to a temp location first so an open browser (holding the
    /// file) doesn't block or corrupt the read.
    static func load(profileRoot: URL, limit: Int = 20_000) throws -> [HistoryEntry] {
        let historyPath = profileRoot.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: historyPath.path) else {
            throw ReadError.notFound(historyPath.path)
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("ArcViewerHistory-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let tempDB = tempDir.appendingPathComponent("History")
        try fm.copyItem(at: historyPath, to: tempDB)
        for suffix in ["-wal", "-shm"] {
            let src = URL(fileURLWithPath: historyPath.path + suffix)
            if fm.fileExists(atPath: src.path) {
                try? fm.copyItem(at: src, to: URL(fileURLWithPath: tempDB.path + suffix))
            }
        }

        var config = Configuration()
        config.readonly = true
        let dbQueue = try DatabaseQueue(path: tempDB.path, configuration: config)

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT visits.id AS id,
                       urls.url AS url,
                       urls.title AS title,
                       visits.visit_time AS timestamp
                FROM visits
                INNER JOIN urls ON visits.url = urls.id
                ORDER BY visits.visit_time DESC
                LIMIT ?
                """, arguments: [limit])
            return rows.map { row in
                let micros = UInt64(bitPattern: row["timestamp"] as Int64? ?? 0)
                return HistoryEntry(
                    id: row["id"],
                    url: row["url"],
                    title: (row["title"] as String?) ?? "",
                    date: decodeChromeTime(micros))
            }
        }
    }
}
