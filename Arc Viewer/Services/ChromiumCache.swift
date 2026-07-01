//
//  ChromiumCache.swift
//  Arc Cache Viewer
//
//  Faithful Swift port of ccl_chromium_reader.ccl_chromium_cache
//  (Copyright 2022-2025, CCL Forensics — MIT licensed).
//
//  Reads both Chromium cache flavours:
//    * Blockfile cache  (index + data_0..data_3 + f_* external files)
//    * Simple cache     (index-dir/ + <16-hex>_0 / _1 / _s files)
//
//  This mirrors the structures, bit-layouts and pickle parsing of the
//  reference Python implementation as closely as Swift allows.
//

import Foundation

// MARK: - Errors

nonisolated enum CacheReadError: LocalizedError {
    case shortRead(expected: Int, got: Int, at: Int)
    case invalidMagic(String)
    case invalidValue(String)
    case fileNotFound(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .shortRead(expected, got, at):
            return "Could not read all of the data starting at \(at). Expected: \(expected); got \(got)"
        case let .invalidMagic(msg): return "Invalid magic: \(msg)"
        case let .invalidValue(msg): return msg
        case let .fileNotFound(msg): return "File not found: \(msg)"
        case let .decodingFailed(msg): return "Decoding failed: \(msg)"
        }
    }
}

// MARK: - Chrome time

nonisolated let chromeEpochToUnixSeconds: Double = 11_644_473_600  // seconds between 1601-01-01 and 1970-01-01

nonisolated func decodeChromeTime(_ microseconds: UInt64) -> Date {
    Date(timeIntervalSince1970: Double(microseconds) / 1_000_000.0 - chromeEpochToUnixSeconds)
}

// MARK: - BinaryReader

