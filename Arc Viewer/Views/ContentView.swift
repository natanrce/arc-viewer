//
//  ContentView.swift
//  Arc Viewer
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: CacheViewModel
    @State private var selectedKey: String?
    @State private var expandedDomains: Set<String> = []
    @State private var didSeedExpansion = false

    var body: some View {
        NavigationSplitView(columnVisibility: $viewModel.columnVisibility) {
            sidebar
        } detail: {
            if let detail = viewModel.detail {
                EntryDetailView(detail: detail)
            } else {
                ContentUnavailableView(
                    "Selecione uma entrada",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Escolha uma entrada para ver metadados e conteúdo"))
            }
        }
        .task { viewModel.autoDetectAndLoad() }
        .onChange(of: selectedKey) { _, new in viewModel.select(new) }
        .onChange(of: viewModel.searchText) { _, _ in viewModel.runSearch() }
        .onChange(of: viewModel.filter) { _, _ in viewModel.runSearch(debounced: false) }
        .onChange(of: viewModel.cachePath) { _, _ in didSeedExpansion = false }
        .onChange(of: viewModel.items) { _, _ in
            // Seed the default-expanded group once per cache, not on each page append.
            if !didSeedExpansion, !viewModel.sections.isEmpty {
                seedExpandedDomains()
                didSeedExpansion = true
            }
        }
        .alert("Erro", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: { Text(viewModel.errorMessage ?? "Erro desconhecido") }
        .confirmationDialog("Limpar o banco de dados do índice?",
                            isPresented: $viewModel.showClearConfirm, titleVisibility: .visible) {
            Button("Limpar", role: .destructive) { viewModel.clearDatabase() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Todas as entradas indexadas serão removidas. O cache será reindexado ao recarregar.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            if viewModel.isLoaded { header }
            searchBar
            Divider()
            if viewModel.showsResults { resultsList } else { browseList }
        }
        .navigationTitle("Arc Viewer")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("\(viewModel.totalIndexed)", systemImage: "number").font(.caption.bold())
                Spacer()
                Text(LocalizedStringKey(viewModel.cacheTypeDescription))
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.15)).clipShape(Capsule())
            }
            if !viewModel.cachePath.isEmpty {
                Text(viewModel.cachePath)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .contextMenu {
                        Button("Copy Path") { viewModel.copyCachePath() }
                        Button("Show in Finder") { viewModel.showCachePathInFinder() }
                    }
            }
            if viewModel.isIndexing {
                IndexingBar(progress: viewModel.indexing)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }

    private var searchBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                SidebarSearchField(text: $viewModel.searchText, prompt: "Search…")
                filterMenu
            }
            if viewModel.filter.hasFacet { activeFilterChips }
            if viewModel.showsResults {
                HStack {
                    if viewModel.isSearching { ProgressView().controlSize(.small) }
                    Text("\(viewModel.totalMatches) results")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Ordenar por", selection: $viewModel.filter.order) {
                ForEach(SearchOrder.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }

            if !viewModel.availableStatusCodes.isEmpty {
                Menu(viewModel.filter.statusCodes.isEmpty ? "Status" : "Status (\(viewModel.filter.statusCodes.count))") {
                    filterOption(label: "Todos", selected: viewModel.filter.statusCodes.isEmpty) {
                        viewModel.filter.statusCodes.removeAll()
                    }
                    ForEach(viewModel.availableStatusCodes, id: \.self) { code in
                        filterOption(label: "\(code)", selected: viewModel.filter.statusCodes.contains(code)) {
                            toggle(code, in: &viewModel.filter.statusCodes)
                        }
                    }
                }
            }

            if !viewModel.availableMimes.isEmpty {
                Menu(viewModel.filter.mimes.isEmpty ? "Content-Type" : "Content-Type (\(viewModel.filter.mimes.count))") {
                    filterOption(label: "Todos", selected: viewModel.filter.mimes.isEmpty) {
                        viewModel.filter.mimes.removeAll()
                    }
                    ForEach(viewModel.availableMimes, id: \.self) { mime in
                        filterOption(label: mime, selected: viewModel.filter.mimes.contains(mime)) {
                            toggle(mime, in: &viewModel.filter.mimes)
                        }
                    }
                }
            }

            if viewModel.filter.hasFacet {
                Divider()
                Button("Limpar filtros") {
                    viewModel.filter.mimes.removeAll(); viewModel.filter.statusCodes.removeAll()
                }
            }
        } label: {
            Image(systemName: viewModel.filter.hasFacet
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Ordenar e filtrar")
    }

    @ViewBuilder
    private func filterOption(label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(label, systemImage: "checkmark") } else { Text(label) }
        }
    }

    private func toggle<T: Hashable>(_ value: T, in set: inout Set<T>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    private var activeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.filter.statusCodes.sorted(), id: \.self) { status in
                    filterChip("status \(status)") { viewModel.filter.statusCodes.remove(status) }
                }
                ForEach(viewModel.filter.mimes.sorted(), id: \.self) { mime in
                    filterChip(mime) { viewModel.filter.mimes.remove(mime) }
                }
            }
        }
    }

    private func filterChip(_ text: String, _ clear: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Text(text).lineLimit(1)
            Button(action: clear) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
        }
        .font(.caption2)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.tint.opacity(0.15)).foregroundStyle(.tint)
        .clipShape(Capsule())
    }

    // MARK: Search results

    private var resultsList: some View {
        List(selection: $selectedKey) {
            ForEach(viewModel.searchResults) { hit in
                SearchHitRow(hit: hit).tag(hit.rawKey)
                    .contextMenu { copyMenu(rawKey: hit.rawKey, url: hit.url) }
                    .onAppear {
                        if hit.id == viewModel.searchResults.last?.id { viewModel.loadMoreResults() }
                    }
            }
        }
    }

    // MARK: Browse (tree: date → top frame site → domain → item)

    // A manually-managed expandable tree. Nested DisclosureGroups inside a List
    // with programmatic `isExpanded` bindings are unreliable in SwiftUI, so we
    // flatten each date section into visible rows driven by `expandedDomains`.
    private enum BrowseRow: Identifiable {
        case frame(sectionID: String, frame: FrameGroup)
        case domain(sectionID: String, host: String, group: DomainGroup)
        case item(CacheItem)

        var id: String {
            switch self {
                case let .frame(s, f): return "f|\(s)|\(f.host)"
                case let .domain(s, h, g): return "d|\(s)|\(h)|\(g.domain)"
                case let .item(i): return "i|\(i.rawKey)"
            }
        }
    }

    private func visibleRows(_ section: DateSection) -> [BrowseRow] {
        var rows: [BrowseRow] = []
        for frame in section.frames {
            rows.append(.frame(sectionID: section.id, frame: frame))
            guard expandedDomains.contains(frameKey(section.id, frame.host)) else { continue }
            for group in frame.domains {
                rows.append(.domain(sectionID: section.id, host: frame.host, group: group))
                guard expandedDomains.contains(domainKey(section.id, frame.host, group.domain)) else { continue }
                for item in group.items { rows.append(.item(item)) }
            }
        }
        return rows
    }

    private var browseList: some View {
        List(selection: $selectedKey) {
            ForEach(viewModel.sections) { section in
                Section(LocalizedStringKey(section.title)) {
                    ForEach(visibleRows(section)) { row in
                        switch row {
                        case let .frame(sid, frame):
                            disclosureRow(
                                icon: frame.host.hasPrefix("chrome-extension://") ? "puzzlepiece.extension.fill" : "rectangle.on.rectangle",
                                favicon: viewModel.faviconForHost(frame.host),
                                title: frame.host, count: frame.itemCount,
                                indent: 0, expanded: expandedDomains.contains(frameKey(sid, frame.host))
                            ) { toggle(frameKey(sid, frame.host)) }
                        case let .domain(sid, host, group):
                            disclosureRow(
                                icon: "globe", title: group.domain, count: group.items.count,
                                indent: 14, expanded: expandedDomains.contains(domainKey(sid, host, group.domain))
                            ) { toggle(domainKey(sid, host, group.domain)) }
                        case let .item(item):
                            CacheItemRow(item: item).tag(item.id)
                                .padding(.leading, 30)   // aligns the file icon under the domain's globe
                                .contextMenu { copyMenu(rawKey: item.rawKey, url: item.url) }
                        }
                    }
                }
            }
            if viewModel.browseHasMore {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .listRowSeparator(.hidden)
                    .onAppear { viewModel.loadMoreBrowse() }
            }
        }
    }

    private func disclosureRow(
        icon: String, favicon: NSImage? = nil, title: String, count: Int, indent: CGFloat,
        expanded: Bool, toggle: @escaping () -> Void
    ) -> some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                LeadingIcon(favicon: favicon, systemName: icon)
                Text(title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(count)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.leading, indent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func frameKey(_ section: String, _ host: String) -> String { "\(section)|\(host)" }
    private func domainKey(_ section: String, _ host: String, _ domain: String) -> String { "\(section)|\(host)|\(domain)" }

    private func toggle(_ key: String) {
        if expandedDomains.contains(key) { expandedDomains.remove(key) } else { expandedDomains.insert(key) }
    }

    private func seedExpandedDomains() {
        guard let section = viewModel.sections.first, let frame = section.frames.first else {
            expandedDomains = []; return
        }
        var seed: Set<String> = [frameKey(section.id, frame.host)]
        if let domain = frame.domains.first {
            seed.insert(domainKey(section.id, frame.host, domain.domain))
        }
        expandedDomains = seed
    }

    /// Right-click "Copy" submenu shared by browse rows and search hits.
    @ViewBuilder
    private func copyMenu(rawKey: String, url: String) -> some View {
        Menu("Copy") {
            Button("Copy Raw") { viewModel.copyHTTPResponse(forKey: rawKey) }
            Button("Copy URL") { viewModel.copyURL(url) }
            Button("Copy as cURL") { viewModel.copyAsCurl(forKey: rawKey) }
            Divider()
            Button("Copy Response") { viewModel.copyRawBody(forKey: rawKey) }
        }
    }
}

