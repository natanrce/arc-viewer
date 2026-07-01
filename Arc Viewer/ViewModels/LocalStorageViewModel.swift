//
//  LocalStorageViewModel.swift
//  Arc Viewer
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
internal import Combine

@MainActor
final class LocalStorageViewModel: ObservableObject {
    @Published var rows: [LocalStorageRow] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var favicons: [String: NSImage] = [:]

    private var profileRoot = HistoryReader.defaultProfileRoot
    private var loaded = false

    /// Unique storage keys (URLs) with their record counts, sorted.
    var storageGroups: [(key: String, count: Int)] {
        var counts: [String: Int] = [:]
        for r in rows { counts[r.storageKey, default: 0] += 1 }
        return counts.map { (key: $0.key, count: $0.value) }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    func rows(for storageKey: String) -> [LocalStorageRow] {
        rows.filter { $0.storageKey == storageKey }
    }

    func favicon(for storageKey: String) -> NSImage? {
        guard let host = FaviconStore.normalizedHost(storageKey) else { return nil }
        return favicons[host]
    }

    func loadIfNeeded() { guard !loaded else { return }; loaded = true; reload(); loadFavicons() }

    func reload() {
        isLoading = true
        errorMessage = nil
        let root = profileRoot
        Task {
            do {
                let rows = try await Task.detached(priority: .userInitiated) {
                    try LocalStorageReader.load(profileRoot: root)
                }.value
                self.rows = rows.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
                self.isLoading = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.rows = []
                self.isLoading = false
            }
        }
    }

    private func loadFavicons() {
        let root = profileRoot
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) { FaviconStore.load(profileRoot: root) }.value
            var images: [String: NSImage] = [:]
            for (host, bytes) in data { if let img = NSImage(data: bytes) { images[host] = img } }
            self?.favicons = images
        }
    }

    func copyValue(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
    }

    func exportCSV(_ rows: [LocalStorageRow]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "local_storage.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let iso = ISO8601DateFormatter()
            var lines = ["storage_key,key,value,timestamp"]
            for r in rows {
                let ts = r.timestamp.map { iso.string(from: $0) } ?? ""
                lines.append([r.storageKey, r.scriptKey, r.value, ts].map(CSV.escape).joined(separator: ","))
            }
            try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: url)
        }
    }
}