/// Little-endian reader over an in-memory byte buffer, mirroring the Python
/// `BinaryReader` (seek/tell semantics included so we can read Simple Cache
/// EOF records relative to the end of the file).
nonisolated final class BinaryReader {
    enum Whence { case set, current, end }

    private let bytes: [UInt8]
    private(set) var offset: Int = 0

    init(_ data: Data) { self.bytes = [UInt8](data) }
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var count: Int { bytes.count }

    func tell() -> Int { offset }

    @discardableResult
    func seek(_ off: Int, _ whence: Whence) -> Int {
        switch whence {
        case .set: offset = off
        case .current: offset += off
        case .end: offset = bytes.count + off
        }
        return offset
    }

    var isEOF: Bool { offset >= bytes.count }

    func readRaw(_ n: Int) throws -> [UInt8] {
        let start = offset
        guard n >= 0, start + n <= bytes.count, start >= 0 else {
            let got = max(0, min(bytes.count - start, n < 0 ? 0 : n))
            throw CacheReadError.shortRead(expected: n, got: got, at: start)
        }
        let slice = bytes[start ..< start + n]
        offset += n
        return Array(slice)
    }

    func readData(_ n: Int) throws -> Data { Data(try readRaw(n)) }

    func readUTF8(_ n: Int) throws -> String {
        let raw = try readRaw(n)
        guard let s = String(bytes: raw, encoding: .utf8) else {
            throw CacheReadError.decodingFailed("utf-8 string of length \(n)")
        }
        return s
    }

    func readLatin1(_ n: Int) throws -> String {
        let raw = try readRaw(n)
        // latin-1 (ISO-8859-1) maps each byte 1:1, so this never fails.
        return String(bytes: raw, encoding: .isoLatin1) ?? ""
    }

    func readInt16() throws -> Int16 { Int16(bitPattern: try readUInt16()) }
    func readInt32() throws -> Int32 { Int32(bitPattern: try readUInt32()) }
    func readInt64() throws -> Int64 { Int64(bitPattern: try readUInt64()) }

    func readUInt16() throws -> UInt16 {
        let b = try readRaw(2)
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    func readUInt32() throws -> UInt32 {
        let b = try readRaw(4)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    func readUInt64() throws -> UInt64 {
        let b = try readRaw(8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[i]) << (8 * i) }
        return v
    }

    func readAddr() throws -> Addr { Addr.from(int: try readUInt32()) }

    func readDatetime() throws -> Date { decodeChromeTime(try readUInt64()) }
}

// MARK: - FileType

nonisolated enum FileType: Int {
    // net/disk_cache/blockfile/disk_format.h
    case external = 0
    case rankings = 1
    case block256 = 2
    case block1K = 3
    case block4K = 4
    case blockFiles = 5
    case blockEntries = 6
    case blockEvicted = 7

    var name: String {
        switch self {
        case .external: return "EXTERNAL"
        case .rankings: return "RANKINGS"
        case .block256: return "BLOCK_256"
        case .block1K: return "BLOCK_1K"
        case .block4K: return "BLOCK_4K"
        case .blockFiles: return "BLOCK_FILES"
        case .blockEntries: return "BLOCK_ENTRIES"
        case .blockEvicted: return "BLOCK_EVICTED"
        }
    }
}

nonisolated let blockSizeForFileType: [FileType: Int] = [
    .rankings: 36, .block256: 256, .block1K: 1024, .block4K: 4096,
    .blockFiles: 8, .blockEntries: 104, .blockEvicted: 48, .external: 0,
]

nonisolated let blockFileFileTypes: Set<FileType> = [.block256, .block1K, .block4K]

// MARK: - Addr

/// A blockfile cache address (net/disk_cache/blockfile/addr.h).
nonisolated struct Addr {
    let isInitialized: Bool
    let fileType: FileType
    let externalFileNumber: Int?
    let contiguousBlocks: Int?
    let fileSelector: Int?
    let blockNumber: Int?
    let reservedBits: Int?

    static func from(int i: UInt32) -> Addr {
        let isInitialized = (i & 0x8000_0000) > 0
        let fileType = FileType(rawValue: Int((i & 0x7000_0000) >> 28)) ?? .external

        if fileType == .external {
            return Addr(
                isInitialized: isInitialized, fileType: fileType,
                externalFileNumber: Int(i & 0x0fff_ffff),
                contiguousBlocks: nil, fileSelector: nil, blockNumber: nil, reservedBits: nil)
        } else {
            return Addr(
                isInitialized: isInitialized, fileType: fileType,
                externalFileNumber: nil,
                contiguousBlocks: 1 + Int((i & 0x0300_0000) >> 24),
                fileSelector: Int((i & 0x00ff_0000) >> 16),
                blockNumber: Int(i & 0x0000_ffff),
                reservedBits: Int(i & 0x0c00_0000))
        }
    }

    /// Identifies invalid data so we can skip it rather than throwing.
    func sanityCheck() -> Bool {
        if fileType.rawValue > FileType.block4K.rawValue { return false }
        if fileType != .external && (reservedBits ?? 0) != 0 { return false }
        return true
    }

    func sanityCheckForEntry() -> Bool {
        sanityCheck() && fileType == .block256
    }
}

// MARK: - Blockfile index

nonisolated struct LruData {
    // net/disk_cache/blockfile/disk_format.h
    let filled: Int32
    let sizes: [Int32]
    let heads: [Addr]
    let tails: [Addr]
    let transaction: Addr
    let operation: Int32
    let operationList: Int32

    static func from(reader: BinaryReader) throws -> LruData {
        _ = try (0..<2).map { _ in try reader.readInt32() }
        let filled = try reader.readInt32()
        let sizes = try (0..<5).map { _ in try reader.readInt32() }
        let heads = try (0..<5).map { _ in try reader.readAddr() }
        let tails = try (0..<5).map { _ in try reader.readAddr() }
        let transaction = try reader.readAddr()
        let operation = try reader.readInt32()
        let operationList = try reader.readInt32()
        _ = try (0..<7).map { _ in try reader.readInt32() }
        return LruData(filled: filled, sizes: sizes, heads: heads, tails: tails,
                       transaction: transaction, operation: operation, operationList: operationList)
    }
}

nonisolated struct BlockFileIndexHeader {
    static let magic: UInt32 = 0xC103CAC3

    let version: UInt32
    let numEntries: Int32
    let numBytesV2: UInt32
    let lastFile: Int32
    let thisId: Int32
    let statsAddr: Addr
    let tableLength: Int32
    let crash: Int32
    let experiment: Int32
    let createTime: Date
    let numBytesV3: Int64
    let lru: LruData

    static func from(reader: BinaryReader) throws -> BlockFileIndexHeader {
        let magic = try reader.readUInt32()
        guard magic == BlockFileIndexHeader.magic else {
            throw CacheReadError.invalidMagic(String(format: "index magic 0x%08X", magic))
        }
        let version = try reader.readUInt32()
        let numEntries = try reader.readInt32()
        let oldV2NumBytes = try reader.readUInt32()
        let lastFile = try reader.readInt32()
        let thisId = try reader.readInt32()
        let statsAddr = try reader.readAddr()
        let tableLengthRaw = try reader.readInt32()
        let tableLength = tableLengthRaw == 0 ? 0x10000 : tableLengthRaw
        let crash = try reader.readInt32()
        let experiment = try reader.readInt32()
        let createTime = try reader.readDatetime()
        let numBytes = try reader.readInt64()
        _ = try (0..<50).map { _ in try reader.readInt32() }
        let lru = try LruData.from(reader: reader)

        return BlockFileIndexHeader(
            version: version, numEntries: numEntries, numBytesV2: oldV2NumBytes,
            lastFile: lastFile, thisId: thisId, statsAddr: statsAddr, tableLength: tableLength,
            crash: crash, experiment: experiment, createTime: createTime, numBytesV3: numBytes, lru: lru)
    }
}

nonisolated struct BlockFileIndexFile {
    let header: BlockFileIndexHeader
    let index: [Addr]

    init(path: URL) throws {
        guard let data = try? Data(contentsOf: path) else {
            throw CacheReadError.fileNotFound(path.path)
        }
        let reader = BinaryReader(data)
        self.header = try BlockFileIndexHeader.from(reader: reader)
        self.index = try (0..<Int(header.tableLength)).map { _ in try reader.readAddr() }
    }

    var indexInitializedOnly: [Addr] { index.filter { $0.isInitialized } }
}

// MARK: - Entry store

nonisolated enum EntryState: Int {
    case normal = 0
    case evicted = 1
    case doomed = 2

    var name: String {
        switch self {
        case .normal: return "Normal"
        case .evicted: return "Evicted"
        case .doomed: return "Doomed"
        }
    }
}

nonisolated struct EntryFlags: OptionSet {
    let rawValue: UInt32
    static let parentEntry = EntryFlags(rawValue: 1 << 0)
    static let childEntry = EntryFlags(rawValue: 1 << 1)
}

nonisolated struct EntryStore {
    // net/disk_cache/blockfile/disk_format.h
    let entryHash: UInt32
    let nextEntry: Addr
    let rankingsNode: Addr
    let reuseCount: Int32
    let refetchCount: Int32
    let state: EntryState
    let creationTime: Date
    let keyLength: Int32
    let longKeyAddr: Addr
    let dataSizes: [Int32]   // 4 streams
    let dataAddrs: [Addr]    // 4 streams
    let flags: EntryFlags
    let selfHash: UInt32
    let key: String?

    var keyIsExternal: Bool { longKeyAddr.isInitialized }

    static func from(data: Data) throws -> EntryStore { try from(reader: BinaryReader(data)) }

    static func from(reader: BinaryReader) throws -> EntryStore {
        let entryHash = try reader.readUInt32()
        let nextEntry = try reader.readAddr()
        let rankingsNode = try reader.readAddr()
        let reuseCount = try reader.readInt32()
        let refetchCount = try reader.readInt32()
        let stateRaw = try reader.readInt32()
        guard let state = EntryState(rawValue: Int(stateRaw)) else {
            throw CacheReadError.invalidValue("invalid entry state \(stateRaw)")
        }
        let creationTime = try reader.readDatetime()
        let keyLength = try reader.readInt32()
        let longKeyAddr = try reader.readAddr()
        let dataSizes = try (0..<4).map { _ in try reader.readInt32() }
        let dataAddrs = try (0..<4).map { _ in try reader.readAddr() }
        let flags = EntryFlags(rawValue: try reader.readUInt32())
        _ = try (0..<4).map { _ in try reader.readInt32() }
        let selfHash = try reader.readUInt32()

        var key: String? = nil
        if !longKeyAddr.isInitialized {
            key = try reader.readUTF8(Int(keyLength))
        }

        return EntryStore(
            entryHash: entryHash, nextEntry: nextEntry, rankingsNode: rankingsNode,
            reuseCount: reuseCount, refetchCount: refetchCount, state: state,
            creationTime: creationTime, keyLength: keyLength, longKeyAddr: longKeyAddr,
            dataSizes: dataSizes, dataAddrs: dataAddrs, flags: flags, selfHash: selfHash, key: key)
    }
}

nonisolated struct BlockFileHeader {
    static let magic: UInt32 = 0xC104CAC3
    static let blockHeaderSize = 8192
    static let maxBlocks = (blockHeaderSize - 80) * 8

    let version: UInt32
    let thisFile: Int16
    let nextFile: Int16
    let entrySize: Int32
    let numEntries: Int32
    let maxEntries: Int32

    static func from(data: Data) throws -> BlockFileHeader { try from(reader: BinaryReader(data)) }

    static func from(reader: BinaryReader) throws -> BlockFileHeader {
        let magic = try reader.readUInt32()
        guard magic == BlockFileHeader.magic else {
            throw CacheReadError.invalidMagic(String(format: "block file magic 0x%08X", magic))
        }
        let version = try reader.readUInt32()
        let thisFile = try reader.readInt16()
        let nextFile = try reader.readInt16()
        let entrySize = try reader.readInt32()
        let numEntries = try reader.readInt32()
        let maxEntries = try reader.readInt32()
        _ = try (0..<4).map { _ in try reader.readInt32() }   // empty type counts
        _ = try (0..<4).map { _ in try reader.readInt32() }   // hints
        _ = try reader.readInt32()                            // updating
        _ = try (0..<5).map { _ in try reader.readInt32() }   // user
        _ = try reader.readRaw(maxBlocks / 8)                 // allocation map
        return BlockFileHeader(version: version, thisFile: thisFile, nextFile: nextFile,
                               entrySize: entrySize, numEntries: numEntries, maxEntries: maxEntries)
    }
}

// MARK: - Cached metadata (HTTP response info pickle)

nonisolated struct CachedMetadataFlags {
    // net/http/http_response_info.cc
    static let versionMask: UInt32 = 0xFF
    static let hasCert: UInt32 = 1 << 8
    static let hasSecurityBits: UInt32 = 1 << 9
    static let hasCertStatus: UInt32 = 1 << 10
    static let hasVaryData: UInt32 = 1 << 11
    static let truncated: UInt32 = 1 << 12
    static let hasSSLConnectionStatus: UInt32 = 1 << 16
    static let hasSignedCertificateTimestamps: UInt32 = 1 << 20
    static let hasExtraFlags: UInt32 = 1 << 31
}

nonisolated struct CachedMetadataExtraFlags {
    static let didUseSharedDictionary: UInt32 = 1
    static let hasProxyChain: UInt32 = 1 << 1
    static let hasOriginalResponseTime: UInt32 = 1 << 2
}

/// Parsed HTTP response metadata (net/http/http_response_info.cc) or Code Cache metadata.
nonisolated struct CachedMetadata {
    /// HTTP header lines without a colon (e.g. the status line "HTTP/1.1 200 OK").
    let headerDeclarations: [String]
    /// Ordered (lowercased-name, value) HTTP header attribute pairs.
    let headerAttributes: [(name: String, value: String)]
    let requestTime: Date?
    let responseTime: Date
    let certs: [Data]
    let host: String?
    let port: Int?
    /// Misc decoded attributes (cert_status, vary_data, code cache tag, …) as display strings.
    let otherAttributes: [(name: String, value: String)]

    func attribute(_ name: String) -> [String] {
        let lower = name.lowercased()
        return headerAttributes.filter { $0.name == lower }.map { $0.value }
    }

    var statusLine: String? { headerDeclarations.first }

    // MARK: HTTP response info pickle

    static func from(buffer: Data) throws -> CachedMetadata {
        let reader = BinaryReader(buffer)
        let totalLength = try reader.readUInt32()
        guard Int(totalLength) == buffer.count - 4 else {
            throw CacheReadError.invalidValue("Metadata buffer is not the declared size")
        }

        func align() throws {
            let alignment = reader.tell() % 4
            if alignment != 0 { _ = try reader.readRaw(4 - alignment) }
        }

        let flags = try reader.readUInt32()
        var extraFlags: UInt32 = 0
        if flags & CachedMetadataFlags.hasExtraFlags != 0 {
            extraFlags = try reader.readUInt32()
        }

        let requestTime = try reader.readDatetime()
        let responseTime = try reader.readDatetime()

        if extraFlags & CachedMetadataExtraFlags.hasOriginalResponseTime != 0 {
            _ = try reader.readDatetime()  // original response time (read, not reported)
        }

        let httpHeaderLength = try reader.readUInt32()
        let httpHeaderRaw = try reader.readRaw(Int(httpHeaderLength))

        var headerAttributes: [(name: String, value: String)] = []
        var headerDeclarations: [String] = []

        for entry in splitBytes(httpHeaderRaw, separator: 0) {
            if entry.isEmpty { continue }
            let line = String(bytes: entry, encoding: .isoLatin1) ?? ""
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headerAttributes.append((name, value))
            } else {
                headerDeclarations.append(line)
            }
        }

        var otherAttributes: [(name: String, value: String)] = []
        var certs: [Data] = []

        if flags & CachedMetadataFlags.hasCert != 0 {
            try align()
            let certCount = try reader.readUInt32()
            for _ in 0..<certCount {
                try align()
                let certLength = try reader.readUInt32()
                certs.append(try reader.readData(Int(certLength)))
            }
        }

        if flags & CachedMetadataFlags.hasCertStatus != 0 {
            try align()
            otherAttributes.append(("cert_status", String(try reader.readUInt32())))
        }

        if flags & CachedMetadataFlags.hasSecurityBits != 0 {
            try align()
            otherAttributes.append(("security_bits", String(try reader.readInt32())))
        }

        if flags & CachedMetadataFlags.hasSSLConnectionStatus != 0 {
            try align()
            otherAttributes.append(("ssl_connection_status", String(try reader.readInt32())))
        }

        if flags & CachedMetadataFlags.hasSignedCertificateTimestamps != 0 {
            try align()
            let tsCount = try reader.readInt32()
            for _ in 0..<max(0, tsCount) {
                // net/cert/signed_certificate_timestamp.cc — read & discard
                _ = try reader.readInt32()                       // version
                var strLen = try reader.readInt32()
                _ = try reader.readRaw(Int(strLen))              // log id
                try align()
                _ = try reader.readDatetime()                    // timestamp
                strLen = try reader.readInt32()
                _ = try reader.readRaw(Int(strLen))              // extensions
                try align()
                _ = try reader.readInt32()                       // hash algo
                _ = try reader.readInt32()                       // sig algo
                strLen = try reader.readInt32()
                _ = try reader.readRaw(Int(strLen))              // sig data
                try align()
                _ = try reader.readInt32()                       // origin
                strLen = try reader.readInt32()
                _ = try reader.readRaw(Int(strLen))              // log desc
                try align()
                _ = try reader.readUInt16()                      // status
                try align()
            }
        }

        if flags & CachedMetadataFlags.hasVaryData != 0 {
            try align()
            let varyData = try reader.readRaw(16)
            otherAttributes.append(("vary_data", varyData.map { String(format: "%02x", $0) }.joined()))
        }

        var host: String? = nil
        var port: Int? = nil
        do {
            try align()
            let hostLength = try reader.readUInt32()
            host = try reader.readLatin1(Int(hostLength))
            try align()
            port = Int(try reader.readUInt16())
        } catch {
            // Hit EOF — return what we have, matching the Python behaviour.
        }

        return CachedMetadata(
            headerDeclarations: headerDeclarations, headerAttributes: headerAttributes,
            requestTime: requestTime, responseTime: responseTime, certs: certs,
            host: host, port: port, otherAttributes: otherAttributes)
    }

    // MARK: Code Cache metadata

    static func fromCodeCache(buffer: Data) throws -> CachedMetadata {
        // content/browser/code_cache/generated_code_cache.cc
        guard buffer.count >= 8 else {
            throw CacheReadError.invalidValue("Code cache metadata buffer too short (\(buffer.count) bytes, need 8)")
        }
        let reader = BinaryReader(buffer)
        let responseTime = try reader.readDatetime()
        let tag = buffer.subdata(in: 8 ..< buffer.count)

        var otherAttributes: [(name: String, value: String)] = []
        if !tag.isEmpty {
            otherAttributes.append(("code_cache_tag_size", String(tag.count)))
            if tag.count >= 68 {
                let refBytes = tag.subdata(in: 4 ..< 68)
                if let ref = String(bytes: refBytes, encoding: .ascii),
                   ref.range(of: "^[0-9A-F]{64}$", options: .regularExpression) != nil {
                    otherAttributes.append(("code_cache_data_ref", ref))
                    let size = tag.prefix(4).enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
                    otherAttributes.append(("code_cache_data_size", String(size)))
                }
            }
        }

        return CachedMetadata(
            headerDeclarations: [], headerAttributes: [], requestTime: nil,
            responseTime: responseTime, certs: [], host: nil, port: nil,
            otherAttributes: otherAttributes)
    }
}

