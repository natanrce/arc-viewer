//
//  JSONValue.swift
//  Arc Viewer
//

import Foundation

/// A parsed JSON value with object key order preserved.
nonisolated indirect enum JSONValue: Sendable {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)   // kept as raw text to preserve formatting
    case bool(Bool)
    case null

    var isContainer: Bool {
        switch self { case .object, .array: return true; default: return false }
    }
}
