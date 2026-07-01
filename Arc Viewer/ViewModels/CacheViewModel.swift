//
//  CacheViewModel.swift
//  Arc Viewer
//
//  Orchestrates the pipeline: open cache folder → open the SQLite index →
//  run the incremental indexer (off-main, with live progress) → serve the
//  grouped sidebar from the DB and FTS-backed search results to the UI.
//
//  Layering
//  --------
//  ChromiumCache (reader)  →  CacheIndexer (actor)  →  AppDatabase (GRDB)
//                                                        ↑
//  SwiftUI  ←  CacheViewModel (@MainActor)  ←  SearchService (reads)
//

import SwiftUI
import AppKit
internal import Combine

/// Orchestrates the pipeline: open cache folder → open the SQLite index → run
/// the incremental indexer (off-main, with live progress) → serve the grouped
/// sidebar and FTS search results to the UI.
@MainActor
final class CacheViewModel: ObservableObject {
    // Sidebar (browse) — capped to the most recent entries; grouping is
    // precomputed into `sections` so SwiftUI never re-groups on every render.
    @Published var items: [CacheItem] = []
    @Published var sections: [DateSection] = []
    @Published var cacheTypeDescription = ""
    @Published var cachePath = ""
    @Published var totalIndexed = 0

    /// Browse list grows in pages via infinite scroll.
    /// Browse loads whole days at a time; scrolling reveals older days.
    private var browseDays = 1
    private var isLoadingMoreBrowse = false

    /// Whether more browse entries can be loaded (drives the scroll footer).
    var browseHasMore: Bool { items.count < totalIndexed }

    // Status / errors
    @Published var isLoaded = false
    @Published var showError = false
    @Published var errorMessage: String?
    @Published var showClearConfirm = false

    // Indexing progress
    @Published var indexing = IndexingProgress()

    // Search
    @Published var searchText = ""
    @Published var filter = SearchFilter()
    @Published var searchResults: [SearchHit] = []
    @Published var totalMatches = 0
    @Published var isSearching = false

    // Facets (available filter values)
    @Published var availableMimes: [String] = []
    @Published var availableStatusCodes: [Int] = []