nonisolated private func splitBytes(_ bytes: [UInt8], separator: UInt8) -> [[UInt8]] {
    var result: [[UInt8]] = []
    var current: [UInt8] = []
    for b in bytes {
        if b == separator {
            result.append(current)
            current = []
        } else {
            current.append(b)
        }
    }
    result.append(current)
    return result
}

// MARK: - Cache key

/// A parsed Chromium cache key (net/http/http_cache.cc GenerateCacheKey).
nonisolated struct CacheKey {
    let rawKey: String
    let url: String
    let isCodeCacheKey: Bool
    let codeCacheOrigin: String?
    let credentialKey: String?
    let uploadDataIdentifier: Int?
    let isolationKeyTopFrameSite: String?
    let isolationKeyVariablePart: String?

    private static let codeCacheKeyPrefix = "_key"

    init(_ rawKey: String) {
        self.rawKey = rawKey

        var url = rawKey
        var isCodeCache = false
        var codeCacheOrigin: String? = nil
        var credentialKey: String? = nil
        var uploadDataIdentifier: Int? = nil
        var isolationTopFrame: String? = nil
        var isolationVariable: String? = nil

        let uploadOnly = rawKey.range(of: "^\\d+/", options: .regularExpression) != nil
        let credUpload = rawKey.range(of: "^\\d+/\\d+/", options: .regularExpression) != nil
        let codeCacheHash = rawKey.range(of: "^[0-9A-F]{64}$", options: .regularExpression) != nil

        if uploadOnly {
            let splitKey: [String]
            if credUpload {
                splitKey = CacheKey.split(rawKey, separator: "/", maxSplits: 2)
                credentialKey = splitKey.count > 0 ? splitKey[0] : ""
                uploadDataIdentifier = splitKey.count > 1 ? Int(splitKey[1]) : nil
            } else {
                splitKey = CacheKey.split(rawKey, separator: "/", maxSplits: 1)
                credentialKey = ""
                uploadDataIdentifier = splitKey.count > 0 ? Int(splitKey[0]) : nil
            }

            let last = splitKey.last ?? ""
            if last.hasPrefix("_dk_") {
                let body = String(last.dropFirst(4))
                let parts = CacheKey.split(body, separator: " ", maxSplits: 2)
                if parts.count == 3 {
                    isolationTopFrame = parts[0]
                    isolationVariable = parts[1]
                    url = parts[2]
                    if isolationTopFrame?.hasPrefix("s_") == true {
                        isolationTopFrame = String(isolationTopFrame!.dropFirst(2))
                    }
                } else {
                    url = body
                }
            } else {
                url = last
            }
        } else if rawKey.hasPrefix(CacheKey.codeCacheKeyPrefix) {
            isCodeCache = true
            let body = String(rawKey.dropFirst(CacheKey.codeCacheKeyPrefix.count))
            if let nl = body.firstIndex(of: "\n") {
                url = String(body[..<nl])
                codeCacheOrigin = String(body[body.index(after: nl)...])
            } else {
                url = body
            }
        } else if codeCacheHash {
            isCodeCache = true
            url = rawKey
        } else {
            url = rawKey
        }

        self.url = url
        self.isCodeCacheKey = isCodeCache
        self.codeCacheOrigin = codeCacheOrigin
        self.credentialKey = credentialKey
        self.uploadDataIdentifier = uploadDataIdentifier
        self.isolationKeyTopFrameSite = isolationTopFrame
        self.isolationKeyVariablePart = isolationVariable
    }

    /// Python-style str.split(sep, maxsplit): the final element keeps any
    /// remaining separators.
    private static func split(_ s: String, separator: Character, maxSplits: Int) -> [String] {
        var parts: [String] = []
        var remainder = Substring(s)
        while parts.count < maxSplits, let idx = remainder.firstIndex(of: separator) {
            parts.append(String(remainder[..<idx]))
            remainder = remainder[remainder.index(after: idx)...]
        }
        parts.append(String(remainder))
        return parts
    }
}

