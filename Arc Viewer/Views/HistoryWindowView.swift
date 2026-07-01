//
//  HistoryWindowView.swift
//  Arc Viewer
//

import SwiftUI

struct HistoryWindowView: View {
    @StateObject private var viewModel = HistoryViewModel()
    @State private var sortOrder = [KeyPathComparator(\HistoryEntry.date, order: .reverse)]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current
        f.dateStyle = .short; f.timeStyle = .medium; return f
    }()

    private var displayed: [HistoryEntry] { viewModel.filteredEntries.sorted(using: sortOrder) }

    var body: some View {
        Table(displayed, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { entry in
                Text(entry.title.isEmpty ? entry.url : entry.title).lineLimit(1)
            }
            TableColumn("URL", value: \.url) { entry in
                Text(entry.url).lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 200, ideal: 360)
            TableColumn("Date", value: \.date) { entry in
                Text(HistoryWindowView.dateFormatter.string(from: entry.date))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 140, ideal: 170)
        }
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            if let id = ids.first, let entry = displayed.first(where: { $0.id == id }) {
                Button("Copy URL") { viewModel.copyURL(entry.url) }
            }
        }
        .navigationTitle("History")
        .searchable(text: $viewModel.searchText, prompt: "Search history…")
        .toolbar {
            ToolbarItem {
                Button { viewModel.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .disabled(viewModel.isLoading)
            }
            ToolbarItem {
                Button { viewModel.exportCSV(displayed) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(viewModel.entries.isEmpty)
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView("Loading history…").padding()
                    .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
            } else if let error = viewModel.errorMessage {
                ContentUnavailableView {
                    Label("Could not load history", systemImage: "clock.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Choose Profile Folder…") { viewModel.chooseProfileFolder() }
                }
            } else if viewModel.entries.isEmpty {
                ContentUnavailableView("No history", systemImage: "clock")
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .task { viewModel.loadIfNeeded() }
    }
}
