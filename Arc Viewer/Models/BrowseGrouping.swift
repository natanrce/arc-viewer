//
//  BrowseGrouping.swift
//  Arc Viewer
//
//  Groups cache items into the sidebar tree: date → top frame site → domain.
//

import Foundation

nonisolated struct DomainGroup: Identifiable, Sendable {
    let domain: String
    var items: [CacheItem]
    var id: String { domain }
}

/// Requests grouped under the page (top frame site) that originated them.
nonisolated struct FrameGroup: Identifiable, Sendable {
    let host: String
    var domains: [DomainGroup]
    var id: String { host }
    var itemCount: Int { domains.reduce(0) { $0 + $1.items.count } }
}

nonisolated struct DateSection: Identifiable, Sendable {
    let day: Date?
    var frames: [FrameGroup]
    var id: String { DateSection.dayKey(day) }

    static func dayKey(_ day: Date?) -> String {
        day.map { String($0.timeIntervalSince1970) } ?? "undated"
    }

    var title: String {
        guard let day else { return "Sem data" }
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Hoje" }
        if cal.isDateInYesterday(day) { return "Ontem" }
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEEE d MMM yyyy")
        return f.string(from: day).capitalized
    }

    /// Builds the tree date → top frame site → resource domain → items,
    /// preserving the incoming (date-descending) order.
    static func build(from items: [CacheItem]) -> [DateSection] {
        let cal = Calendar.current
        var dayOrder: [Date?] = []
        var byDay: [String: [CacheItem]] = [:]
        for item in items {
            let day = item.date.map { cal.startOfDay(for: $0) }
            let key = dayKey(day)
            if byDay[key] == nil { dayOrder.append(day) }
            byDay[key, default: []].append(item)
        }
        return dayOrder.map { day in
            var byFrame: [String: [String: [CacheItem]]] = [:]
            var frameOrder: [String] = []
            for item in byDay[dayKey(day)] ?? [] {
                let frame = item.topFrameHost
                if byFrame[frame] == nil { frameOrder.append(frame) }
                byFrame[frame, default: [:]][item.domain, default: []].append(item)
            }
            let frames = frameOrder.map { host -> FrameGroup in
                let domains = (byFrame[host] ?? [:])
                    .map { DomainGroup(domain: $0.key, items: $0.value) }
                    .sorted { $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending }
                return FrameGroup(host: host, domains: domains)
            }
            .sorted { $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending }
            return DateSection(day: day, frames: frames)
        }
    }
}