// MARK: - Cache file location

nonisolated struct CacheFileLocation {
    let fileName: String
    let offset: Int

    var description: String { "\(fileName) @ \(offset)" }
}

// MARK: - ChromiumCache protocol

nonisolated protocol ChromiumCache: AnyObject {
    var cacheTypeDescription: String { get }
    func keys() -> [String]
    func getMetadata(_ key: String) throws -> [CachedMetadata?]
    func getCachefile(_ key: String) throws -> [Data?]
    func getLocationForMetadata(_ key: String) -> [CacheFileLocation]
    func getLocationForCachefile(_ key: String) -> [CacheFileLocation]
    /// A cheap timestamp for the entry, used for sorting/grouping in the UI.
    /// Blockfile uses the entry creation time; Simple uses the file mtime.
    func entryDate(_ key: String) -> Date?
    /// A cheap fingerprint of the entry for incremental indexing — derived
    /// purely from sizes/dates/CRCs already in memory, *without* reading the
    /// (possibly large/compressed) body.
    func changeToken(_ key: String) -> String
    /// Where the response body lives on disk, so the body can be read later
    /// (detail view / export) without re-opening the whole cache.
    func cachefileLocator(_ key: String) -> BlobLocator?
    /// The stored (on-disk, still content-encoded) body size — cheap to read.
    func bodySize(_ key: String) -> Int
}

