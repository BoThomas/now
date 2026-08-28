import SwiftUI
import AppKit

enum Palette {
    static let nsColors: [NSColor] = [.systemBlue, .systemOrange, .systemPurple, .systemTeal, .systemPink, .systemGreen, .systemIndigo, .systemYellow, .systemRed, .systemMint]
    static func nsColor(_ index: Int) -> NSColor {
        nsColors[abs(index) % nsColors.count]
    }
    static func color(_ index: Int) -> Color {
        Color(nsColor: nsColor(index))
    }

    static func hex(for index: Int) -> String {
        hexString(from: nsColor(index))
    }

    static func hexString(from color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    static func nsColor(hex: String) -> NSColor {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nsColor(0) }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                       green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(rgb & 0xFF) / 255.0,
                       alpha: 1)
    }

    static func color(hex: String) -> Color {
        Color(nsColor: nsColor(hex: hex))
    }

    static func dotImage(color: NSColor, size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        image.unlockFocus()
        return image
    }
}

enum Fmt {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func mmss(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let m = Int(interval) / 60
        if m < 60 { return "\(m) min" }
        return String(format: "%dh %dm", m / 60, m % 60)
    }

    static func leadTime(_ seconds: Int) -> String {
        if seconds == 0 { return "Just in time" }
        let m = seconds / 60
        let s = seconds % 60
        if m == 0 { return "\(s)s" }
        if s == 0 { return "\(m) min" }
        return "\(m) min \(s)s"
    }

    static func barCountdown(to date: Date) -> String {
        let s = Int(date.timeIntervalSince(Date()))
        let sign = s < 0 ? "-" : ""
        let t = abs(s)
        if t == 0 { return "now" }
        if t < 60 { return "\(sign)\(t)s" }
        if t < 3600 { return "\(sign)\(max(1, t / 60))m" }
        if t < 86400 {
            let h = t / 3600
            let m = (t % 3600) / 60
            return m > 0 ? "\(sign)\(h)h \(m)m" : "\(sign)\(h)h"
        }
        let d = t / 86400
        let h = (t % 86400) / 3600
        return h > 0 ? "\(sign)\(d)d \(h)h" : "\(sign)\(d)d"
    }

    static func ago(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Uppercase day-section header ("TODAY", "TOMORROW", "FRI, AUG 28") shared by
    /// the menu bar dropdown and the settings event lists.
    static func dayHeader(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today".localizedUppercase }
        if calendar.isDateInTomorrow(day) { return "Tomorrow".localizedUppercase }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).localizedUppercase
    }

    /// Truncates to `limit` grapheme clusters and appends an ellipsis, like SwiftUI's
    /// `.lineLimit(1)` + `.truncationMode(.tail)` does in the settings event rows.
    static func ellipsized(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Collapses whitespace/newlines, word-wraps to `width` chars per line and cuts after
    /// `maxLines` lines with a trailing ellipsis — for multi-line tooltips.
    static func wrapped(_ text: String, width: Int, maxLines: Int) -> String {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + word.count + 1 <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        guard lines.count <= maxLines else {
            return lines.prefix(maxLines).joined(separator: "\n") + " …"
        }
        return lines.joined(separator: "\n")
    }
}
