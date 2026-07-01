//
//  SidebarComponents.swift
//  Arc Viewer
//
//  Reusable sidebar/list UI pieces shared across the cache, history and
//  local-storage views.
//

import SwiftUI

/// A 14pt leading icon: a favicon when available, otherwise an SF Symbol.
struct LeadingIcon: View {
    var favicon: NSImage? = nil
    var systemName: String
    var tint: Color = .secondary

    var body: some View {
        if let favicon {
            Image(nsImage: favicon)
                .resizable().interpolation(.medium)
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: systemName)
                .imageScale(.small)
                .foregroundStyle(tint)
                .frame(width: 14)
        }
    }
}

/// Inline search field used at the top of sidebars (with a clear button).
struct SidebarSearchField: View {
    @Binding var text: String
    var prompt: String = "Buscar…"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.callout)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Maps a MIME type / path extension to an SF Symbol + tint for content-type icons.
nonisolated func contentTypeIcon(mime: String?, path: String) -> (symbol: String, color: Color) {
    let m = (mime ?? "").lowercased()
    let ext = (path as NSString).pathExtension.lowercased()
    func isType(_ needles: [String], _ exts: [String]) -> Bool {
        needles.contains(where: { m.contains($0) }) || exts.contains(ext)
    }

    if isType(["json"], ["json"]) { return ("curlybraces", .orange) }
    if isType(["javascript", "ecmascript"], ["js", "mjs", "cjs", "ts"]) {
        return ("chevron.left.forwardslash.chevron.right", .yellow)
    }
    if isType(["html", "xhtml"], ["html", "htm"]) { return ("doc.richtext", .orange) }
    if isType(["css"], ["css"]) { return ("paintbrush", .blue) }
    if isType(["svg"], ["svg"]) { return ("photo", .green) }
    if isType(["xml"], ["xml"]) { return ("doc.text", .gray) }
    if m.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "ico"].contains(ext) {
        return ("photo", .purple)
    }
    if m.hasPrefix("video/") || ["mp4", "webm", "mov", "m4v"].contains(ext) { return ("film", .pink) }
    if m.hasPrefix("audio/") || ["mp3", "aac", "wav", "ogg", "m4a"].contains(ext) { return ("waveform", .pink) }
    if m.hasPrefix("font/") || m.contains("font") || ["woff", "woff2", "ttf", "otf", "eot"].contains(ext) {
        return ("textformat", .gray)
    }
    if isType(["text/plain", "csv"], ["txt", "csv", "log", "md"]) { return ("doc.plaintext", .gray) }
    if m.contains("wasm") || m.contains("octet-stream") { return ("shippingbox", .gray) }
    return ("doc", .secondary)
}