/// A pointer to a cached response body on disk.
nonisolated enum BlobLocator: Codable, Sendable {
    case simpleStream1(file: String)               // reopen the simple-cache file, read stream 1
    case range(file: String, offset: Int, length: Int)
    case wholeFile(file: String)

    /// Reads the raw (still content-encoded) body bytes.
    func readRaw() -> Data? {
        switch self {
        case let .simpleStream1(file):
            return try? SimpleCacheFile(path: URL(fileURLWithPath: file)).getStream1()
        case let .wholeFile(file):
            return try? Data(contentsOf: URL(fileURLWithPath: file))
        case let .range(file, offset, length):
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: file)) else { return nil }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(offset))
            return try? handle.read(upToCount: length)
        }
    }
}

// MARK: - Blockfile cache

nonisolated final class ChromiumBlockFileCache: ChromiumCache {
    let cacheTypeDescription = "Blockfile Cache"

    private let dir: URL
    private let indexFile: BlockFileIndexFile
    private var blockFiles: [Int: (header: BlockFileHeader, data: Data)] = [:]
    private(set) var entries: [String: EntryStore] = [:]
    private(set) var orderedKeys: [String] = []

    init(cacheDir: URL) throws {
        self.dir = cacheDir
        self.indexFile = try BlockFileIndexFile(path: cacheDir.appendingPathComponent("index"))
        try buildKeys()
    }

    private func getBlockFile(_ number: Int) throws -> (header: BlockFileHeader, data: Data) {
        if let cached = blockFiles[number] { return cached }
        let path = dir.appendingPathComponent("data_\(number)")
        guard let data = try? Data(contentsOf: path) else {
            throw CacheReadError.fileNotFound(path.lastPathComponent)
        }
        let header = try BlockFileHeader.from(data: data.prefix(BlockFileHeader.blockHeaderSize))
        let entry = (header, data)
        blockFiles[number] = entry
        return entry
    }

    private func buildKeys() throws {
        for start in indexFile.index {
            var addr = start
            while addr.isInitialized {
                if !addr.sanityCheckForEntry() {
                    FileHandle.standardError.write(Data("Warning: Addr skipped (not sane for an entry)\n".utf8))
                    break
                }
                guard let raw = try? getDataForAddr(addr) else { break }
                let es: EntryStore
                do {
                    es = try EntryStore.from(data: raw)
                } catch {
                    FileHandle.standardError.write(Data("Warning: EntryStore could not be read; skipping.\n".utf8))
                    break
                }
                let key: String
                if let k = es.key {
                    key = k
                } else if let keyData = try? getDataForAddr(es.longKeyAddr),
                          let decoded = String(bytes: keyData, encoding: .utf8) {
                    key = String(decoded.prefix(Int(es.keyLength)))
                } else {
                    break
                }
                if entries[key] == nil { orderedKeys.append(key) }
                entries[key] = es
                addr = es.nextEntry
            }
        }
    }

    func getDataForAddr(_ addr: Addr) throws -> Data? {
        guard addr.isInitialized else { throw CacheReadError.invalidValue("Addr is not initialized") }
        if blockFileFileTypes.contains(addr.fileType) {
            let (header, data) = try getBlockFile(addr.fileSelector ?? 0)
            let entrySize = Int(header.entrySize)
            let offset = BlockFileHeader.blockHeaderSize + entrySize * (addr.blockNumber ?? 0)
            let length = entrySize * (addr.contiguousBlocks ?? 1)
            guard offset >= 0, offset + length <= data.count else {
                throw CacheReadError.shortRead(expected: length, got: max(0, data.count - offset), at: offset)
            }
            return data.subdata(in: offset ..< offset + length)
        } else if addr.fileType == .external {
            let path = dir.appendingPathComponent(String(format: "f_%06x", addr.externalFileNumber ?? 0))
            guard FileManager.default.fileExists(atPath: path.path) else {
                FileHandle.standardError.write(Data("Warning: External cache file \(path.lastPathComponent) referenced but missing.\n".utf8))
                return nil
            }
            return try Data(contentsOf: path)
        }
        throw CacheReadError.invalidValue("unexpected file type")
    }

    func getDataBuffer(_ es: EntryStore, stream: Int) throws -> Data? {
        guard stream >= 0, stream <= 2 else { throw CacheReadError.invalidValue("invalid stream number") }
        let addr = es.dataAddrs[stream]
        guard addr.isInitialized else { return nil }
        guard let data = try getDataForAddr(addr) else { return nil }
        let streamLength = Int(es.dataSizes[stream])
        guard data.count >= streamLength else {
            throw CacheReadError.invalidValue("Could not get all of the data for stream \(stream)")
        }
        return data.prefix(streamLength)
    }

    private func location(_ key: String, stream: Int) -> CacheFileLocation? {
        guard let es = entries[key] else { return nil }
        let addr = es.dataAddrs[stream]
        if blockFileFileTypes.contains(addr.fileType) {
            guard let (header, _) = try? getBlockFile(addr.fileSelector ?? 0) else { return nil }
            let offset = BlockFileHeader.blockHeaderSize + Int(header.entrySize) * (addr.blockNumber ?? 0)
            return CacheFileLocation(fileName: "data_\(addr.fileSelector ?? 0)", offset: offset)
        } else if addr.fileType == .external {
            return CacheFileLocation(fileName: String(format: "f_%06x", addr.externalFileNumber ?? 0), offset: 0)
        }
        return nil
    }

    func keys() -> [String] { orderedKeys }

    func getMetadata(_ key: String) throws -> [CachedMetadata?] {
        guard let es = entries[key] else { return [nil] }
        guard let buffer = try getDataBuffer(es, stream: 0), !buffer.isEmpty else { return [nil] }
        return [try CachedMetadata.from(buffer: buffer)]
    }

    func getCachefile(_ key: String) throws -> [Data?] {
        guard let es = entries[key] else { return [nil] }
        return [try getDataBuffer(es, stream: 1)]
    }

    func getLocationForMetadata(_ key: String) -> [CacheFileLocation] {
        location(key, stream: 0).map { [$0] } ?? []
    }

    func getLocationForCachefile(_ key: String) -> [CacheFileLocation] {
        location(key, stream: 1).map { [$0] } ?? []
    }

    func entryDate(_ key: String) -> Date? { entries[key]?.creationTime }

    func changeToken(_ key: String) -> String {
        guard let es = entries[key] else { return "?" }
        // creation time + stream sizes + self hash are stable per stored entry
        // and cheap to read (already in the parsed EntryStore).
        return "\(Int(es.creationTime.timeIntervalSince1970))-\(es.dataSizes[0])-\(es.dataSizes[1])-\(es.selfHash)"
    }

    func cachefileLocator(_ key: String) -> BlobLocator? {
        guard let es = entries[key] else { return nil }
        let addr = es.dataAddrs[1]
        guard addr.isInitialized else { return nil }
        let length = Int(es.dataSizes[1])
        if blockFileFileTypes.contains(addr.fileType) {
            guard let (header, _) = try? getBlockFile(addr.fileSelector ?? 0) else { return nil }
            let offset = BlockFileHeader.blockHeaderSize + Int(header.entrySize) * (addr.blockNumber ?? 0)
            let file = dir.appendingPathComponent("data_\(addr.fileSelector ?? 0)").path
            return .range(file: file, offset: offset, length: length)
        } else if addr.fileType == .external {
            let file = dir.appendingPathComponent(String(format: "f_%06x", addr.externalFileNumber ?? 0)).path
            return .wholeFile(file: file)
        }
        return nil
    }

    func bodySize(_ key: String) -> Int { Int(entries[key]?.dataSizes[1] ?? 0) }
}

