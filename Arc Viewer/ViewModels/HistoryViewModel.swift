//
//  HistoryViewModel.swift
//  Arc Viewer
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
internal import Combine

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""

    private var profileRoot = HistoryReader.defaultProfileRoot
    private var loaded = false

    var filteredEntries: [HistoryEntry] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.url.localizedCaseInsensitiveContains(q) || $0.title.localizedCaseInsensitiveContains(q)
        }
    }

    func loadIfNeeded() { guard !loaded else { return }; loaded = true; reload() }

    func reload() {
        isLoading = true
        errorMessage = nil
        let root = profileRoot
        Task {
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    try HistoryReader.load(profileRoot: root)
                }.value
                self.entries = entries
                self.isLoading = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.entries = []
                self.isLoading = false
            }
        }
    }

    func chooseProfileFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the Arc profile folder (contains the History file)"
        panel.directoryURL = HistoryReader.defaultProfileRoot.deletingLastPathComponent()
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.profileRoot = url
                self.loaded = true
                self.reload()
            }
        }
    }

    func copyURL(_ url: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url, forType: .string)
    }

    func exportCSV(_ entries: [HistoryEntry]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? HistoryViewModel.makeCSV(entries).data(using: .utf8)?.write(to: url)
        }
    }

    private static func makeCSV(_ entries: [HistoryEntry]) -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["id,url,title,timestamp"]
        for e in entries {
            lines.append([String(e.id), e.url, e.title, iso.string(from: e.date)].map(CSV.escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
