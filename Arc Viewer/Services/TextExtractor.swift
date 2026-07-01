//
//  TextExtractor.swift
//  Arc Viewer
//
//  Decides whether a cached resource is textual and, if so, produces a clean
//  string to feed the full-text index. HTML is reduced to visible text
//  (scripts/styles/markup stripped); other text formats pass through with
//  whitespace normalised. Binary resources return no content (metadata only).
//

import Foundation

nonisolated enum TextExtractor {
    /// Upper bound on indexed text per entry, to keep the FTS index compact.
    static let maxContentCharacters = 200_000

    struct Classification {
        let isText: Bool
        let isHTML: Bool
    }

    // MARK: - Classification

    static func classify(mime: String?, path: String) -> Classification {
        let m = (mime ?? "").lowercased()
        let ext = (path as NSString).pathExtension.lowercased()

        let html = m.contains("text/html")
            || m.contains("application/xhtml")
            || ext == "html" || ext == "htm"
        if html { return Classification(isText: true, isHTML: true) }

        let textMimes = [
            "application/json", "application/ld+json", "application/manifest+json",
            "application/xml", "text/xml", "application/javascript", "text/javascript",
            "application/x-javascript", "application/ecmascript", "image/svg+xml",
            "application/x-www-form-urlencoded", "application/graphql",
        ]
        if m.hasPrefix("text/") || textMimes.contains(where: { m.contains($0) }) {
            return Classification(isText: true, isHTML: false)
        }

        let textExts: Set<String> = [
            "json", "xml", "js", "mjs", "cjs", "ts", "css", "svg", "txt",
            "csv", "tsv", "md", "html", "htm", "vtt", "srt", "map", "yaml", "yml",
        ]
        if textExts.contains(ext) {
            return Classification(isText: true, isHTML: ext == "html" || ext == "htm")
        }

        return Classification(isText: false, isHTML: false)
    }

    // MARK: - Extraction

    /// Hard cap on bytes fed to the (regex-based) extractor, to bound CPU/memory
    /// on very large JS/HTML/JSON resources.
    static let maxInputBytes = 2_000_000

    /// Returns clean searchable text, or nil for binary content.
    static func extractText(from data: Data, mime: String?, path: String) -> String? {
        let cls = classify(mime: mime, path: path)
        guard cls.isText else { return nil }

        let slice = data.count > maxInputBytes ? data.prefix(maxInputBytes) : data
        let raw = String(decoding: slice, as: UTF8.self)
        let text = cls.isHTML ? stripHTML(raw) : normalizeWhitespace(raw)
        if text.isEmpty { return nil }
        return text.count > maxContentCharacters ? String(text.prefix(maxContentCharacters)) : text
    }

    // MARK: - HTML → visible text

    private static let scriptStyleRegex = try! NSRegularExpression(
        pattern: "<(script|style)\\b[^>]*>[\\s\\S]*?</\\1>",
        options: [.caseInsensitive])
    private static let commentRegex = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->")
    private static let tagRegex = try! NSRegularExpression(pattern: "<[^>]+>")

    static func stripHTML(_ html: String) -> String {
        var s = html
        s = replace(scriptStyleRegex, in: s, with: " ")
        s = replace(commentRegex, in: s, with: " ")
        s = replace(tagRegex, in: s, with: " ")
        s = decodeEntities(s)
        return normalizeWhitespace(s)
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, with repl: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: repl)
    }

    private static func normalizeWhitespace(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
        "&#39;": "'", "&nbsp;": " ", "&copy;": "©", "&reg;": "®", "&hellip;": "…",
        "&mdash;": "—", "&ndash;": "–", "&rsquo;": "’", "&lsquo;": "‘",
        "&rdquo;": "”", "&ldquo;": "“", "&trade;": "™", "&euro;": "€",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var result = s
        for (entity, value) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        // Numeric entities: &#123; and &#x1F600;
        result = decodeNumericEntities(result)
        return result
    }

    private static let numericEntityRegex = try! NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);")

    private static func decodeNumericEntities(_ s: String) -> String {
        let ns = s as NSString
        let matches = numericEntityRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var result = ""
        var last = 0
        for m in matches {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let isHex = ns.substring(with: m.range(at: 1)) == "x"
            let digits = ns.substring(with: m.range(at: 2))
            if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