// MARK: - Simple cache

/// Switch off if you get errors about the EOF magic on a Simple Cache.
nonisolated let eightBytePickleAlignment = true
nonisolated var simpleEOFSize: Int { eightBytePickleAlignment ? 24 : 20 }

nonisolated struct SimpleCacheEOF {
    static let finalMagic: UInt64 = 0xf4fa6f45970d41d8

    let flags: UInt32
    let dataCRC: UInt32
    let streamSize: Int

    var hasCRC: Bool { flags & 1 > 0 }
    var hasKeySHA256: Bool { flags & 2 > 0 }

    static func from(reader: BinaryReader) throws -> SimpleCacheEOF {
        let magic = try reader.readUInt64()
        guard magic == SimpleCacheEOF.finalMagic else {
            throw CacheReadError.invalidMagic(String(format: "simple EOF magic 0x%016llX", magic))
        }
        let flags = try reader.readUInt32()
        let dataCRC = try reader.readUInt32()
        let streamSize = try reader.readUInt32()
        return SimpleCacheEOF(flags: flags, dataCRC: dataCRC, streamSize: Int(streamSize))
    }
}

nonisolated struct SimpleCacheHeader {
    static let initialMagic: UInt64 = 0xfcfb6d1ba7725c30

    let version: UInt32
    let keyLength: Int
    let keyHash: UInt32

    static func from(reader: BinaryReader) throws -> SimpleCacheHeader {
        let magic = try reader.readUInt64()
        guard magic == SimpleCacheHeader.initialMagic else {
            throw CacheReadError.invalidMagic(String(format: "simple header magic 0x%016llX", magic))
        }
        let version = try reader.readUInt32()
        let keyLength = try reader.readUInt32()
        let keyHash = try reader.readUInt32()
        if eightBytePickleAlignment { _ = try reader.readUInt32() }  // align to 8 bytes before the key
        return SimpleCacheHeader(version: version, keyLength: Int(keyLength), keyHash: keyHash)
    }
}

