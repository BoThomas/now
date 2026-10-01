import Foundation
import NowCore

/// Agenda presentation for the Linux shell: pure mappings from NowCore
/// snapshots to the tray bar title and dbusmenu rows, mirroring the macOS
/// menu's section semantics (running first, the next-start group, capped
/// later rows) with Linux-owned formatting only. The macOS `Fmt` countdown
/// policy is duplicated here on purpose — presentation stays shell-owned.
enum AgendaMenu {
    struct Row: Sendable {
        var label: String
        var action = ""
        var isEnabled = true
    }

    struct Section: Sendable {
        var header: String
        var rows: [Row]
    }

    /// The bar title: countdown to the next start, or "ends …" while running,
    /// matching the macOS menu bar focus choice (running wins).
    static func barTitle(events: [MeetingEvent], now: Date) -> String {
        if let running = events.first(where: { $0.start <= now && now < $0.end && !$0.isMuted }) {
            return "ends \(countdown(to: running.end, now: now))"
        }
        if let next = upcoming(events, now: now).first {
            return countdown(to: next.start, now: now)
        }
        return "now"
    }

    /// Menu sections for the snapshot: NOW (running), NEXT (the next-start
    /// group), and later meetings capped by the core menu limit.
    static func sections(events: [MeetingEvent], now: Date, limit: Int? = nil) -> [Section] {
        let cap = limit ?? AppSettings().menuMeetingLimit
        var result: [Section] = []
        let running = events
            .filter { $0.start <= now && now < $0.end }
            .sorted { $0.end < $1.end }
        if !running.isEmpty {
            result.append(Section(header: "NOW", rows: running.map { row($0, now: now, joinable: true) }))
        }
        let next = upcoming(events, now: now)
        if !next.isEmpty {
            result.append(Section(header: "NEXT", rows: next.prefix(1).map { row($0, now: now, joinable: true) }))
            let later = Array(next.dropFirst())
            if !later.isEmpty {
                var header = "LATER"
                var rows: [Row] = []
                for event in later.prefix(cap) {
                    let day = dayHeader(for: event.start, now: now)
                    if day != header {
                        if !rows.isEmpty { result.append(Section(header: header, rows: rows)) }
                        header = day
                        rows = []
                    }
                    rows.append(row(event, now: now, joinable: false))
                }
                if !rows.isEmpty { result.append(Section(header: header, rows: rows)) }
            }
        }
        if result.isEmpty {
            result.append(Section(header: "NOW", rows: [Row(label: "No upcoming meetings")]))
        }
        return result
    }

    /// Converts sections to dbusmenu nodes with sequential ids; `join:<url>`
    /// actions ride on rows, section headers are disabled rows.
    static func nodes(sections: [Section]) -> DBusMenu.Node {
        var id: Int32 = 1
        var children: [DBusMenu.Node] = []
        for section in sections {
            var header = DBusMenu.Node.item(id, section.header)
            header.isEnabled = false
            children.append(header)
            id += 1
            for entry in section.rows {
                var node = entry.action.isEmpty
                    ? DBusMenu.Node.item(id, entry.label)
                    : DBusMenu.Node.item(id, entry.label, action: entry.action)
                node.isEnabled = entry.isEnabled
                children.append(node)
                id += 1
            }
            children.append(.separator(id))
            id += 1
        }
        var root = DBusMenu.Node(id: 0)
        root.children = children
        return root
    }

    // MARK: Row shaping

    private static func row(_ event: MeetingEvent, now: Date, joinable: Bool) -> Row {
        var label = "\(clockTime(event.start)) \(event.title)"
        if event.start <= now {
            label += " · ends \(countdown(to: event.end, now: now))"
        } else {
            label += " · in \(countdown(to: event.start, now: now))"
        }
        var entry = Row(label: label)
        entry.isEnabled = !event.isMuted
        if joinable, let link = event.link {
            entry.action = "join:\(link.absoluteString)"
        }
        return entry
    }

    private static func upcoming(_ events: [MeetingEvent], now: Date) -> [MeetingEvent] {
        events
            .filter { $0.start > now }
            .sorted { $0.start < $1.start }
    }

    private static func dayHeader(for date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "LATER TODAY" }
        if calendar.isDateInTomorrow(date) { return "TOMORROW" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date).uppercased()
    }

    private static func clockTime(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    /// The macOS bar countdown policy, ported verbatim: "now", seconds,
    /// minutes, hours, or days with a leading sign for the past.
    static func countdown(to date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        let seconds = Int(interval.rounded())
        let sign = seconds < 0 ? "-" : ""
        let magnitude = abs(seconds)
        if magnitude == 0 { return "now" }
        if magnitude < 60 { return "\(sign)\(magnitude)s" }
        if magnitude < 3_600 { return "\(sign)\(max(1, magnitude / 60))m" }
        if magnitude < 86_400 {
            let hours = magnitude / 3_600
            let minutes = (magnitude % 3_600) / 60
            return minutes > 0 ? "\(sign)\(hours)h \(minutes)m" : "\(sign)\(hours)h"
        }
        let days = magnitude / 86_400
        let hours = (magnitude % 86_400) / 3_600
        return hours > 0 ? "\(sign)\(days)d \(hours)h" : "\(sign)\(days)d"
    }
}
