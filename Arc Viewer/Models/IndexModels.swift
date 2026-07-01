//
//  IndexModels.swift
//  Arc Viewer
//
//  Models shared by the persistence / indexing / search layers.
//

import Foundation
import GRDB

// MARK: - Persisted entry (main table "entry")

/// One cache entry as stored in SQLite. The searchable text columns
/// (url/domain/path/mime/headers/content) are mirrored into the FTS5 table
/// `entry_ft` (external-content) via triggers, so they are never duplicated.
nonisolated struct IndexedEntry: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "entry"

    var id: Int64?
    var rawKey: String          // the raw Chromium cache key (unique)
    var url: String
    var domain: String
    var path: String
    var method: String
    var mime: String?
    var contentEncoding: String?
    var statusLine: String?
    var requestTime: Double?    // unix seconds
    var responseTime: Double?   // unix seconds
    var entryDate: Double?      // unix seconds (creation/mtime) — used for sorting
    var dataSize: Int           // stored (encoded) body size
    var isText: Bool
    var signature: String       // cheap change-detection token
    var headers: String?        // flattened headers for searching/highlight
    var content: String?        // extracted visible text (nil for binary)
    var bodyLocator: String?    // JSON BlobLocator, to read the raw body later
    var sourceFile: String?     // disk file identity (Simple Cache) for mtime-skip
    var statusCode: Int?        // parsed HTTP status (for filtering)
    var indexedAt: Double

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Search

nonisolated enum SearchOrder: String, CaseIterable, Sendable {
    case relevance = "Relevância"
    case newest = "Mais recente"
    case oldest = "Mais antigo"
    case alphabetical = "Alfabética"
}

/// Ordering + facet filters applied to search / filtered browse.
/// Facets are multi-select: an entry matches if its value is in the chosen set.
nonisolated struct SearchFilter: Equatable, Sendable {
    var order: SearchOrder = .relevance
    var mimes: Set<String> = []
    var statusCodes: Set<Int> = []

    var hasFacet: Bool { !mimes.isEmpty || !statusCodes.isEmpty }
}

/// A row returned by a search/browse query, with an optional highlighted snippet.
nonisolated struct SearchHit: Identifiable, FetchableRecord, Decodable, Sendable {
    var rawKey: String
    var url: String
    var domain: String
    var path: String
    var mime: String?
    var responseTime: Double?
    var entryDate: Double?
    var dataSize: Int
    var isText: Bool
    var snippet: String?

    var id: String { rawKey }
}

// MARK: - Indexing progress

nonisolated struct IndexingProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case idle
        case reading        // "Lendo cache"
        case extracting     // "Extraindo texto"
        case indexing       // "Indexando"
        case updating       // "Atualizando índice"
        case finalizing     // "Finalizando"
        case done           // "Concluído"
        case failed         // "Erro"

        var label: String {
            switch self {
                case .idle: return "Ocioso"
                case .reading: return "Lendo cache"
                case .extracting: return "Extraindo texto"
                case .indexing: return "Indexando"
                case .updating: return "Atualizando índice"
                case .finalizing: return "Finalizando"
                case .done: return "Concluído"
                case .failed: return "Erro"
            }
        }
    }

    var phase: Phase = .idle
    var total: Int = 0
    var processed: Int = 0
    var added: Int = 0
    var updated: Int = 0
    var skipped: Int = 0
    var removed: Int = 0
    var itemsPerSecond: Double = 0
    var etaSeconds: Double?
    var message: String?

    var fraction: Double {
        if phase == .done { return 1 }
        guard total > 0 else { return 0 }
        return min(1, Double(processed) / Double(total))
    }

    var isActive: Bool { phase != .idle && phase != .done && phase != .failed }
}
