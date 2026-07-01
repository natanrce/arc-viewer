//
//  LocalStorageWindowView.swift
//  Arc Viewer
//

import SwiftUI

struct LocalStorageWindowView: View {
    @StateObject private var viewModel = LocalStorageViewModel()
    @State private var selectedKey: String?
    @State private var urlFilter = ""
    @State private var sortOrder = [KeyPathComparator(\LocalStorageRow.scriptKey)]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current
        f.dateStyle = .short; f.timeStyle = .medium; return f
    }()

    private var groups: [(key: String, count: Int)] {
        let all = viewModel.storageGroups
        let q = urlFilter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.key.localizedCaseInsensitiveContains(q) }
    }

    private var detailRows: [LocalStorageRow] {
        guard let key = selectedKey else { return [] }
        return viewModel.rows(for: key).sorted(using: sortOrder)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                SidebarSearchField(text: $urlFilter, prompt: "Search URLs…")
                    .padding(.horizontal, 10).padding(.vertical, 8)
                Divider()
                List(groups, id: \.key, selection: $selectedKey) { group in
                    HStack(spacing: 6) {
                        LeadingIcon(
                            favicon: viewModel.favicon(for: group.key),
                            systemName: group.key.hasPrefix("chrome-extension://") ? "puzzlepiece.extension.fill" : "globe")
                        Text(Self.displayURL(group.key)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("\(group.count)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .navigationTitle("Local Storage")
            .frame(minWidth: 240)
        } detail: {
            if selectedKey != nil {
                detailTable
            } else {
                ContentUnavailableView("Select a URL", systemImage: "internaldrive",
                                       description: Text("Choose a URL to view its local storage"))
            }
        }
        .toolbar {
            ToolbarItem {
                Button { viewModel.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .disabled(viewModel.isLoading)
            }
            ToolbarItem {
                Button {
                    viewModel.exportCSV(selectedKey == nil ? viewModel.rows : detailRows)
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(viewModel.rows.isEmpty)
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView("Loading local storage…").padding()
                    .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
            } else if let error = viewModel.errorMessage {
                ContentUnavailableView("Could not load local storage", systemImage: "internaldrive",
                                       description: Text(error))
            } else if viewModel.rows.isEmpty {
                ContentUnavailableView("No local storage", systemImage: "internaldrive")
            }
        }
        .frame(minWidth: 820, minHeight: 440)
        .task { viewModel.loadIfNeeded() }
        .onChange(of: viewModel.rows.count) { _, _ in
            if selectedKey == nil { selectedKey = groups.first?.key }
        }
    }

    private var detailTable: some View {
        Table(detailRows, sortOrder: $sortOrder) {
            TableColumn("Key", value: \.scriptKey) { row in
                Text(row.scriptKey).lineLimit(1)
            }
            .width(min: 140, ideal: 200)
            TableColumn("Value", value: \.value) { row in
                Text(row.value).lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 220, ideal: 380)
            TableColumn("Timestamp") { row in
                Text(row.timestamp.map { LocalStorageWindowView.dateFormatter.string(from: $0) } ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 160)
        }
        .contextMenu(forSelectionType: LocalStorageRow.ID.self) { ids in
            if let id = ids.first, let row = detailRows.first(where: { $0.id == id }) {
                Button("Copy Value") { viewModel.copyValue(row.value) }
                Button("Copy Key") { viewModel.copyValue(row.scriptKey) }
            }
        }
        .navigationTitle(selectedKey.map(Self.displayURL) ?? "Local Storage")
    }

    /// Strips the http(s):// scheme for display (keeps chrome-extension://, etc.).
    static func displayURL(_ s: String) -> String {
        if s.hasPrefix("https://") { return String(s.dropFirst(8)) }
        if s.hasPrefix("http://") { return String(s.dropFirst(7)) }
        return s
    }
}
