import SwiftUI
import AppKit

enum Palette {
    static let nsColors: [NSColor] = [.systemBlue, .systemOrange, .systemPurple, .systemTeal, .systemPink, .systemGreen, .systemIndigo, .systemYellow, .systemRed, .systemMint]

    /// Positive modulo — safe for any Int (including `Int.min`, where
    /// `abs(index) % count` would trap).
    static func nsColor(_ index: Int) -> NSColor {
        let count = nsColors.count
        let normalized = ((index % count) + count) % count
        return nsColors[normalized]
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

    // MARK: Contrast-safe derivations

    enum ContrastTarget {
        case onBlack
        case onWhite
    }

    /// WCAG-style relative luminance of an sRGB color (pure — unit-testable).
    static func luminance(_ color: NSColor) -> CGFloat {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ channel: CGFloat) -> CGFloat {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// Linear interpolation toward another color (alpha forced to 1).
    static func blend(_ color: NSColor, toward other: NSColor, amount: CGFloat) -> NSColor {
        let a = color.usingColorSpace(.sRGB) ?? color
        let b = other.usingColorSpace(.sRGB) ?? other
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, al1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, al2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &al1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &al2)
        let t = min(1, max(0, amount))
        return NSColor(srgbRed: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1)
    }

    /// User-picked calendar colors can be near-black or near-white; text and
    /// prominent controls rendered in them must stay readable. Lightens toward
    /// white (on black backgrounds) or darkens toward black (on light ones)
    /// until clear of the luminance floor/ceiling. Pure — unit-testable.
    static func readable(_ color: NSColor, on target: ContrastTarget) -> NSColor {
        let floor: CGFloat = 0.18
        let ceiling: CGFloat = 0.82
        if target == .onBlack {
            guard luminance(color) < floor else { return color }
            var amount: CGFloat = 0.05
            while amount < 1 {
                let mixed = blend(color, toward: .white, amount: amount)
                if luminance(mixed) >= floor { return mixed }
                amount += 0.05
            }
            return .white
        }
        guard luminance(color) > ceiling else { return color }
        var amount: CGFloat = 0.05
        while amount < 1 {
            let mixed = blend(color, toward: .black, amount: amount)
            if luminance(mixed) <= ceiling { return mixed }
            amount += 0.05
        }
        return .black
    }

    /// Stable fullscreen Join-button fill. Unlike SwiftUI's native prominent
    /// button treatment, this color is not transformed when the panel becomes
    /// inactive. Keep it bright enough to separate from the black alert and
    /// dark enough for the button's explicit white label.
    static func alertButtonColor(_ color: NSColor) -> NSColor {
        let onBlack = readable(color, on: .onBlack)
        let maximumLuminance: CGFloat = 0.30 // white large text keeps >= 3:1 contrast
        guard luminance(onBlack) > maximumLuminance else { return onBlack }
        var amount: CGFloat = 0.05
        while amount < 1 {
            let mixed = blend(onBlack, toward: .black, amount: amount)
            if luminance(mixed) <= maximumLuminance { return mixed }
            amount += 0.05
        }
        return .black
    }

    static func dotImage(color: NSColor, size: CGFloat = 12) -> NSImage {
        dotClusterImage(colors: [color], size: size)
    }

    /// One compact, color-preserving image for the status bar. Separate text
    /// attachments plus negative kerning shift unpredictably across macOS font
    /// metrics, so simultaneous meetings are drawn into one bitmap instead.
    /// Adjacent circles overlap by 40%; a transparent cutout around each front
    /// circle keeps equal-colored calendars visibly distinct on any menu-bar
    /// material. More than three meetings remain a compact visual cluster; the
    /// exact count belongs in the accessibility text and dropdown.
    static func dotClusterImage(colors: [NSColor], size: CGFloat = 12) -> NSImage {
        let visibleColors = Array(colors.prefix(3))
        guard !visibleColors.isEmpty else { return NSImage(size: .zero) }
        let imageSize = dotClusterSize(colorCount: visibleColors.count, dotSize: size)
        let step = size * 0.60
        let image = NSImage(size: imageSize)
        image.lockFocus()
        for (index, color) in visibleColors.enumerated() {
            let x = CGFloat(index) * step
            if index > 0, let context = NSGraphicsContext.current {
                context.saveGraphicsState()
                context.compositingOperation = .destinationOut
                NSColor.black.setFill()
                let separator: CGFloat = max(0.5, size * 0.07)
                NSBezierPath(ovalIn: NSRect(
                    x: x - separator,
                    y: -separator,
                    width: size + separator * 2,
                    height: size + separator * 2
                )).fill()
                context.restoreGraphicsState()
            }
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 0, width: size, height: size)).fill()
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Pure geometry seam for CLI selftests; constructing/focusing an NSImage
    /// would register an AppKit process and is invalid in a headless run.
    static func dotClusterSize(colorCount: Int, dotSize: CGFloat) -> NSSize {
        guard colorCount > 0 else { return .zero }
        let visibleCount = min(3, colorCount)
        return NSSize(width: dotSize + CGFloat(visibleCount - 1) * dotSize * 0.60, height: dotSize)
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

    static func barCountdown(to date: Date, relativeTo now: Date = Date()) -> String {
        let s = Int(date.timeIntervalSince(now))
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
    /// Unbreakable tokens (URLs, ids) longer than `width` are chunked so a
    /// single token can't blow up the tooltip width.
    static func wrapped(_ text: String, width: Int, maxLines: Int) -> String {
        var words: [String] = []
        for word in text.components(separatedBy: .whitespacesAndNewlines) where !word.isEmpty {
            guard word.count > width else {
                words.append(word)
                continue
            }
            var index = word.startIndex
            while index < word.endIndex {
                let end = word.index(index, offsetBy: width, limitedBy: word.endIndex) ?? word.endIndex
                words.append(String(word[index..<end]))
                index = end
            }
        }
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
