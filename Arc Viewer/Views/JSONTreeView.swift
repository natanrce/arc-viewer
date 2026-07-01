//
//  JSONTreeView.swift
//  Arc Viewer
//
//  Collapsible, syntax-highlighted JSON tree.
//

import SwiftUI

struct JSONTreeView: View {
    let root: JSONValue

    var body: some View {
        // Horizontal scroll for long lines; the enclosing detail ScrollView
        // handles vertical scrolling.
        ScrollView(.horizontal, showsIndicators: false) {
            JSONNodeView(key: nil, value: root, depth: 0, isLast: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private let jsonFont = Font.system(.caption, design: .monospaced)

struct JSONNodeView: View {
    let key: String?
    let value: JSONValue
    let depth: Int
    let isLast: Bool
    @State private var expanded: Bool

    init(key: String?, value: JSONValue, depth: Int, isLast: Bool) {
        self.key = key
        self.value = value
        self.depth = depth
        self.isLast = isLast
        _expanded = State(initialValue: depth < 2)   // auto-expand the top levels
    }

    var body: some View {
        switch value {
        case let .object(pairs):
            container(open: "{", close: "}", count: pairs.count) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { idx, kv in
                    JSONNodeView(key: kv.key, value: kv.value, depth: depth + 1, isLast: idx == pairs.count - 1)
                }
            }
        case let .array(items):
            container(open: "[", close: "]", count: items.count) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, v in
                    JSONNodeView(key: nil, value: v, depth: depth + 1, isLast: idx == items.count - 1)
                }
            }
        default:
            leafRow
        }
    }

    // Container (object/array) with a disclosure chevron.
    @ViewBuilder
    private func container<Content: View>(
        open: String, close: String, count: Int, @ViewBuilder children: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 10)
                    keyText()
                    if expanded {
                        Text(open).foregroundStyle(.secondary)
                    } else {
                        (Text(open) + Text(" … ").foregroundStyle(.tertiary) + Text(close)).foregroundStyle(.secondary)
                        Text(count == 1 ? "1 item" : "\(count) items")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                        trailingComma()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                children().padding(.leading, 14)
                HStack(spacing: 0) {
                    Color.clear.frame(width: 10)
                    Text(close).foregroundStyle(.secondary)
                    trailingComma()
                }
            }
        }
        .font(jsonFont)
    }

    private var leafRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Color.clear.frame(width: 14)
            keyText()
            valueText()
            trailingComma()
        }
        .font(jsonFont)
    }

    @ViewBuilder
    private func keyText() -> some View {
        if let key {
            Text("\"\(key)\"").foregroundStyle(.purple) + Text(": ").foregroundStyle(.secondary)
        }
    }

    private func valueText() -> Text {
        switch value {
        case let .string(s): return Text("\"\(s)\"").foregroundStyle(.red)
        case let .number(n): return Text(n).foregroundStyle(.blue)
        case let .bool(b): return Text(b ? "true" : "false").foregroundStyle(.orange)
        case .null: return Text("null").foregroundStyle(.secondary)
        default: return Text("")
        }
    }

    @ViewBuilder
    private func trailingComma() -> some View {
        if !isLast { Text(",").foregroundStyle(.secondary) }
    }
}
