//
//  JSONParser.swift
//  Arc Viewer
//
//  Lightweight recursive-descent JSON parser (preserves object key order).
//

import Foundation

nonisolated struct JSONParser {
    private let chars: [Character]
    private var pos = 0

    private init(_ s: String) { chars = Array(s) }

    /// Parses a full JSON document. Returns nil unless the whole string is valid
    /// JSON whose root is an object or array (so plain text/numbers aren't shown
    /// as JSON).
    static func parse(_ s: String) -> JSONValue? {
        var p = JSONParser(s)
        p.skipWhitespace()
        guard let value = p.parseValue(), value.isContainer else { return nil }
        p.skipWhitespace()
        return p.pos == p.chars.count ? value : nil
    }

    private func peek() -> Character? { pos < chars.count ? chars[pos] : nil }

    private mutating func skipWhitespace() {
        while let c = peek(), c == " " || c == "\n" || c == "\t" || c == "\r" { pos += 1 }
    }

    private mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard let c = peek() else { return nil }
        switch c {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return parseString().map { .string($0) }
        case "t", "f": return parseBool()
        case "n": return parseNull()
        default: return parseNumber()
        }
    }

    private mutating func parseObject() -> JSONValue? {
        pos += 1  // {
        skipWhitespace()
        if peek() == "}" { pos += 1; return .object([]) }
        var pairs: [(key: String, value: JSONValue)] = []
        while true {
            skipWhitespace()
            guard let key = parseString() else { return nil }
            skipWhitespace()
            guard peek() == ":" else { return nil }
            pos += 1
            guard let value = parseValue() else { return nil }
            pairs.append((key, value))
            skipWhitespace()
            switch peek() {
            case ",": pos += 1
            case "}": pos += 1; return .object(pairs)
            default: return nil
            }
        }
    }

    private mutating func parseArray() -> JSONValue? {
        pos += 1  // [
        skipWhitespace()
        if peek() == "]" { pos += 1; return .array([]) }
        var items: [JSONValue] = []
        while true {
            guard let value = parseValue() else { return nil }
            items.append(value)
            skipWhitespace()
            switch peek() {
            case ",": pos += 1
            case "]": pos += 1; return .array(items)
            default: return nil
            }
        }
    }

    private mutating func parseString() -> String? {
        guard peek() == "\"" else { return nil }
        pos += 1
        var out = ""
        while pos < chars.count {
            let ch = chars[pos]; pos += 1
            if ch == "\"" { return out }
            if ch == "\\" {
                guard pos < chars.count else { return nil }
                let e = chars[pos]; pos += 1
                switch e {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "u":
                    guard pos + 4 <= chars.count else { return nil }
                    let hex = String(chars[pos ..< pos + 4]); pos += 4
                    if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                        out.append(Character(scalar))
                    }
                default: return nil
                }
            } else {
                out.append(ch)
            }
        }
        return nil
    }

    private mutating func parseNumber() -> JSONValue? {
        let start = pos
        while let c = peek(), "-+.eE0123456789".contains(c) { pos += 1 }
        guard pos > start else { return nil }
        return .number(String(chars[start ..< pos]))
    }

    private mutating func parseBool() -> JSONValue? {
        if match("true") { return .bool(true) }
        if match("false") { return .bool(false) }
        return nil
    }

    private mutating func parseNull() -> JSONValue? {
        match("null") ? .null : nil
    }

    private mutating func match(_ literal: String) -> Bool {
        let lit = Array(literal)
        guard pos + lit.count <= chars.count, Array(chars[pos ..< pos + lit.count]) == lit else { return false }
        pos += lit.count
        return true
    }
}