/// A single Simple Cache file (`<16-hex>_0`). Reads only the header, key and
/// EOF records up-front via a `FileHandle` — the (potentially large) stream
/// bodies are read on demand, so opening a file never loads the whole thing
/// into memory. This keeps indexing CPU/RSS low even for big binary resources.
nonisolated final class SimpleCacheFile {
    let path: URL
    let key: String
    let header: SimpleCacheHeader
    let hasData: Bool

    private let handle: FileHandle
    private let fileSize: Int
    let stream0EOF: SimpleCacheEOF?
    let stream1EOF: SimpleCacheEOF?
    private let stream0StartOffsetNegative: Int
    private let stream1StartOffset: Int
    let stream1Length: Int

    private static var headerSize: Int { eightBytePickleAlignment ? 24 : 20 }

    init(path: URL) throws {
        self.path = path
        guard let handle = try? FileHandle(forReadingFrom: path) else {
            throw CacheReadError.fileNotFound(path.lastPathComponent)
        }
        self.handle = handle
        let attrs = try? FileManager.default.attributesOfItem(atPath: path.path)
        self.fileSize = (attrs?[.size] as? Int) ?? 0

        // Header + key from the front.
        let headerData = (try? handle.read(upToCount: SimpleCacheFile.headerSize)) ?? Data()
        self.header = try SimpleCacheHeader.from(reader: BinaryReader(headerData))
        let keyData = (try? handle.read(upToCount: header.keyLength)) ?? Data()
        self.key = String(bytes: keyData, encoding: .isoLatin1) ?? ""

        let headerAndKey = SimpleCacheFile.headerSize + header.keyLength
        if fileSize <= headerAndKey {
            self.hasData = false
            self.stream0EOF = nil; self.stream1EOF = nil
            self.stream0StartOffsetNegative = 0; self.stream1StartOffset = 0; self.stream1Length = 0
            return
        }
        self.hasData = true

        func readEOF(at offset: Int) throws -> SimpleCacheEOF {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            let d = (try? handle.read(upToCount: simpleEOFSize)) ?? Data()
            return try SimpleCacheEOF.from(reader: BinaryReader(d))
        }

        // Stream 0 EOF at the very end.
        let s0eof = try readEOF(at: fileSize - simpleEOFSize)
        self.stream0EOF = s0eof
        var s0Neg = -simpleEOFSize - s0eof.streamSize
        if s0eof.hasKeySHA256 { s0Neg -= 32 }
        self.stream0StartOffsetNegative = s0Neg

        // Stream 1 EOF sits before stream 0's data (and the optional key SHA-256).
        var s1EndOffset = fileSize - simpleEOFSize - simpleEOFSize - s0eof.streamSize
        if s0eof.hasKeySHA256 { s1EndOffset -= 32 }
        self.stream1EOF = try readEOF(at: s1EndOffset)
        self.stream1StartOffset = SimpleCacheFile.headerSize + header.keyLength
        self.stream1Length = s1EndOffset - stream1StartOffset
    }

    deinit { try? handle.close() }

    func getStream0() throws -> Data {
        guard hasData, let eof = stream0EOF else { return Data() }
        try handle.seek(toOffset: UInt64(max(0, fileSize + stream0StartOffsetNegative)))
        return (try handle.read(upToCount: eof.streamSize)) ?? Data()
    }

    func getStream1() throws -> Data {
        guard hasData, stream1Length > 0 else { return Data() }
        try handle.seek(toOffset: UInt64(stream1StartOffset))
        return (try handle.read(upToCount: stream1Length)) ?? Data()
    }

    var metadataStartOffsetNegative: Int { stream0StartOffsetNegative }
    var dataStartOffset: Int { stream1StartOffset }
    var keyHash: UInt32 { header.keyHash }
}

nonisolated struct SimpleCacheEntryInfo {
    let sourceFile: String
    let headerVersion: UInt32
    let keyHash: UInt32
    let dataSize: Int
    let metadataSize: Int
    let stream0CRC: UInt32?
    let stream1CRC: UInt32?
    let hasKeySHA256: Bool
}

