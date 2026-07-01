//
//  LocalStorageModels.swift
//  Arc Viewer
//

import Foundation

nonisolated struct LocalStorageRow: Identifiable, Sendable {
    let id = UUID()
    let storageKey: String   // host / origin
    let scriptKey: String    // JS-visible key
    let value: String
    let timestamp: Date?     // owning batch timestamp
}