// MARK: - Indexing progress bar

struct IndexingBar: View {
    let progress: IndexingProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(LocalizedStringKey(progress.phase.label)).font(.caption2.bold())
                Spacer()
                if progress.total > 0 {
                    Text("\(progress.processed)/\(progress.total)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if progress.total > 0 {
                ProgressView(value: progress.fraction).progressViewStyle(.linear)
            } else if progress.isActive {
                ProgressView().progressViewStyle(.linear)   // indeterminate while listing
            }
            HStack {
                Text("\(Int(progress.fraction * 100))%").monospacedDigit()
                if progress.itemsPerSecond > 0 {
                    Text("· \(Int(progress.itemsPerSecond))/s")
                }
                if let eta = progress.etaSeconds, progress.isActive {
                    Text("· \(Self.formatETA(eta)) restante")
                }
                Spacer()
                if progress.added + progress.updated + progress.removed > 0 {
                    Text("+\(progress.added) ~\(progress.updated) -\(progress.removed)")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    static func formatETA(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }
}

// MARK: - Search hit row

struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(hit.domain).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let d = hit.entryDate { Text(Self.date(d)).font(.caption2).foregroundStyle(.tertiary) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                let icon = contentTypeIcon(mime: hit.mime, path: hit.path)
                LeadingIcon(systemName: icon.symbol, tint: icon.color)
                Text(hit.path).font(.system(.callout, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }
            if let snippet = hit.snippet, !snippet.isEmpty {
                Text(SearchHitRow.highlight(snippet))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private static func date(_ d: Double) -> String {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: d))
    }

    /// Turns FTS snippet delimiters (STX/ETX) into styled highlighted runs.
    static func highlight(_ s: String) -> AttributedString {
        var out = AttributedString()
        var buffer = ""
        var on = false
        func flush() {
            guard !buffer.isEmpty else { return }
            var piece = AttributedString(buffer)
            if on {
                piece.backgroundColor = .yellow.opacity(0.35)
                piece.font = .caption2.bold()
            }
            out += piece
            buffer = ""
        }
        for ch in s {
            if ch == "\u{2}" { flush(); on = true }
            else if ch == "\u{3}" { flush(); on = false }
            else { buffer.append(ch) }
        }
        flush()
        return out
    }
}


struct CacheItemRow: View {
    let item: CacheItem

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current
        f.setLocalizedDateFormatFromTemplate("Hms"); return f
    }()

    var body: some View {
        let icon = contentTypeIcon(mime: item.mime, path: item.endpoint)
        HStack(alignment: .center, spacing: 6) {
            LeadingIcon(systemName: icon.symbol, tint: icon.color)
            Text(item.endpoint).font(.system(.body, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let date = item.date {
                Text(CacheItemRow.timeFormatter.string(from: date))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    .layoutPriority(1).fixedSize()
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

struct EntryDetailView: View {
    let detail: EntryDetail
    @State private var tab = Tab.metadata

    enum Tab: String, CaseIterable { case metadata = "Metadados", headers = "Headers", data = "Conteúdo", key = "Chave" }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(maxWidth: .infinity)
            .padding()

            ScrollView {
                switch tab {
                    case .metadata: metadataTab
                    case .headers: headersTab
                    case .data: DetailDataView(detail: detail)
                    case .key: keyTab
                }
            }
        }
        .navigationTitle("Entrada")
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.cacheKey.url).font(.title3.bold()).textSelection(.enabled).lineLimit(3)
            HStack(spacing: 12) {
                if let status = detail.statusLine { chip(status, "globe") }
                if let mime = detail.mime { chip(mime, "doc.text") }
                if let ce = detail.contentEncoding, !ce.isEmpty { chip(ce, "archivebox") }
            }
            .font(.caption)
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading).background(.ultraThinMaterial)
    }

    private func chip(_ t: String, _ icon: String) -> some View {
        Label(t, systemImage: icon).font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary.opacity(0.5)).clipShape(Capsule()).lineLimit(1)
    }

    private var metadataTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            InfoSection(title: "Resposta") {
                InfoRow(label: "Método", value: detail.method)
                if let s = detail.statusLine { InfoRow(label: "Status", value: s) }
                if let m = detail.mime { InfoRow(label: "MIME", value: m) }
                if let ce = detail.contentEncoding { InfoRow(label: "Content-Encoding", value: ce) }
                if let rt = detail.requestTime { InfoRow(label: "Request Time", value: Self.fmt(rt)) }
                if let rt = detail.responseTime { InfoRow(label: "Response Time", value: Self.fmt(rt)) }
                if let d = detail.entryDate { InfoRow(label: "Data da entrada", value: Self.fmt(d)) }
                InfoRow(label: "Tamanho", value: ByteCountFormatter().string(fromByteCount: Int64(detail.dataSize)))
                InfoRow(label: "Textual", value: detail.isText ? String(localized: "sim") : String(localized: "não (binário)"))
            }
        }
        .padding()
    }

    private var headersTab: some View {
        Group {
            if detail.headers.isEmpty {
                ContentUnavailableView("Sem headers", systemImage: "doc.text").padding(.top, 40)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(detail.headers.enumerated()), id: \.offset) { _, h in
                        HeaderRow(name: h.name, value: h.value)
                        Divider()
                    }
                }
                .padding(.vertical)
            }
        }
    }

    private var keyTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            InfoSection(title: "Chave de cache") {
                InfoRow(label: "URL", value: detail.cacheKey.url)
                InfoRow(label: "Raw Key", value: detail.rawKey)
                if let cred = detail.cacheKey.credentialKey {
                    InfoRow(label: "Credential Key", value: cred.isEmpty ? String(localized: "(vazio)") : cred)
                }
                if let uid = detail.cacheKey.uploadDataIdentifier { InfoRow(label: "Upload Data ID", value: String(uid)) }
                if let tf = detail.cacheKey.isolationKeyTopFrameSite { InfoRow(label: "Top Frame Site", value: tf) }
                if let vp = detail.cacheKey.isolationKeyVariablePart { InfoRow(label: "Variable Part", value: vp) }
                if detail.cacheKey.isCodeCacheKey { InfoRow(label: "Code Cache", value: String(localized: "sim")) }
                if let o = detail.cacheKey.codeCacheOrigin { InfoRow(label: "Code Cache Origin", value: o) }
            }
        }
        .padding()
    }

    static func fmt(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium
        return f.string(from: d)
    }
}

