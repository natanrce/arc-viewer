import SwiftUI
import AppKit

@main
struct ArcCacheViewerApp: App {
    @StateObject private var viewModel = CacheViewModel()

    init() {
        // Disable macOS automatic window tabbing (⌘T new tabs / Merge All Windows).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
        .commands {
            ArchiveCommands()
            // Replace the default "New Window" group with our own File commands.
            CommandGroup(replacing: .newItem) {
                Button {
                    viewModel.showCachePathPicker()
                } label: {
                    Label("Open...", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button {
                    viewModel.reload()
                } label: {
                    Label("Reload Cache", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(viewModel.isIndexing)

                Button {
                    viewModel.requestClearDatabase()
                } label: {
                    Label("Clear Database", systemImage: "trash")
                }
            }

            CommandGroup(after: .sidebar) {
                Button(viewModel.columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar") {
                    viewModel.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.command])
            }
        }

        // Archive windows read straight from the Arc profile.
        Window("History", id: ArchiveCommands.historyWindowID) {
            HistoryWindowView()
        }
        .keyboardShortcut("y", modifiers: [.command])

        Window("Local Storage", id: ArchiveCommands.localStorageWindowID) {
            LocalStorageWindowView()
        }
    }
}

/// The "Archive" menu — opens the History and Local Storage windows.
struct ArchiveCommands: Commands {
    static let historyWindowID = "history"
    static let localStorageWindowID = "localstorage"
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Archive") {
            Button {
                openWindow(id: ArchiveCommands.historyWindowID)
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .keyboardShortcut("y", modifiers: [.command])

            Button {
                openWindow(id: ArchiveCommands.localStorageWindowID)
            } label: {
                Label("Local Storage", systemImage: "internaldrive")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