    /// Whether the results list (rather than the grouped browse) should show.
    var showsResults: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || filter.hasFacet
    }

    // Detail
    @Published var detail: EntryDetail?

    // Sidebar visibility (toggled via ⌘S)
    @Published var columnVisibility: NavigationSplitViewVisibility = .all

    // host → favicon (from the profile's Favicons DB)
    @Published var favicons: [String: NSImage] = [:]

    func faviconForHost(_ host: String) -> NSImage? {
        favicons[host.hasPrefix("www.") ? String(host.dropFirst(4)) : host]
    }

    func toggleSidebar() {
        columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
    }

    private var database: AppDatabase?
    private var indexer: CacheIndexer?
    private var search: SearchService?
    private var cacheURL: URL?

    private var indexingTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var bodyTask: Task<Void, Never>?
    private let pageSize = 120

    static var defaultArcCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Arc/User Data/Default/Cache/Cache_Data")
    }

    var isIndexing: Bool { indexing.isActive }

    // MARK: Loading

    func autoDetectAndLoad() {
        guard cacheURL == nil else { return }
        let candidate = CacheViewModel.defaultArcCacheURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue else { return }
        open(candidate)
    }

    func reload() {
        guard let url = cacheURL else { showCachePathPicker(); return }
        open(url)
    }

    func requestClearDatabase() { showClearConfirm = true }

    /// Wipes the index database and resets the UI to an empty state.
    func clearDatabase() {
        indexingTask?.cancel()
        Task { [weak self] in
            guard let self, let db = self.database else { return }
            try? await db.clear()
            self.items = []
            self.sections = []
            self.totalIndexed = 0
            self.searchResults = []
            self.totalMatches = 0
            self.availableMimes = []
            self.availableStatusCodes = []
            self.detail = nil
            self.indexing = IndexingProgress()
            self.browseDays = 1
        }
    }

    private func open(_ url: URL) {
        cacheURL = url
        cachePath = url.path
        cacheTypeDescription = Self.typeLabel(url)
        errorMessage = nil
        browseDays = 1

        do {
            let db = try AppDatabase.make(forCacheDirectory: url)
            database = db
            search = SearchService(database: db)
            indexer = CacheIndexer(database: db)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            return
        }
        isLoaded = true

        // Show whatever is already indexed immediately, then (re)index.
        Task { await refreshSidebar() }
        startIndexing(url)
        loadFavicons()
    }

    private func loadFavicons() {
        Task { [weak self] in
            let root = HistoryReader.defaultProfileRoot
            let data = await Task.detached(priority: .utility) { FaviconStore.load(profileRoot: root) }.value
            var images: [String: NSImage] = [:]
            images.reserveCapacity(data.count)
            for (host, bytes) in data { if let img = NSImage(data: bytes) { images[host] = img } }
            self?.favicons = images
        }
    }

    private func startIndexing(_ url: URL) {
        guard let indexer else { return }
        indexingTask?.cancel()
        lastLiveRefresh = .distantPast
        // Lower priority so indexing never starves the main thread / UI.
        indexingTask = Task(priority: .utility) { [weak self] in
            await indexer.index(cacheDirectory: url) { [weak self] progress in
                guard let self else { return }
                self.indexing = progress
                self.liveRefreshIfNeeded(progress)   // surface entries as they're indexed
            }
            guard let self else { return }
            await self.refreshSidebar()
            self.runSearch(debounced: false)   // refresh any active search with new data
        }
    }

    // Throttled refresh so newly-indexed entries appear in the list live,
    // without reloading the whole table on every progress tick.
    private var lastLiveRefresh = Date.distantPast
    private var isLiveRefreshing = false

    private func liveRefreshIfNeeded(_ progress: IndexingProgress) {
        guard progress.added > 0 || progress.updated > 0 || progress.removed > 0 else { return }
        guard !isLiveRefreshing, Date().timeIntervalSince(lastLiveRefresh) > 2.0 else { return }
        lastLiveRefresh = Date()
        isLiveRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            if self.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                await self.refreshSidebar()
            } else {
                self.runSearch(debounced: false)
            }
            self.isLiveRefreshing = false
        }
    }

    /// Reveals the next older day (called from the list footer).
    func loadMoreBrowse() {
        guard !isLoadingMoreBrowse, browseHasMore else { return }
        isLoadingMoreBrowse = true
        browseDays += 1
        Task { [weak self] in
            await self?.refreshSidebar()
            self?.isLoadingMoreBrowse = false
        }
    }

    private func refreshSidebar() async {
        guard let search else { return }
        do {
            let days = browseDays
            let dayCount = try await search.distinctDayCount()
            let cutoff = try await search.dayCutoff(days: days)
            // Once all days are loaded, include undated entries at the tail.
            let includeUndated = cutoff == nil || days >= dayCount
            let rows = try await search.browseKeys(cutoff: cutoff, includeUndated: includeUndated)
            let total = try await search.totalCount()
            // Map + group off the main actor; publish ready-to-render results.
            let built = await Task.detached(priority: .utility) { () -> ([CacheItem], [DateSection]) in
                let items = CacheItem.make(from: rows)
                return (items, DateSection.build(from: items))
            }.value
            self.items = built.0
            self.sections = built.1
            self.totalIndexed = total
            await loadFacets()
        } catch {
            // Non-fatal: sidebar just stays as-is.
        }
    }

    static func typeLabel(_ url: URL) -> String {
        switch guessCacheClass(cacheDir: url) {
        case .blockFile: return "Blockfile Cache"
        case .simple: return "Simple Cache"
        case nil: return "Desconhecido"
        }
    }

    // MARK: Search

    /// Debounced (250 ms) unless `debounced` is false (e.g. order change / reindex).
    func runSearch(debounced: Bool = true) {
        searchTask?.cancel()
        let text = searchText
        let filter = filter
        guard let search else { searchResults = []; totalMatches = 0; return }

        searchTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.isSearching = true
            do {
                async let hits = search.search(text: text, filter: filter, limit: self.pageSize, offset: 0)
                async let total = search.count(text: text, filter: filter)
                let (results, count) = try await (hits, total)
                if Task.isCancelled { return }
                self.searchResults = results
                self.totalMatches = count
            } catch {
                self.searchResults = []
                self.totalMatches = 0
            }
            self.isSearching = false
        }
    }

    /// Appends the next page of results (infinite scroll).
    func loadMoreResults() {
        guard let search, searchResults.count < totalMatches, !isSearching else { return }
        let text = searchText, filter = filter, offset = searchResults.count
        Task { [weak self] in
            guard let self else { return }
            if let more = try? await search.search(text: text, filter: filter, limit: self.pageSize, offset: offset) {
                self.searchResults.append(contentsOf: more)
            }
        }
    }

    private func loadFacets() async {
        guard let search else { return }
        async let mimes = try? search.availableMimes()
        async let statuses = try? search.availableStatusCodes()
        self.availableMimes = (await mimes) ?? []
        self.availableStatusCodes = (await statuses) ?? []
    }

    // MARK: Detail

    func select(_ rawKey: String?) {
        bodyTask?.cancel()
        guard let rawKey, let database else { detail = nil; return }

        Task { [weak self] in
            guard let self, let entry = try? await database.fetchEntry(rawKey: rawKey) else {
                self?.detail = nil
                return
            }
            let locator: BlobLocator? = entry.bodyLocator
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(BlobLocator.self, from: $0) }

            var d = EntryDetail(
                rawKey: entry.rawKey,
                cacheKey: CacheKey(entry.rawKey),
                mime: entry.mime,
                contentEncoding: entry.contentEncoding,
                statusLine: entry.statusLine,
                method: entry.method,
                requestTime: entry.requestTime.map(Date.init(timeIntervalSince1970:)),
                responseTime: entry.responseTime.map(Date.init(timeIntervalSince1970:)),
                entryDate: entry.entryDate.map(Date.init(timeIntervalSince1970:)),
                dataSize: entry.dataSize,
                isText: entry.isText,
                headers: Self.parseHeaders(entry.headers),
                content: entry.content,
                bodyLocator: locator,
                body: nil)
            self.detail = d

            // Load raw body (and parse JSON) off-main, then update.
            let encoding = entry.contentEncoding
            let mime = entry.mime
            self.bodyTask = Task { [weak self] in
                let result: (body: Data?, json: JSONValue?) = await Task.detached {
                    guard let raw = locator?.readRaw() else { return (nil, nil) }
                    let decoded = ContentDecoding.decode(raw, contentEncoding: encoding)
                    return (decoded, Self.parseJSONIfLikely(decoded, mime: mime))
                }.value
                guard let self, self.detail?.rawKey == rawKey else { return }
                d.body = result.body
                d.json = result.json
                self.detail = d
            }
        }
    }

    /// Parses `data` as JSON only when it plausibly is (by MIME or leading
    /// byte) and isn't huge, to avoid wasting work on large binaries.
    nonisolated static func parseJSONIfLikely(_ data: Data, mime: String?) -> JSONValue? {
        guard data.count <= 5_000_000 else { return nil }
        let looksJSON = (mime?.contains("json") ?? false)
            || {
                let trimmed = data.prefix(64).drop { $0 == 0x20 || $0 == 0x0a || $0 == 0x09 || $0 == 0x0d }
                return trimmed.first == 0x7b || trimmed.first == 0x5b  // '{' or '['
            }()
        guard looksJSON else { return nil }
        return JSONParser.parse(String(decoding: data, as: UTF8.self))
    }

    private static func parseHeaders(_ raw: String?) -> [(name: String, value: String)] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: "\n").map { line in
            if let colon = line.firstIndex(of: ":") {
                return (String(line[..<colon]), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            }
            return ("", String(line))
        }
    }

    // MARK: Copy actions (context menu)

    func copyURL(_ url: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url, forType: .string)
    }

    func copyCachePath() {
        guard !cachePath.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cachePath, forType: .string)
    }

    func showCachePathInFinder() {
        guard !cachePath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cachePath)])
    }

    /// Copies the decoded response body: as an image when it is one, otherwise
    /// as text. The body is read off-main.
    func copyRawBody(forKey rawKey: String) {
        guard let db = database else { return }
        Task { [weak self] in
            guard let entry = try? await db.fetchEntry(rawKey: rawKey) else { return }
            let locator = Self.decodeLocator(entry.bodyLocator)
            let enc = entry.contentEncoding
            let body = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let raw = locator?.readRaw() else { return nil }
                return ContentDecoding.decode(raw, contentEncoding: enc)
            }.value
            guard self != nil, let body, !body.isEmpty else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            if let image = NSImage(data: body) {
                pb.writeObjects([image])
            } else {
                pb.setString(String(decoding: body, as: UTF8.self), forType: .string)
            }
        }
    }

    /// Copies the full raw HTTP response: status line + headers + blank line +
    /// (decoded) body.
    func copyHTTPResponse(forKey rawKey: String) {
        guard let db = database else { return }
        Task { [weak self] in
            guard let entry = try? await db.fetchEntry(rawKey: rawKey) else { return }
            let locator = Self.decodeLocator(entry.bodyLocator)
            let enc = entry.contentEncoding
            let body = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let raw = locator?.readRaw() else { return nil }
                return ContentDecoding.decode(raw, contentEncoding: enc)
            }.value
            guard self != nil else { return }

            // `headers` already stores the status line followed by the header
            // lines (newline-separated) — just switch to CRLF for HTTP.
            var head = (entry.headers ?? entry.statusLine ?? "").replacingOccurrences(of: "\n", with: "\r\n")
            if head.isEmpty { head = "HTTP/1.1 \(entry.statusCode ?? 200)" }
            let bodyString = body.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let full = head + "\r\n\r\n" + bodyString

            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(full, forType: .string)
        }
    }

    /// Copies a runnable `curl` command that re-fetches the resource.
    func copyAsCurl(forKey rawKey: String) {
        guard let db = database else { return }
        Task { [weak self] in
            guard let entry = try? await db.fetchEntry(rawKey: rawKey) else { return }
            let cmd = Self.curlCommand(url: entry.url, method: entry.method, contentEncoding: entry.contentEncoding)
            guard self != nil else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(cmd, forType: .string)
        }
    }

    private static func decodeLocator(_ json: String?) -> BlobLocator? {
        json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(BlobLocator.self, from: $0) }
    }

    static func curlCommand(url: String, method: String, contentEncoding: String?) -> String {
        let quoted = "'" + url.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var parts = ["curl"]
        if method != "GET" { parts += ["-X", method] }
        if let enc = contentEncoding, !enc.isEmpty { parts += ["--compressed"] }
        parts.append(quoted)
        return parts.joined(separator: " ")
    }

    // MARK: Folder picker

    func showCachePathPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a Chromium/Arc cache folder (e.g. Cache_Data)"
        panel.prompt = "Select"

        let realHome = NSHomeDirectory()
        let arcCachePath = (realHome as NSString).appendingPathComponent("Library/Caches/Arc/User Data/Default/Cache")
        panel.directoryURL = URL(fileURLWithPath:
            FileManager.default.fileExists(atPath: arcCachePath)
                ? arcCachePath
                : (realHome as NSString).appendingPathComponent("Library/Caches"))

        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.items = []
                self.detail = nil
                self.searchResults = []
                self.open(url)
            }
        }
    }
}
