//
//  CSV.swift
//  Arc Viewer
//

import Foundation

nonisolated enum CSV {
    /// Quotes a field when it contains a comma, quote or newline (RFC 4180).
    static func escape(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
