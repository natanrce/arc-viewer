//
//  LevelDB.swift
//  Arc Viewer
//
//  A minimal, read-only LevelDB reader sufficient to dump every record (like
//  ccl_leveldb.RawLevelDb): it parses the write-ahead `.log` files and the
//  `.ldb`/`.sst` SSTables, decompressing data blocks (none / Snappy / zstd).
//  CRCs and the MANIFEST are ignored — we surface all records (including stale
//  ones), which is exactly what the local-storage layer needs to rebuild
//  batches.
//

import Foundation

nonisolated struct LDBRecord {
    let key: [UInt8]
    let value: [UInt8]?
    let seq: UInt64
    let isLive: Bool
}

nonisolated enum LevelDBReader {
    /// Reads every record from all `.log` and `.ldb`/`.sst` files in `dir`.
    static func records(in dir: URL) -> [LDBRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [LDBRecord] = []
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let bytes = [UInt8](data)
            switch file.pathExtension.lowercased() {
            case "ldb", "sst": out.append(contentsOf: parseTable(bytes))
            case "log": out.append(contentsOf: parseLog(bytes))
            default: break
            }
        }
        return out
    }

    // MARK: - Little-endian / varint helpers

    private static func readVarint(_ b: [UInt8], _ i: inout Int) -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while i < b.count {
            let c = b[i]; i += 1
            result |= UInt64(c & 0x7f) << shift
            if c & 0x80 == 0 { break }
            shift += 7
            if shift >= 64 { break }
        }
        return result
    }

    private static func le32(_ b: ArraySlice<UInt8>) -> UInt32 {
        let a = Array(b)
        guard a.count >= 4 else { return 0 }
        return UInt32(a[0]) | (UInt32(a[1]) << 8) | (UInt32(a[2]) << 16) | (UInt32(a[3]) << 24)
    }

    private static func le64(_ b: ArraySlice<UInt8>) -> UInt64 {
        let a = Array(b)
        guard a.count >= 8 else { return 0 }
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(a[k]) << (8 * k) }
        return v
    }

    // MARK: - SSTable

    private static func parseTable(_ data: [UInt8]) -> [LDBRecord] {
        guard data.count >= 48 else { return [] }
        let footer = Array(data[(data.count - 48)...])
        var fi = 0
        _ = readVarint(footer, &fi); _ = readVarint(footer, &fi)   // metaindex handle (skip)
        let indexOffset = Int(readVarint(footer, &fi))
        let indexSize = Int(readVarint(footer, &fi))
        guard let indexBlock = readBlock(data, offset: indexOffset, size: indexSize) else { return [] }

        var recs: [LDBRecord] = []
        for (_, handleBytes) in blockEntries(indexBlock) {
            var hi = 0
            let off = Int(readVarint(handleBytes, &hi))
            let sz = Int(readVarint(handleBytes, &hi))
            guard let dataBlock = readBlock(data, offset: off, size: sz) else { continue }
            for (internalKey, value) in blockEntries(dataBlock) {
                guard internalKey.count >= 8 else { continue }
                let userKey = Array(internalKey[..<(internalKey.count - 8)])
                let trailer = le64(internalKey[(internalKey.count - 8)...])
                let type = trailer & 0xff          // 1 = value, 0 = deletion
                let seq = trailer >> 8
                recs.append(LDBRecord(key: userKey, value: type == 1 ? value : nil, seq: seq, isLive: type == 1))
            }
        }
        return recs
    }

    /// Reads and decompresses a block at (offset, size) + 1 compression-type byte.
    private static func readBlock(_ data: [UInt8], offset: Int, size: Int) -> [UInt8]? {
        guard offset >= 0, size >= 0, offset + size + 1 <= data.count else { return nil }
        let raw = Array(data[offset ..< offset + size])
        let compression = data[offset + size]
        switch compression {
        case 0: return raw
        case 1: return snappyDecompress(raw)
        case 4: return ZstdDecoder.shared.decompress(Data(raw)).map { [UInt8]($0) }
        default: return raw   // unknown: best-effort as-is
        }
    }

    /// Parses a LevelDB block's key/value entries (prefix-compressed, restarts ignored).
    private static func blockEntries(_ block: [UInt8]) -> [([UInt8], [UInt8])] {
        guard block.count >= 4 else { return [] }
        let numRestarts = Int(le32(block[(block.count - 4)...]))
        let entriesEnd = block.count - 4 - numRestarts * 4
        guard entriesEnd >= 0, entriesEnd <= block.count else { return [] }

        var entries: [([UInt8], [UInt8])] = []
        var i = 0
        var prevKey: [UInt8] = []
        while i < entriesEnd {
            let shared = Int(readVarint(block, &i))
            let nonShared = Int(readVarint(block, &i))
            let valueLen = Int(readVarint(block, &i))
            guard shared <= prevKey.count, i + nonShared <= block.count else { break }
            let delta = Array(block[i ..< i + nonShared]); i += nonShared
            guard i + valueLen <= block.count else { break }
            let value = Array(block[i ..< i + valueLen]); i += valueLen
            let key = Array(prevKey[0 ..< shared]) + delta
            entries.append((key, value))
            prevKey = key
        }
        return entries
    }

    // MARK: - Write-ahead log

    private static func parseLog(_ data: [UInt8]) -> [LDBRecord] {
        let blockSize = 32768
        var recs: [LDBRecord] = []
        var pos = 0
        var pending: [UInt8] = []
        while pos + 7 <= data.count {
            let inBlock = pos % blockSize
            if blockSize - inBlock < 7 { pos += (blockSize - inBlock); continue }   // block trailer padding
            let length = Int(data[pos + 4]) | (Int(data[pos + 5]) << 8)
            let type = data[pos + 6]
            let start = pos + 7
            guard start + length <= data.count else { break }
            let frag = Array(data[start ..< start + length])
            pos = start + length
            switch type {
            case 1: recs.append(contentsOf: parseWriteBatch(frag))            // FULL
            case 2: pending = frag                                            // FIRST
            case 3: pending.append(contentsOf: frag)                          // MIDDLE
            case 4: pending.append(contentsOf: frag)                          // LAST
                    recs.append(contentsOf: parseWriteBatch(pending)); pending = []
            default: break
            }
        }
        return recs
    }

    private static func parseWriteBatch(_ b: [UInt8]) -> [LDBRecord] {
        guard b.count >= 12 else { return [] }
        let baseSeq = le64(b[0..<8])
        let count = Int(le32(b[8..<12]))
        var i = 12
        var recs: [LDBRecord] = []
        var k = 0
        while k < count, i < b.count {
            let tag = b[i]; i += 1
            if tag == 1 {   // put
                let kl = Int(readVarint(b, &i)); guard i + kl <= b.count else { break }
                let key = Array(b[i ..< i + kl]); i += kl
                let vl = Int(readVarint(b, &i)); guard i + vl <= b.count else { break }
                let value = Array(b[i ..< i + vl]); i += vl
                recs.append(LDBRecord(key: key, value: value, seq: baseSeq + UInt64(k), isLive: true))
            } else if tag == 0 {   // delete
                let kl = Int(readVarint(b, &i)); guard i + kl <= b.count else { break }
                let key = Array(b[i ..< i + kl]); i += kl
                recs.append(LDBRecord(key: key, value: nil, seq: baseSeq + UInt64(k), isLive: false))
            } else {
                break
            }
            k += 1
        }
        return recs
    }

    // MARK: - Snappy

    static func snappyDecompress(_ input: [UInt8]) -> [UInt8]? {
        var i = 0
        _ = readVarint(input, &i)   // uncompressed length (unused; we grow dynamically)
        var out: [UInt8] = []
        while i < input.count {
            let tag = input[i]; i += 1
            switch tag & 0x03 {
            case 0:   // literal
                var litLen = Int(tag >> 2)
                if litLen >= 60 {
                    let extra = litLen - 59
                    guard i + extra <= input.count else { return nil }
                    var l = 0
                    for b in 0..<extra { l |= Int(input[i + b]) << (8 * b) }
                    i += extra
                    litLen = l
                }
                litLen += 1
                guard i + litLen <= input.count else { return nil }
                out.append(contentsOf: input[i ..< i + litLen]); i += litLen
            case 1:   // copy, 1-byte offset
                guard i < input.count else { return nil }
                let length = Int((tag >> 2) & 0x07) + 4
                let offset = (Int(tag >> 5) << 8) | Int(input[i]); i += 1
                if !copy(&out, offset: offset, length: length) { return nil }
            case 2:   // copy, 2-byte offset
                guard i + 2 <= input.count else { return nil }
                let length = Int(tag >> 2) + 1
                let offset = Int(input[i]) | (Int(input[i + 1]) << 8); i += 2
                if !copy(&out, offset: offset, length: length) { return nil }
            default:  // 3: copy, 4-byte offset
                guard i + 4 <= input.count else { return nil }
                let length = Int(tag >> 2) + 1
                let offset = Int(input[i]) | (Int(input[i + 1]) << 8) | (Int(input[i + 2]) << 16) | (Int(input[i + 3]) << 24)
                i += 4
                if !copy(&out, offset: offset, length: length) { return nil }
            }
        }
        return out
    }

    private static func copy(_ out: inout [UInt8], offset: Int, length: Int) -> Bool {
        let start = out.count - offset
        guard start >= 0, offset > 0 else { return false }
        for k in 0..<length { out.append(out[start + k]) }   // overlapping copies are intentional
        return true
    }
}