// MARK: - Detail data (body) tab

struct DetailDataView: View {
    let detail: EntryDetail
    @State private var mode: Mode? = nil   // nil = auto (JSON when available, else Text)
    enum Mode: String, CaseIterable { case json = "JSON", text = "Texto", hex = "Hex", image = "Imagem" }

    var body: some View {
        Group {
            if let data = detail.body, !data.isEmpty {
                content(data)
            } else if detail.dataSize > 0 && detail.body == nil {
                ProgressView("Carregando conteúdo…").padding(.top, 40)
            } else {
                ContentUnavailableView("Sem conteúdo", systemImage: "doc").padding(.top, 40)
            }
        }
        .onChange(of: detail.rawKey) { _, _ in mode = nil }
    }

    private func content(_ data: Data) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { effectiveMode }, set: { mode = $0 })) {
                ForEach(availableModes, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal)

            Text(ByteCountFormatter().string(fromByteCount: Int64(data.count)))
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.top, 4)

            Divider().padding(.vertical, 8)

            switch effectiveMode {
            case .json:
                if let json = detail.json {
                    JSONTreeView(root: json)
                } else {
                    Text(String(decoding: data, as: UTF8.self))
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                }
            case .text:
                Text(String(decoding: data, as: UTF8.self))
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            case .hex:
                Text(hexDump(data.prefix(8192)))
                    .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            case .image:
                if let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().scaledToFit().padding()
                } else {
                    Text("Não foi possível exibir a imagem").foregroundStyle(.secondary).padding()
                }
            }

            Divider()
            Button { export(data) } label: { Label("Exportar", systemImage: "square.and.arrow.up") }
                .buttonStyle(.bordered).padding()
        }
    }

    private var isImage: Bool { detail.body.flatMap { NSImage(data: $0) } != nil }

    private var availableModes: [Mode] {
        var modes: [Mode] = []
        if detail.json != nil { modes.append(.json) }
        modes.append(.text)
        modes.append(.hex)
        if isImage { modes.append(.image) }
        return modes
    }

    private var effectiveMode: Mode {
        if let mode, availableModes.contains(mode) { return mode }
        return detail.json != nil ? .json : .text   // auto default
    }

    private func hexDump(_ data: Data) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let chunk = bytes[offset ..< min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = chunk.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            lines.append(String(format: "%08x  %-47@  %@", offset, hex as NSString, ascii as NSString))
            offset += 16
        }
        return lines.joined(separator: "\n")
    }

    private func export(_ data: Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(string: detail.cacheKey.url)?.lastPathComponent ?? "cached_file"
        panel.begin { resp in
            if resp == .OK, let url = panel.url { try? data.write(to: url) }
        }
    }
}

// MARK: - Reusable info widgets

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 4) { content }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            (Text(LocalizedStringKey(label)) + Text(":")).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
            Spacer()
        }
        .font(.system(.caption, design: .monospaced))
    }
}

/// A header name/value pair whose value is click-to-copy. The copy affordance
/// is hidden until the row is hovered, where the text brightens too.
struct HeaderRow: View {
    let name: String
    let value: String
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !name.isEmpty {
                Text(name).font(.caption.bold()).foregroundStyle(.secondary)
            }
            Button(action: copy) {
                HStack(alignment: .top, spacing: 6) {
                    Text(value)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(hovering ? .primary : .secondary)
                    if hovering || copied {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(hovering ? .primary : .secondary)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Clique para copiar")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.12), value: copied)
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }
}

#Preview {
    ContentView(viewModel: CacheViewModel())
}
