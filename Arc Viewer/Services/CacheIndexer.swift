//
//  CacheIndexer.swift
//  Arc Viewer
//
//  Off-main indexing pipeline (an `actor`). Progress streams back to the UI via
//  a @Sendable @MainActor callback.
//
//  Startup latency
//  ---------------
//  The Simple Cache (used by Arc) stores one file per entry. Opening the whole
//  cache eagerly would stat+parse tens of thousands of files *before* any
//  progress — a long "dead" wait every launch. Instead, for the Simple Cache we
//  enumerate the directory once (cheap, with modification dates) and only OPEN a
//  file when it is new or its mtime changed vs. the DB. Unchanged files are
//  skipped without being opened, so re-launches are near-instant.
//
//  The Blockfile cache enumerates through its in-memory index (a handful of
//  mmap'd data_N files), which is already fast, so it uses the reader directly.
//

import Foundation
import GRDB

actor CacheIndexer {
    private let dbPool: DatabasePool
    private let batchSize = 150   // bounds peak memory (each record may hold extracted text)

    init(database: AppDatabase) { self.dbPool = database.dbPool }

    private static let simpleFilePattern = try! NSRegularExpression(pattern: "^[0-9a-f]{16}_0$")

    func index(
        cacheDirectory: URL,
        onProgress: @escaping @Sendable @MainActor (IndexingProgress) -> Void
    ) async {
        switch guessCacheClass(cacheDir: cacheDirectory) {
        case .simple:
            await indexSimple(cacheDirectory, onProgress: onProgress)
        case .blockFile:
            await indexBlockFile(cacheDirectory, onProgress: onProgress)
        case nil:
            var p = IndexingProgress(phase: .failed)
            p.message = "Formato de cache não reconhecido"
            await MainActor.run { onProgress(p) }
        }
    }

    // MARK: - Simple Cache (fast, mtime-based incremental)

    private func indexSimple(
        _ dir: URL, onProgress: @escaping @Sendable @MainActor (IndexingProgress) -> Void
    ) async {
        let start = Date()
        var progress = IndexingProgress(phase: .reading)
        await MainActor.run { onProgress(progress) }

        // 1. Cheap directory listing with modification dates.
        let files: [(url: URL, mtime: Double, name: String)]
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            files = contents.compactMap { url in
                let name = url.lastPathComponent
                let range = NSRange(name.startIndex..., in: name)
                guard Self.simpleFilePattern.firstMatch(in: name, range: range) != nil else { return nil }
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                return (url, mtime, name)
            }
        } catch {
            progress.phase = .failed; progress.message = error.localizedDescription
            await MainActor.run { [progress] in onProgress(progress) }
            return
        }

        progress.total = files.count
        await MainActor.run { [progress] in onProgress(progress) }

        // 2. What's already indexed: sourceFile -> (id, signature=mtime).
        let existing = (try? await dbPool.read { db -> [String: (Int64, String)] in
            var map: [String: (Int64, String)] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT id, sourceFile, signature FROM entry WHERE sourceFile IS NOT NULL")
            while let row = try rows.next() {
                if let sf: String = row["sourceFile"] { map[sf] = (row["id"], row["signature"]) }
            }
            return map
        }) ?? [:]

        var seen = Set<String>(); seen.reserveCapacity(files.count)
        var batch: [IndexedEntry] = []; batch.reserveCapacity(batchSize)
        var lastEmit = Date.distantPast

        for file in files {
            seen.insert(file.name)
            let token = String(file.mtime)

            if let e = existing[file.name], e.1 == token {
                progress.skipped += 1
            } else {
                let isUpdate = existing[file.name] != nil
                progress.phase = .indexing
                // autoreleasepool drains transient Data/String buffers per file,
                // so peak memory stays flat over a long indexing loop.
                let record = autoreleasepool {
                    Self.buildSimpleRecord(file: file.url, name: file.name, mtime: file.mtime, id: existing[file.name]?.0)
                }
                if let record {
                    batch.append(record)
                    if isUpdate { progress.updated += 1 } else { progress.added += 1 }
                }
                if batch.count >= batchSize { await flush(&batch) }
            }
            progress.processed += 1
            await emitThrottled(&progress, start: start, last: &lastEmit, onProgress: onProgress)
        }
        await flush(&batch)

        progress.removed = await deleteMissing(column: "sourceFile", keep: seen, from: existing.keys)
        progress.phase = .done
        await MainActor.run { [progress] in onProgress(progress) }
    }

    private static func buildSimpleRecord(file: URL, name: String, mtime: Double, id: Int64?) -> IndexedEntry? {
        guard let cf = try? SimpleCacheFile(path: file) else { return nil }
        let key = cf.key

        var meta: CachedMetadata? = nil
        if cf.hasData, let buffer = try? cf.getStream0(), !buffer.isEmpty {
            meta = (try? CachedMetadata.from(buffer: buffer)) ?? (try? CachedMetadata.fromCodeCache(buffer: buffer))
        }
        let fields = entryFields(rawKey: key, meta: meta)

        var content: String? = nil
        if fields.isText, cf.hasData, let raw = try? cf.getStream1(), !raw.isEmpty {
            let decoded = ContentDecoding.decode(raw, contentEncoding: fields.encoding)
            content = TextExtractor.extractText(from: decoded, mime: fields.mime, path: fields.path)
        }

        let locator = BlobLocator.simpleStream1(file: file.path)
        let locatorJSON = (try? JSONEncoder().encode(locator)).flatMap { String(data: $0, encoding: .utf8) }

        return IndexedEntry(
            id: id, rawKey: key, url: fields.url, domain: fields.domain, path: fields.path,
            method: fields.method, mime: fields.mime, contentEncoding: fields.encoding,
            statusLine: meta?.statusLine, requestTime: meta?.requestTime?.timeIntervalSince1970,
            responseTime: meta?.responseTime.timeIntervalSince1970,
            entryDate: mtime, dataSize: cf.hasData ? cf.stream1Length : 0, isText: fields.isText,
            signature: String(mtime), headers: fields.headers, content: content,
            bodyLocator: locatorJSON, sourceFile: name, statusCode: fields.statusCode,
            indexedAt: Date().timeIntervalSince1970)
    }

    // MARK: - Blockfile cache (via the in-memory index)

    private func indexBlockFile(
        _ dir: URL, onProgress: @escaping @Sendable @MainActor (IndexingProgress) -> Void
    ) async {
        let start = Date()
        var progress = IndexingProgress(phase: .reading)
        await MainActor.run { onProgress(progress) }

        guard let cache = try? openChromiumCache(cacheDir: dir) else {
            progress.phase = .failed; progress.message = "Não foi possível abrir o cache"
            await MainActor.run { [progress] in onProgress(progress) }
            return
        }
        let keys = cache.keys()
        progress.total = keys.count
        await MainActor.run { [progress] in onProgress(progress) }

        let existing = (try? await dbPool.read { db -> [String: (Int64, String)] in
            var map: [String: (Int64, String)] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT id, rawKey, signature FROM entry")
            while let row = try rows.next() { map[row["rawKey"]] = (row["id"], row["signature"]) }
            return map
        }) ?? [:]

        var seen = Set<String>(); seen.reserveCapacity(keys.count)
        var batch: [IndexedEntry] = []; batch.reserveCapacity(batchSize)
        var lastEmit = Date.distantPast

        for key in keys {
            seen.insert(key)
            let token = cache.changeToken(key)
            if let e = existing[key], e.1 == token {
                progress.skipped += 1
            } else {
                let isUpdate = existing[key] != nil
                progress.phase = .indexing
                let record = autoreleasepool {
                    Self.buildBlockRecord(cache: cache, key: key, token: token, id: existing[key]?.0)
                }
                batch.append(record)
                if isUpdate { progress.updated += 1 } else { progress.added += 1 }
                if batch.count >= batchSize { await flush(&batch) }
            }
            progress.processed += 1
            await emitThrottled(&progress, start: start, last: &lastEmit, onProgress: onProgress)
        }
        await flush(&batch)

        progress.removed = await deleteMissing(column: "rawKey", keep: seen, from: existing.keys)
        progress.phase = .done
        await MainActor.run { [progress] in onProgress(progress) }
    }

    private static func buildBlockRecord(cache: ChromiumCache, key: String, token: String, id: Int64?) -> IndexedEntry {
        let meta = (try? cache.getMetadata(key))?.first ?? nil
        let fields = entryFields(rawKey: key, meta: meta)
        var content: String? = nil
        if fields.isText, let raw = (try? cache.getCachefile(key))?.first ?? nil, !raw.isEmpty {
            let decoded = ContentDecoding.decode(raw, contentEncoding: fields.encoding)
            content = TextExtractor.extractText(from: decoded, mime: fields.mime, path: fields.path)
        }
        let locator = cache.cachefileLocator(key)
        let locatorJSON = locator.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }

        return IndexedEntry(
            id: id, rawKey: key, url: fields.url, domain: fields.domain, path: fields.path,
            method: fields.method, mime: fields.mime, contentEncoding: fields.encoding,
            statusLine: meta?.statusLine, requestTime: meta?.requestTime?.timeIntervalSince1970,
            responseTime: meta?.responseTime.timeIntervalSince1970,
            entryDate: cache.entryDate(key)?.timeIntervalSince1970,
            dataSize: cache.bodySize(key), isText: fields.isText, signature: token,
            headers: fields.headers, content: content, bodyLocator: locatorJSON,
            sourceFile: nil, statusCode: fields.statusCode, indexedAt: Date().timeIntervalSince1970)
    }

    // MARK: - Shared helpers

    private struct EntryFields {
        var url: String; var domain: String; var path: String; var method: String
        var mime: String?; var encoding: String?; var headers: String?; var isText: Bool
        var statusCode: Int?
    }

    private static func entryFields(rawKey: String, meta: CachedMetadata?) -> EntryFields {
        let cacheKey = CacheKey(rawKey)
        let url = cacheKey.url
        let comps = URLComponents(string: url)
        let domain = comps?.host ?? fallbackDomain(url)
        var path = comps?.path ?? ""
        if let q = comps?.query, !q.isEmpty { path += "?\(q)" }
        if path.isEmpty { path = "/" }
        let mime = meta?.attribute("content-type").first.map(normaliseMime)
        let encoding = meta?.attribute("content-encoding").first
        let method = (cacheKey.uploadDataIdentifier ?? 0) != 0 ? "POST" : "GET"
        let headers = meta.map(flattenHeaders)
        let isText = TextExtractor.classify(mime: mime, path: path).isText
        return EntryFields(url: url, domain: domain, path: path, method: method,
                           mime: mime, encoding: encoding, headers: headers, isText: isText,
                           statusCode: parseStatusCode(meta?.statusLine))
    }

    private func emitThrottled(
        _ progress: inout IndexingProgress, start: Date, last: inout Date,
        onProgress: @escaping @Sendable @MainActor (IndexingProgress) -> Void
    ) async {
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.1 else { return }
        last = now
        let elapsed = now.timeIntervalSince(start)
        progress.itemsPerSecond = elapsed > 0 ? Double(progress.processed) / elapsed : 0
        if progress.itemsPerSecond > 0 {
            progress.etaSeconds = Double(progress.total - progress.processed) / progress.itemsPerSecond
        }
        let snapshot = progress
        await MainActor.run { onProgress(snapshot) }
    }

    private func flush(_ batch: inout [IndexedEntry]) async {
        guard !batch.isEmpty else { return }
        let records = batch
        batch.removeAll(keepingCapacity: true)
        try? await dbPool.write { db in
            for var record in records {
                if record.id == nil { try record.insert(db) } else { try record.update(db) }
            }
        }
    }

    private func deleteMissing(
        column: String, keep: Set<String>, from all: Dictionary<String, (Int64, String)>.Keys
    ) async -> Int {
        let toDelete = Array(Set(all).subtracting(keep))
        guard !toDelete.isEmpty else { return 0 }
        var removed = 0
        for start in stride(from: 0, to: toDelete.count, by: 500) {
            let chunk = Array(toDelete[start ..< min(start + 500, toDelete.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            try? await dbPool.write { db in
                try db.execute(sql: "DELETE FROM entry WHERE \(column) IN (\(placeholders))",
                               arguments: StatementArguments(chunk))
            }
            removed += chunk.count
        }
        return removed
    }
}

// MARK: - Free helpers

private func normaliseMime(_ raw: String) -> String {
    raw.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? raw.lowercased()
}

private func flattenHeaders(_ meta: CachedMetadata) -> String {
    var lines: [String] = []
    if let status = meta.statusLine { lines.append(status) }
    for (name, value) in meta.headerAttributes { lines.append("\(name): \(value)") }
    return lines.joined(separator: "\n")
}

private func fallbackDomain(_ url: String) -> String {
    if let r = url.range(of: "://") {
        let host = url[r.upperBound...].prefix { $0 != "/" }
        if !host.isEmpty { return String(host) }
    }
    return "(outros)"
}

/// Extracts the numeric HTTP status from a status line like "HTTP/1.1 200 OK".
private func parseStatusCode(_ statusLine: String?) -> Int? {
    guard let statusLine else { return nil }
    for token in statusLine.split(separator: " ") {
        if let n = Int(token), (100..<600).contains(n) { return n }
    }
    return nil
}