nonisolated final class ChromiumSimpleFileCache: ChromiumCache {
    let cacheTypeDescription = "Simple Cache"

    private let dir: URL
    private var fileLookup: [String: [URL]] = [:]
    private(set) var entryInfo: [String: [SimpleCacheEntryInfo]] = [:]
    private(set) var orderedKeys: [String] = []
    private var entryDates: [String: Date] = [:]

    init(cacheDir: URL) throws {
        self.dir = cacheDir
        try buildKeys()
    }

    private static let stream01Pattern = try! NSRegularExpression(pattern: "^[0-9a-f]{16}_0$")

    private func buildKeys() throws {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            let range = NSRange(name.startIndex..., in: name)
            guard ChromiumSimpleFileCache.stream01Pattern.firstMatch(in: name, range: range) != nil else { continue }
            guard let cf = try? SimpleCacheFile(path: file) else { continue }

            if fileLookup[cf.key] == nil { orderedKeys.append(cf.key) }
            fileLookup[cf.key, default: []].append(file)

            if let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                // Keep the most recent file's date for the key.
                if let existing = entryDates[cf.key] { entryDates[cf.key] = max(existing, mtime) }
                else { entryDates[cf.key] = mtime }
            }

            let info = SimpleCacheEntryInfo(
                sourceFile: name,
                headerVersion: cf.header.version,
                keyHash: cf.header.keyHash,
                dataSize: cf.hasData ? cf.stream1Length : 0,
                metadataSize: cf.hasData ? (cf.stream0EOF?.streamSize ?? 0) : 0,
                stream0CRC: (cf.hasData && cf.stream0EOF?.hasCRC == true) ? cf.stream0EOF?.dataCRC : nil,
                stream1CRC: (cf.hasData && cf.stream1EOF?.hasCRC == true) ? cf.stream1EOF?.dataCRC : nil,
                hasKeySHA256: cf.hasData ? (cf.stream0EOF?.hasKeySHA256 ?? false) : false)
            entryInfo[cf.key, default: []].append(info)
        }
    }

    func keys() -> [String] { orderedKeys }

    func getMetadata(_ key: String) throws -> [CachedMetadata?] {
        var result: [CachedMetadata?] = []
        for file in fileLookup[key] ?? [] {
            guard let cf = try? SimpleCacheFile(path: file) else { result.append(nil); continue }
            let buffer = (try? cf.getStream0()) ?? Data()
            if buffer.isEmpty {
                result.append(nil)
            } else if let meta = try? CachedMetadata.from(buffer: buffer) {
                result.append(meta)
            } else if let meta = try? CachedMetadata.fromCodeCache(buffer: buffer) {
                result.append(meta)
            } else {
                result.append(nil)
            }
        }
        return result
    }

    func getCachefile(_ key: String) throws -> [Data?] {
        var result: [Data?] = []
        for file in fileLookup[key] ?? [] {
            guard let cf = try? SimpleCacheFile(path: file) else { result.append(nil); continue }
            result.append((try? cf.getStream1()) ?? Data())
        }
        return result
    }

    func getEntryInfo(_ key: String) -> [SimpleCacheEntryInfo] { entryInfo[key] ?? [] }

    func entryDate(_ key: String) -> Date? { entryDates[key] }

    func changeToken(_ key: String) -> String {
        guard let info = entryInfo[key]?.first else { return "?" }
        // The stream-1 CRC (read cheaply from the file's EOF record) plus sizes
        // make a strong fingerprint without decompressing the body.
        let date = entryDates[key].map { Int($0.timeIntervalSince1970) } ?? 0
        return "\(info.dataSize)-\(info.metadataSize)-\(info.stream1CRC ?? 0)-\(info.stream0CRC ?? 0)-\(date)"
    }

    func cachefileLocator(_ key: String) -> BlobLocator? {
        guard let file = fileLookup[key]?.first else { return nil }
        return .simpleStream1(file: file.path)
    }

    func bodySize(_ key: String) -> Int { entryInfo[key]?.first?.dataSize ?? 0 }

    func getFileForKey(_ key: String) -> [String] { (fileLookup[key] ?? []).map { $0.lastPathComponent } }

    func getLocationForMetadata(_ key: String) -> [CacheFileLocation] {
        var result: [CacheFileLocation] = []
        for file in fileLookup[key] ?? [] {
            let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
            let length = (attrs?[.size] as? Int) ?? 0
            guard let cf = try? SimpleCacheFile(path: file) else { continue }
            result.append(CacheFileLocation(fileName: file.lastPathComponent,
                                            offset: length + cf.metadataStartOffsetNegative))
        }
        return result
    }

    func getLocationForCachefile(_ key: String) -> [CacheFileLocation] {
        var result: [CacheFileLocation] = []
        for file in fileLookup[key] ?? [] {
            guard let cf = try? SimpleCacheFile(path: file) else { continue }
            result.append(CacheFileLocation(fileName: file.lastPathComponent, offset: cf.dataStartOffset))
        }
        return result
    }
}

// MARK: - Cache type detection

nonisolated enum DetectedCacheType {
    case blockFile
    case simple
}

nonisolated func guessCacheClass(cacheDir: URL) -> DetectedCacheType? {
    let dataFiles: Set<String> = ["data_0", "data_1", "data_2", "data_3"]
    guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else {
        return nil
    }
    for file in files {
        let name = file.lastPathComponent
        if name == "index-dir" { return .simple }
        if dataFiles.contains(name) { return .blockFile }
        if name.range(of: "^f_[0-9a-f]{6}", options: .regularExpression) != nil { return .blockFile }
        if name.range(of: "^[0-9a-f]{16}_0$", options: .regularExpression) != nil { return .simple }
    }
    return nil
}

/// Opens whichever cache flavour lives in `cacheDir`.
nonisolated func openChromiumCache(cacheDir: URL) throws -> ChromiumCache {
    switch guessCacheClass(cacheDir: cacheDir) {
    case .blockFile:
        return try ChromiumBlockFileCache(cacheDir: cacheDir)
    case .simple:
        return try ChromiumSimpleFileCache(cacheDir: cacheDir)
    case nil:
        throw CacheReadError.invalidValue("Could not detect Chromium cache type in \(cacheDir.lastPathComponent). Make sure you selected the Cache_Data folder.")
    }
}
