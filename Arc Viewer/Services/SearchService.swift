//
//  SearchService.swift
//  Arc Viewer
//
//  Read-only query layer over the FTS5 index. All work runs on GRDB's reader
//  pool (WAL snapshot reads), so callers can `await` from @MainActor without
//  blocking the UI. Supports full-text MATCH with bm25 relevance ranking,
//  ordering by date/size, pagination and highlighted snippets.
//

import Foundation
import GRDB

nonisolated struct SearchService: Sendable {
    let dbPool: DatabasePool

    init(database: AppDatabase) { self.dbPool = database.dbPool }

    // Columns selected for every hit (aliases match SearchHit).
    private static let hitColumns = """
        e.rawKey, e.url, e.domain, e.path, e.mime, e.responseTime, \
        e.entryDate, e.dataSize, e.isText
        """

    // Facet WHERE fragments + their bound arguments, shared by search & count.
    private static func facetClause(_ filter: SearchFilter) -> (sql: String, args: [DatabaseValueConvertible]) {
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        if !filter.mimes.isEmpty {
            let list = Array(filter.mimes)
            clauses.append("e.mime IN (\(placeholders(list.count)))")
            args.append(contentsOf: list.map { $0 as DatabaseValueConvertible })
        }
        if !filter.statusCodes.isEmpty {
            let list = Array(filter.statusCodes)
            clauses.append("e.statusCode IN (\(placeholders(list.count)))")
            args.append(contentsOf: list.map { $0 as DatabaseValueConvertible })
        }
        return (clauses.isEmpty ? "" : " AND " + clauses.joined(separator: " AND "), args)
    }

    private static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ", ")
    }

    /// ORDER BY clause for a given order. `ftsRanked` enables bm25 relevance
    /// (only valid when the query joins entry_ft).
    private static func orderClause(_ order: SearchOrder, ftsRanked: Bool) -> String {
        switch order {
        case .relevance:
            return ftsRanked
                ? "bm25(entry_ft, 10.0, 8.0, 6.0, 3.0, 2.0, 1.0)"
                : "COALESCE(e.responseTime, e.entryDate) DESC"   // no text → newest
        case .newest: return "COALESCE(e.responseTime, e.entryDate) DESC"
        case .oldest: return "COALESCE(e.responseTime, e.entryDate) ASC"
        case .alphabetical: return "e.url COLLATE NOCASE ASC"
        }
    }

    /// Runs a query. Empty text (with optional facets) browses; otherwise FTS.
    func search(text: String, filter: SearchFilter, limit: Int, offset: Int) async throws -> [SearchHit] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let facet = Self.facetClause(filter)

        if let match = Self.ftsMatchExpression(trimmed) {
            let sql = """
                SELECT \(Self.hitColumns),
                       snippet(entry_ft, 5, '\u{2}', '\u{3}', '…', 12) AS snippet
                FROM entry_ft
                JOIN entry e ON e.id = entry_ft.rowid
                WHERE entry_ft MATCH ?\(facet.sql)
                ORDER BY \(Self.orderClause(filter.order, ftsRanked: true))
                LIMIT ? OFFSET ?
                """
            let args: [DatabaseValueConvertible] = [match] + facet.args + [limit, offset]
            return try await dbPool.read { db in
                try SearchHit.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
        } else {
            let sql = """
                SELECT \(Self.hitColumns), NULL AS snippet
                FROM entry e
                WHERE 1=1\(facet.sql)
                ORDER BY \(Self.orderClause(filter.order, ftsRanked: false))
                LIMIT ? OFFSET ?
                """
            let args: [DatabaseValueConvertible] = facet.args + [limit, offset]
            return try await dbPool.read { db in
                try SearchHit.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
        }
    }

    /// Total number of matches (for pagination UI).
    func count(text: String, filter: SearchFilter) async throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let facet = Self.facetClause(filter)
        return try await dbPool.read { db in
            if let match = Self.ftsMatchExpression(trimmed) {
                let args: [DatabaseValueConvertible] = [match] + facet.args
                return try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM entry_ft JOIN entry e ON e.id = entry_ft.rowid WHERE entry_ft MATCH ?\(facet.sql)",
                    arguments: StatementArguments(args)) ?? 0
            } else {
                return try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM entry e WHERE 1=1\(facet.sql)",
                    arguments: StatementArguments(facet.args)) ?? 0
            }
        }
    }

    // MARK: - Facets (available filter values)

    func availableMimes(limit: Int = 40) async throws -> [String] {
        try await dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT mime FROM entry
                WHERE mime IS NOT NULL AND mime <> ''
                GROUP BY mime ORDER BY COUNT(*) DESC LIMIT ?
                """, arguments: [limit])
        }
    }

    func availableStatusCodes() async throws -> [Int] {
        try await dbPool.read { db in
            try Int.fetchAll(db, sql: """
                SELECT statusCode FROM entry
                WHERE statusCode IS NOT NULL
                GROUP BY statusCode ORDER BY statusCode
                """)
        }
    }

    /// Lightweight rows (rawKey + entryDate) for the grouped sidebar. Capped to
    /// the most recent `limit` entries — rendering tens of thousands of rows in a
    /// List is neither usable nor cheap; the rest is reachable via search.
    typealias SidebarRow = (rawKey: String, entryDate: Double?, statusCode: Int?, mime: String?)

    /// Number of distinct local calendar days present (dated entries only).
    func distinctDayCount() async throws -> Int {
        try await dbPool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (
                    SELECT 1 FROM entry WHERE entryDate IS NOT NULL
                    GROUP BY date(entryDate, 'unixepoch', 'localtime')
                )
                """) ?? 0
        }
    }

    /// The timestamp cutoff covering the `days` most recent local days: the
    /// smallest entryDate among those days. `entryDate >= cutoff` then yields
    /// exactly those whole days. Returns nil when there are no dated entries.
    func dayCutoff(days: Int) async throws -> Double? {
        try await dbPool.read { db in
            try Double.fetchOne(db, sql: """
                SELECT MIN(entryDate) FROM entry
                WHERE date(entryDate, 'unixepoch', 'localtime') IN (
                    SELECT date(entryDate, 'unixepoch', 'localtime') AS d FROM entry
                    WHERE entryDate IS NOT NULL
                    GROUP BY d ORDER BY MAX(entryDate) DESC LIMIT ?
                )
                """, arguments: [days])
        }
    }

    /// Loads sidebar rows for whole days: everything at/after `cutoff`
    /// (most-recent-first), optionally including undated entries at the tail.
    func browseKeys(cutoff: Double?, includeUndated: Bool) async throws -> [SidebarRow] {
        try await dbPool.read { db in
            let rows: [Row]
            if let cutoff {
                let cond = includeUndated ? "entryDate >= ? OR entryDate IS NULL" : "entryDate >= ?"
                rows = try Row.fetchAll(
                    db, sql: "SELECT rawKey, entryDate, statusCode, mime FROM entry WHERE \(cond) ORDER BY entryDate DESC",
                    arguments: [cutoff])
            } else {
                rows = try Row.fetchAll(
                    db, sql: "SELECT rawKey, entryDate, statusCode, mime FROM entry ORDER BY entryDate DESC")
            }
            return rows.map { (rawKey: $0["rawKey"], entryDate: $0["entryDate"], statusCode: $0["statusCode"], mime: $0["mime"]) }
        }
    }

    /// Total number of indexed entries (for the header count).
    func totalCount() async throws -> Int {
        try await dbPool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry") ?? 0 }
    }

    // MARK: - FTS5 query building

    /// Turns free user text into a safe FTS5 MATCH expression: each token is
    /// quoted (so punctuation is literal) and prefix-matched, combined with AND.
    static func ftsMatchExpression(_ text: String) -> String? {
        let tokens = text
            .components(separatedBy: CharacterSet(charactersIn: " \t\n\r"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"       // prefix match on the quoted term
        }.joined(separator: " ")
    }
}
