//
//  HistoryEntry.swift
//  Arc Viewer
//

import Foundation

nonisolated struct HistoryEntry: Identifiable, Sendable {
    let id: Int64
    let url: String
    let title: String
    let date: Date
}
