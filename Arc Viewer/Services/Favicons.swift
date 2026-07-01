//
//  Favicons.swift
//  Arc Viewer
//
//  Reads the profile's `Favicons` SQLite DB (icon_mapping ⨝ favicon_bitmaps)
//  and maps each page host to its favicon image bytes, so cache entries can be
//  shown with the real site favicon.
//

import Foundation
import GRDB

nonisolated enum FaviconStore {
    /// Returns host → favicon PNG data (largest available bitmap per host).
    /// Hosts are normalised (leading "www." dropped) to improve matching with
    /// the cache's top-frame-site hosts.
    static func load(profileRoot: URL) -> [String: Data] {
        let path = profileRoot.appendingPathComponent("Favicons")
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }

        // Copy (+ wal/shm) to temp so a running browser doesn't block the read.
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ArcViewerFav-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)) != nil else { return [:] }
        defer { try? fm.removeItem(at: tempDir) }
        let tempDB = tempDir.appendingPathComponent("Favicons")
        guard (try? fm.copyItem(at: path, to: tempDB)) != nil else { return [:] }
        for suffix in ["-wal", "-shm"] {
            let src = URL(fileURLWithPath: path.path + suffix)
            if fm.fileExists(atPath: src.path) {
                try? fm.copyItem(at: src, to: URL(fileURLWithPath: tempDB.path + suffix))
            }
        }

        var config = Configuration()
        config.readonly = true
        guard let db = try? DatabaseQueue(path: tempDB.path, configuration: config) else { return [:] }

        var best: [String: (width: Int, data: Data)] = [:]
        _ = try? db.read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT icon_mapping.page_url AS page_url,
                       favicon_bitmaps.image_data AS image_data,
                       favicon_bitmaps.width AS width
                FROM icon_mapping
                JOIN favicon_bitmaps ON favicon_bitmaps.icon_id = icon_mapping.icon_id
                WHERE favicon_bitmaps.image_data IS NOT NULL
                """)
            while let row = try rows.next() {
                guard let data = row["image_data"] as Data?, !data.isEmpty,
                      let pageURL = row["page_url"] as String?,
                      let host = normalizedHost(pageURL) else { continue }
                let width = (row["width"] as Int?) ?? 0
                if let existing = best[host], existing.width >= width { continue }
                best[host] = (width, data)
            }
        }
        return best.mapValues { $0.data }
    }

    static func normalizedHost(_ urlOrHost: String) -> String? {
        var host = URLComponents(string: urlOrHost)?.host ?? urlOrHost
        if let r = host.range(of: "://") { host = String(host[r.upperBound...]) }
        host = host.prefix { $0 != "/" }.description
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host.isEmpty ? nil : host
    }
}
