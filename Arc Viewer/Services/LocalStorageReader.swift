//
//  LocalStorageReader.swift
//  Arc Viewer
//
//  Port of ccl_chromium_localstorage: reads the Local Storage LevelDB
//  (<profile>/Local Storage/leveldb), reconstructing storage keys, records and
//  batches, and returning the live records with their batch timestamps.
//

import Foundation

nonisolated enum LocalStorageReader {
    private static let metaPrefix = Array("META:".utf8)
    private static let recordPrefix = Array("_".utf8)

    static func load(profileRoot: URL) throws -> [LocalStorageRow] {
        let leveldbDir = profileRoot
            .appendingPathComponent("Local Storage", isDirectory: true)
            .appendingPathComponent("leveldb", isDirectory: true)
        guard FileManager.default.fileExists(atPath: leveldbDir.path) else {
            throw HistoryReader.ReadError.notFound(leveldbDir.path)
        }

        // Copy to a temp dir so a running browser doesn't interfere.
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ArcViewerLS-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        for file in (try? fm.contentsOfDirectory(at: leveldbDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.copyItem(at: file, to: tempDir.appendingPathComponent(file.lastPathComponent))
        }

        let records = LevelDBReader.records(in: tempDir)

        enum Item { case meta(StorageMetadata); case record(Record) }
        struct StorageMetadata { let storageKey: String; let timestamp: Date; let seq: UInt64 }
        struct Record { let storageKey: String; let scriptKey: String; let value: String?; let seq: UInt64; let isLive: Bool }

        var flat: [(seq: UInt64, item: Item)] = []
        var liveRecords: [Record] = []

        for rec in records {
            if rec.isLive, startsWith(rec.key, metaPrefix) {
                let storageKey = latin1(Array(rec.key[metaPrefix.count...]))
                guard let value = rec.value, let meta = parseMetadata(value, storageKey: storageKey) else { continue }
                flat.append((rec.seq, .meta(StorageMetadata(storageKey: meta.storageKey, timestamp: meta.timestamp, seq: rec.seq))))
            } else if startsWith(rec.key, recordPrefix) {
                let body = Array(rec.key[recordPrefix.count...])
                guard let sep = body.firstIndex(of: 0x00) else { continue }
                let storageKey = latin1(Array(body[..<sep]))
                guard let scriptKey = decodeString(Array(body[(sep + 1)...])) else { continue }
                let value: String? = rec.isLive ? (rec.value.flatMap { decodeString($0) }) : nil
                let r = Record(storageKey: storageKey, scriptKey: scriptKey, value: value, seq: rec.seq, isLive: rec.isLive)
                flat.append((rec.seq, .record(r)))
                if rec.isLive, value != nil { liveRecords.append(r) }
            }
        }

        flat.sort { $0.seq < $1.seq }

        // Rebuild batches: a StorageMetadata followed by a contiguous (by seq)
        // run of records with the same storage key.
        struct Batch { let storageKey: String; let timestamp: Date; let start: UInt64; let end: UInt64 }
        var batches: [Batch] = []
        var currentMeta: StorageMetadata?
        var currentEnd: UInt64 = 0
        for entry in flat {
            switch entry.item {
            case let .record(r):
                if let meta = currentMeta {
                    if r.seq - currentEnd != 1 || r.storageKey != meta.storageKey {
                        batches.append(Batch(storageKey: meta.storageKey, timestamp: meta.timestamp, start: meta.seq, end: currentEnd))
                        currentMeta = nil; currentEnd = 0
                    } else {
                        currentEnd = r.seq
                    }
                }
            case let .meta(m):
                if let meta = currentMeta {
                    batches.append(Batch(storageKey: meta.storageKey, timestamp: meta.timestamp, start: meta.seq, end: currentEnd))
                }
                currentMeta = m; currentEnd = m.seq
            }
        }
        if let meta = currentMeta {
            batches.append(Batch(storageKey: meta.storageKey, timestamp: meta.timestamp, start: meta.seq, end: currentEnd))
        }
        batches.sort { $0.start < $1.start }
        let batchStarts = batches.map(\.start)

        func findBatch(_ seq: UInt64) -> Batch? {
            var lo = 0, hi = batchStarts.count
            while lo < hi { let mid = (lo + hi) / 2; if batchStarts[mid] < seq { lo = mid + 1 } else { hi = mid } }
            let i = lo - 1
            guard i >= 0 else { return nil }
            let b = batches[i]
            return (b.start <= seq && seq <= b.end) ? b : nil
        }

        return liveRecords.map {
            LocalStorageRow(storageKey: $0.storageKey, scriptKey: $0.scriptKey,
                            value: $0.value ?? "", timestamp: findBatch($0.seq)?.timestamp)
        }
    }

    private static func startsWith(_ a: [UInt8], _ prefix: [UInt8]) -> Bool {
        a.count >= prefix.count && Array(a[..<prefix.count]) == prefix
    }

    private static func latin1(_ b: [UInt8]) -> String { String(bytes: b, encoding: .isoLatin1) ?? "" }

    /// Type-prefixed string: 0 = utf-16-le, 1 = latin-1.
    private static func decodeString(_ raw: [UInt8]) -> String? {
        guard let prefix = raw.first else { return "" }
        let body = Array(raw.dropFirst())
        switch prefix {
        case 0: return String(bytes: body, encoding: .utf16LittleEndian)
        case 1: return String(bytes: body, encoding: .isoLatin1)
        default: return nil
        }
    }

    private static func parseMetadata(_ data: [UInt8], storageKey: String) -> (storageKey: String, timestamp: Date)? {
        var i = 0
        let tsTag = readVarint(data, &i)
        guard (tsTag & 0x07) == 0, (tsTag >> 3) == 1 else { return nil }
        let micros = readVarint(data, &i)
        return (storageKey, decodeChromeTime(micros))
    }

    private static func readVarint(_ b: [UInt8], _ i: inout Int) -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while i < b.count {
            let c = b[i]; i += 1
            result |= UInt64(c & 0x7f) << shift
            if c & 0x80 == 0 { break }
            shift += 7; if shift >= 64 { break }
        }
        return result
    }
}
