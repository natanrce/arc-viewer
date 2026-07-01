//
//  CacheModels.swift
//  Arc Viewer
//
//  Display models for the cache browser: a sidebar item and a detail record.
//

import Foundation

/// One cache key shown in the grouped sidebar. Sendable so it can be built off
/// the main actor from DB rows.
nonisolated struct CacheItem: Identifiable, Hashable, Sendable {
    let rawKey: String
    let url: String
    let isCodeCache: Bool
    let credentialKey: String?
    let uploadDataIdentifier: Int?
    let isolationKeyTopFrameSite: String?
    let codeCacheOrigin: String?
    let date: Date?
    let statusCode: Int?
    let mime: String?

    var id: String { rawKey }

    init(cacheKey: CacheKey, date: Date?, statusCode: Int?, mime: String?) {
        rawKey = cacheKey.rawKey
        url = cacheKey.url
        isCodeCache = cacheKey.isCodeCacheKey
        credentialKey = cacheKey.credentialKey
        uploadDataIdentifier = cacheKey.uploadDataIdentifier
        isolationKeyTopFrameSite = cacheKey.isolationKeyTopFrameSite
        codeCacheOrigin = cacheKey.codeCacheOrigin
        self.date = date
        self.statusCode = statusCode
        self.mime = mime
    }

    static func == (lhs: CacheItem, rhs: CacheItem) -> Bool { lhs.rawKey == rhs.rawKey }
    func hash(into hasher: inout Hasher) { hasher.combine(rawKey) }

    var domain: String {
        if let host = URLComponents(string: url)?.host, !host.isEmpty { return host }
        if let r = url.range(of: "://") {
            let host = url[r.upperBound...].prefix { $0 != "/" }
            if !host.isEmpty { return String(host) }
        }
        return "(outros)"
    }

    var endpoint: String {
        guard let comps = URLComponents(string: url) else { return url }
        var path = comps.path.isEmpty ? "/" : comps.path
        if let query = comps.query, !query.isEmpty { path += "?\(query)" }
        return path
    }

    /// Host of the page that made the request (double-key top frame site); falls
    /// back to the resource URL. Keeps the `chrome-extension://` scheme.
    var topFrameHost: String {
        CacheItem.displayHost(from: isolationKeyTopFrameSite ?? url)
    }

    private static func displayHost(from site: String) -> String {
        if site.hasPrefix("chrome-extension://") {
            let rest = site.dropFirst("chrome-extension://".count)
            let id = rest.prefix { $0 != "/" }
            return "chrome-extension://\(id)"
        }
        return host(from: site) ?? site
    }

    private static func host(from site: String) -> String? {
        if let host = URLComponents(string: site)?.host, !host.isEmpty { return host }
        if let r = site.range(of: "://") {
            let host = site[r.upperBound...].prefix { $0 != "/" }
            if !host.isEmpty { return String(host) }
        }
        return site.isEmpty ? nil : site
    }

    /// Builds items from lightweight DB rows (off-main friendly).
    nonisolated static func make(from rows: [(rawKey: String, entryDate: Double?, statusCode: Int?, mime: String?)]) -> [CacheItem] {
        rows.map {
            CacheItem(cacheKey: CacheKey($0.rawKey),
                      date: $0.entryDate.map(Date.init(timeIntervalSince1970:)),
                      statusCode: $0.statusCode,
                      mime: $0.mime)
        }
    }
}

/// Detail pane data, sourced from the SQLite index plus a lazily-read body.
struct EntryDetail: Identifiable {
    let rawKey: String
    let cacheKey: CacheKey
    let mime: String?
    let contentEncoding: String?
    let statusLine: String?
    let method: String
    let requestTime: Date?
    let responseTime: Date?
    let entryDate: Date?
    let dataSize: Int
    let isText: Bool
    let headers: [(name: String, value: String)]
    let content: String?
    let bodyLocator: BlobLocator?
    var body: Data?
    var json: JSONValue?

    var id: String { rawKey }
}
