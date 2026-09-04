import SwiftUI
import AppKit

enum Links {
    static let repo = URL(string: "https://github.com/BoThomas/now")!
    static let releases = URL(string: "https://github.com/BoThomas/now/releases/latest")!
    static let website = URL(string: "https://thomasboch.com")!
}

/// The settings sections, in display order — shared by the section headers and
/// the sidebar navigation.
enum SettingsSection: String, CaseIterable, Identifiable {
    case calendars, native, reminder, general, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendars: return "External Calendars"
        case .native: return "Apple Calendars"
        case .reminder: return "Reminder"
        case .general: return "General"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .calendars: return "calendar"
        case .native: return "calendar.badge.clock"
        case .reminder: return "bell.badge"
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

/// Reveals the ⌘-number shortcut hints after the user holds ⌘ for a moment
/// (the macOS toolbar convention) — brief ⌘ taps (⌘C, ⌘Q…) stay invisible.
/// Main-thread only, like the rest of the settings UI.
final class CommandHoldTracker: ObservableObject {
    @Published private(set) var showHints = false
    private var monitor: Any?
    private var holding = false
    private var revealWorkItem: DispatchWorkItem?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.setCommandHeld(event.modifierFlags.contains(.command))
            return event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        revealWorkItem?.cancel()
        revealWorkItem = nil
        holding = false
        showHints = false
    }

    private func setCommandHeld(_ held: Bool) {
        if held {
            guard !holding else { return }
            holding = true
            revealWorkItem?.cancel()
            let reveal = DispatchWorkItem { [weak self] in
                guard let self, self.holding else { return }
                withAnimation(.easeOut(duration: 0.15)) { self.showHints = true }
            }
            revealWorkItem = reveal
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: reveal)
        } else {
            holding = false
            revealWorkItem?.cancel()
            if showHints { withAnimation(.easeOut(duration: 0.12)) { showHints = false } }
        }
    }
}

struct CursorModifier: ViewModifier {
    let cursor: NSCursor

    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside {
                cursor.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        modifier(CursorModifier(cursor: cursor))
    }
}

struct GitHubMark: Shape {
    private static let pathData = "M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8z"

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        var path = Path()
        var cursor = CGPoint.zero
        var subpathStart = CGPoint.zero
        func scaled(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale)
        }
        for (cmd, numbers) in Self.parse(Self.pathData) {
            let upper = Character(cmd.uppercased())
            let relative = cmd.isLowercase
            var index = 0
            func nextRaw() -> CGPoint {
                let value = CGPoint(x: numbers[index], y: numbers[index + 1])
                index += 2
                return value
            }
            func nextPoint() -> CGPoint {
                let value = nextRaw()
                return relative ? CGPoint(x: cursor.x + value.x, y: cursor.y + value.y) : value
            }
            switch upper {
            case "M":
                while index + 1 < numbers.count {
                    cursor = nextPoint()
                    if index == 2 {
                        path.move(to: scaled(cursor))
                        subpathStart = cursor
                    } else {
                        path.addLine(to: scaled(cursor))
                    }
                }
            case "L":
                while index + 1 < numbers.count {
                    cursor = nextPoint()
                    path.addLine(to: scaled(cursor))
                }
            case "C":
                while index + 5 < numbers.count {
                    let origin = cursor
                    let r1 = nextRaw()
                    let r2 = nextRaw()
                    let r3 = nextRaw()
                    let c1 = relative ? CGPoint(x: origin.x + r1.x, y: origin.y + r1.y) : r1
                    let c2 = relative ? CGPoint(x: origin.x + r2.x, y: origin.y + r2.y) : r2
                    let to = relative ? CGPoint(x: origin.x + r3.x, y: origin.y + r3.y) : r3
                    path.addCurve(to: scaled(to), control1: scaled(c1), control2: scaled(c2))
                    cursor = to
                }
            case "A":
                while index + 6 < numbers.count {
                    let rx = numbers[index]
                    let ry = numbers[index + 1]
                    let rotation = numbers[index + 2]
                    let largeArc = numbers[index + 3] != 0
                    let sweep = numbers[index + 4] != 0
                    let raw = CGPoint(x: numbers[index + 5], y: numbers[index + 6])
                    index += 7
                    let to = relative ? CGPoint(x: cursor.x + raw.x, y: cursor.y + raw.y) : raw
                    for curve in Self.arcToCubics(from: cursor, to: to, rx: rx, ry: ry, rotationDegrees: rotation, largeArc: largeArc, sweep: sweep) {
                        path.addCurve(to: scaled(curve.to), control1: scaled(curve.c1), control2: scaled(curve.c2))
                    }
                    cursor = to
                }
            case "Z":
                path.closeSubpath()
                cursor = subpathStart
            default:
                break
            }
        }
        return path
    }

    private static func parse(_ data: String) -> [(Character, [CGFloat])] {
        var commands: [(Character, [CGFloat])] = []
        var current: Character?
        var numbers: [CGFloat] = []
        var token = ""
        func flushToken() {
            guard !token.isEmpty else { return }
            numbers.append(CGFloat(Double(token) ?? 0))
            token = ""
        }
        for ch in data {
            if ch.isLetter {
                flushToken()
                if let command = current { commands.append((command, numbers)) }
                numbers = []
                current = ch
            } else if ch.isNumber || ch == "." || ch == "-" {
                if ch == "-" && !token.isEmpty {
                    flushToken()
                    token = "-"
                } else if ch == "." && token.contains(".") {
                    flushToken()
                    token = "."
                } else {
                    token.append(ch)
                }
            } else {
                flushToken()
            }
        }
        flushToken()
        if let command = current { commands.append((command, numbers)) }
        return commands
    }

    private static func arcToCubics(from: CGPoint, to: CGPoint, rx: CGFloat, ry: CGFloat, rotationDegrees: CGFloat, largeArc: Bool, sweep: Bool) -> [(c1: CGPoint, c2: CGPoint, to: CGPoint)] {
        var radiusX = abs(rx)
        var radiusY = abs(ry)
        guard radiusX > 0.01, radiusY > 0.01, from != to else { return [] }
        let rotation = rotationDegrees * .pi / 180
        let cosPhi = cos(rotation)
        let sinPhi = sin(rotation)
        let dx = (from.x - to.x) / 2
        let dy = (from.y - to.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (radiusX * radiusX) + (y1p * y1p) / (radiusY * radiusY)
        if lambda > 1 {
            let factor = sqrt(lambda)
            radiusX *= factor
            radiusY *= factor
        }
        let sign: CGFloat = largeArc != sweep ? 1 : -1
        let numerator = radiusX * radiusX * radiusY * radiusY - radiusX * radiusX * y1p * y1p - radiusY * radiusY * x1p * x1p
        let denominator = radiusX * radiusX * y1p * y1p + radiusY * radiusY * x1p * x1p
        let coefficient = denominator == 0 ? 0 : sign * sqrt(max(0, numerator / denominator))
        let cxp = coefficient * radiusX * y1p / radiusY
        let cyp = -coefficient * radiusY * x1p / radiusX
        let cx = cosPhi * cxp - sinPhi * cyp + (from.x + to.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (from.y + to.y) / 2

        func angle(ux: CGFloat, uy: CGFloat, vx: CGFloat, vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let length = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var value = acos(min(1, max(-1, dot / max(length, 0.000001))))
            if ux * vy - uy * vx < 0 { value = -value }
            return value
        }

        let startAngle = angle(ux: 1, uy: 0, vx: (x1p - cxp) / radiusX, vy: (y1p - cyp) / radiusY)
        var delta = angle(ux: (x1p - cxp) / radiusX, uy: (y1p - cyp) / radiusY, vx: (-x1p - cxp) / radiusX, vy: (-y1p - cyp) / radiusY)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        func point(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + radiusX * cosPhi * cos(t) - radiusY * sinPhi * sin(t),
                    y: cy + radiusX * sinPhi * cos(t) + radiusY * cosPhi * sin(t))
        }
        func derivative(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -radiusX * cosPhi * sin(t) - radiusY * sinPhi * cos(t),
                    y: -radiusX * sinPhi * sin(t) + radiusY * cosPhi * cos(t))
        }
        var theta = startAngle
        var current = point(theta)
        var curves: [(c1: CGPoint, c2: CGPoint, to: CGPoint)] = []
        for _ in 0..<segments {
            let next = theta + step
            let endPoint = point(next)
            let d1 = derivative(theta)
            let d2 = derivative(next)
            curves.append((
                c1: CGPoint(x: current.x + k * d1.x, y: current.y + k * d1.y),
                c2: CGPoint(x: endPoint.x - k * d2.x, y: endPoint.y - k * d2.y),
                to: endPoint
            ))
            theta = next
            current = endPoint
        }
        return curves
    }
}

struct PresetButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(active ? Color.accentColor : Color.primary.opacity(0.08)))
            .foregroundStyle(active ? Color.white : Color.primary)
    }
}

/// Left-aligned wrap layout (text-flow style): children keep their ideal size
/// and wrap as WHOLE items to the next line when the width runs out. Used for
/// the lead-time presets — equal-width grid slots made pills stretch or break.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                width = max(width, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        width = max(width, x - spacing)
        return CGSize(width: max(0, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Events grouped under one uppercase day header (same `Fmt.dayHeader` style as the
/// menu bar dropdown), so each row is a single line: time + title.
struct UpcomingEventList: View {
    /// All visible events for the calendar; collapsed to `collapsedLimit` rows
    /// until "+ N more" is used.
    let events: [MeetingEvent]
    let error: String?
    let colorHex: String
    /// This calendar's title-filter rules — drive the per-row mute toggle
    /// (its state is derived: "does any rule match this title?").
    let rules: [TitleFilterRule]
    let onMute: (MeetingEvent) -> Void
    let onRemoveRules: (Set<UUID>) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private static let collapsedLimit = 8
    @State private var availableWidth: CGFloat = 600

    /// Local expand state — the list is unmounted when the calendar row collapses,
    /// so this resets by itself; the parent never tracks it.
    @State private var showAll = false

    private var shown: [MeetingEvent] {
        showAll ? events : Array(events.prefix(Self.collapsedLimit))
    }

    private var overflowCount: Int {
        max(0, events.count - Self.collapsedLimit)
    }

    /// Switch the whole list together. Per-row ViewThatFits made mixed rows
    /// look accidental when only one long host wrapped beneath its title.
    private var compactLinks: Bool {
        let longestHostWidth = shown.compactMap(\.link).map { link in
            (hostText(link) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
        }.max() ?? 0
        // time + spacing + minimum useful title + spacer + icon/label padding
        return longestHostWidth > 0 && availableWidth < 60 + 8 + 80 + 4 + longestHostWidth + 26
    }

    private struct DayGroup: Identifiable {
        let day: Date
        var events: [MeetingEvent]
        var id: Date { day }
    }

    private func dayGroups(from events: [MeetingEvent]) -> [DayGroup] {
        var groups: [DayGroup] = []
        for event in events {
            let day = Calendar.current.startOfDay(for: event.start)
            if !groups.isEmpty, groups[groups.count - 1].day == day {
                groups[groups.count - 1].events.append(event)
            } else {
                groups.append(DayGroup(day: day, events: [event]))
            }
        }
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if events.isEmpty {
                Text(error != nil ? "No events — fix the sync error above" : "No upcoming events in the next two weeks")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(dayGroups(from: shown)) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Fmt.dayHeader(for: group.day))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(group.events) { event in
                            if compactLinks {
                                VStack(alignment: .leading, spacing: 4) {
                                    eventSummary(event)
                                    HStack(alignment: .top, spacing: 6) {
                                        trailingDetail(event, compact: true)
                                        Spacer(minLength: 4)
                                        MuteToggleButton(event: event, rules: rules, onMute: onMute, onRemoveRules: onRemoveRules)
                                    }
                                    .padding(.leading, 68)
                                }
                            } else {
                                HStack(alignment: .top, spacing: 8) {
                                    eventSummary(event)
                                    Spacer(minLength: 4)
                                    trailingDetail(event, compact: false)
                                    MuteToggleButton(event: event, rules: rules, onMute: onMute, onRemoveRules: onRemoveRules)
                                }
                            }
                        }
                    }
                }
                if overflowCount > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showAll.toggle() }
                    } label: {
                        Text(showAll ? "Show less" : "+ \(overflowCount) more")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.link)
                    .cursor(.pointingHand)
                }
            }
        }
        .padding(.top, 2)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: UpcomingEventListWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(UpcomingEventListWidthKey.self) { availableWidth = $0 }
    }

    /// Join link / no-link label on the trailing edge; dimmed (but still
    /// clickable) when the event is muted — muting silences reminders, not joining.
    @ViewBuilder
    private func trailingDetail(_ event: MeetingEvent, compact: Bool) -> some View {
        if let link = event.link {
            joinButton(link, compact: compact)
                .opacity(event.isMuted ? 0.55 : 1)
        } else {
            noLinkLabel
                .opacity(event.isMuted ? 0.55 : 1)
        }
    }

    private func hostText(_ link: URL) -> String {
        (link.host ?? "").replacingOccurrences(of: "www.", with: "")
    }

    private func eventSummary(_ event: MeetingEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Fmt.time.string(from: event.start))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(width: 60, alignment: .leading)
            Text(event.title.isEmpty ? "Untitled" : event.title)
                .font(.system(size: 11))
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 80, alignment: .leading)
        }
        .opacity(event.isMuted ? 0.45 : 1)
    }

    private func joinButton(_ link: URL, compact: Bool) -> some View {
        Button {
            NSWorkspace.shared.open(link)
        } label: {
            Label(hostText(link), systemImage: "video.fill")
                .font(.system(size: 10))
                .foregroundStyle(linkColor)
                .lineLimit(compact ? 2 : 1)
                .fixedSize(horizontal: !compact, vertical: compact)
        }
        .buttonStyle(.link)
        .cursor(.pointingHand)
        .help("Open \(link.absoluteString)")
    }

    private var noLinkLabel: some View {
        Text("No link")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .help("No meeting link found")
    }

    /// Contrast-safe tint for link text: user-picked near-background colors
    /// (near-black in dark mode, near-white in light mode) get nudged readable.
    private var linkColor: Color {
        let target: Palette.ContrastTarget = colorScheme == .dark ? .onBlack : .onWhite
        return Color(nsColor: Palette.readable(Palette.nsColor(hex: colorHex), on: target))
    }
}

/// Per-event mute toggle. Its state is DERIVED — "does any rule of this
/// calendar match this event's title?" via the same pure matcher the reminder
/// pipeline uses — so hand-added, hand-edited, or hand-removed rules keep it in
/// sync with zero bookkeeping. Unmuted + click adds an exact-title rule
/// immediately; muted + click opens the confirmation popover (selective removal).
private struct MuteToggleButton: View {
    let event: MeetingEvent
    let rules: [TitleFilterRule]
    let onMute: (MeetingEvent) -> Void
    let onRemoveRules: (Set<UUID>) -> Void
    @State private var showUnmutePopover = false
    @State private var popoverGeneration = 0

    private var hasTitle: Bool {
        !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var matching: [TitleFilterRule] {
        TitleFilterRule.matchingRules(title: event.title, rules: rules)
    }

    private var atRuleCap: Bool {
        rules.count >= TitleFilterRule.maxRulesPerCalendar
    }

    private var helpText: String {
        if !hasTitle { return "This meeting has no title to match" }
        if !event.isMuted && atRuleCap { return "Rule limit reached (\(TitleFilterRule.maxRulesPerCalendar)) — remove a rule first" }
        if event.isMuted {
            return matching.count == 1
                ? "Muted by 1 rule — click to unmute"
                : "Muted by \(matching.count) rules — click to unmute"
        }
        return "Mute reminders for “\(Fmt.ellipsized(event.title, limit: 60))” — matches every event with this title in this calendar"
    }

    var body: some View {
        Button {
            if event.isMuted {
                popoverGeneration += 1
                showUnmutePopover = true
            } else {
                onMute(event)
            }
        } label: {
            // Muted: crossed bell (filled, accent). Not muted: outline bell.
            // offset(y: -1): bell glyphs carry their mass low — a small optical
            // lift keeps the icon centered against the 11pt row text.
            Image(systemName: event.isMuted ? "bell.slash.fill" : "bell.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(event.isMuted ? Color.accentColor : Color.secondary)
                .frame(width: 14, height: 14)
                .offset(y: -1)
        }
        .buttonStyle(.borderless)
        .cursor(.pointingHand)
        .disabled(!hasTitle || (!event.isMuted && atRuleCap))
        .help(helpText)
        .accessibilityLabel(event.isMuted ? "Unmute \(event.title.isEmpty ? "Untitled" : event.title) (muted)" : "Mute reminders for \(event.title.isEmpty ? "Untitled" : event.title)")
        .popover(isPresented: $showUnmutePopover, arrowEdge: .bottom) {
            UnmuteRulePopover(
                title: event.title,
                rules: matching,
                onCancel: { showUnmutePopover = false },
                onRemove: { ids in
                    onRemoveRules(ids)
                    showUnmutePopover = false
                }
            )
                .id(popoverGeneration)
        }
    }
}

private struct UnmuteRulePopover: View {
    let title: String
    let rules: [TitleFilterRule]
    let onCancel: () -> Void
    let onRemove: (Set<UUID>) -> Void
    @State private var selectedRuleIDs: Set<UUID>

    init(title: String, rules: [TitleFilterRule], onCancel: @escaping () -> Void, onRemove: @escaping (Set<UUID>) -> Void) {
        self.title = title
        self.rules = rules
        self.onCancel = onCancel
        self.onRemove = onRemove
        _selectedRuleIDs = State(initialValue: Set(rules.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Unmute “\(Fmt.ellipsized(title, limit: 60))”")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rules) { rule in
                        HStack(spacing: 8) {
                            Button {
                                if selectedRuleIDs.contains(rule.id) {
                                    selectedRuleIDs.remove(rule.id)
                                } else {
                                    selectedRuleIDs.insert(rule.id)
                                }
                            } label: {
                                Image(systemName: selectedRuleIDs.contains(rule.id) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13))
                                    .foregroundStyle(selectedRuleIDs.contains(rule.id) ? Color.accentColor : Color.secondary)
                                    .id(selectedRuleIDs.contains(rule.id))
                            }
                            .buttonStyle(.plain)
                            .cursor(.pointingHand)
                            .accessibilityLabel((selectedRuleIDs.contains(rule.id) ? "Deselect rule " : "Select rule ") + Fmt.ellipsized(rule.pattern, limit: 40))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Fmt.ellipsized(rule.pattern, limit: 48))
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(rule.mode == .regex ? "Regex" : "Full title")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            .frame(height: min(CGFloat(rules.count) * 36, 240))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Remove") {
                    onRemove(selectedRuleIDs)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRuleIDs.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

private struct UpcomingEventListWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 600
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct SubscriptionRow: View {
    @Binding var subscription: CalendarSubscription
    let events: [MeetingEvent]
    let error: String?
    let warning: String?
    let existingURLs: [String]
    let onMute: (MeetingEvent) -> Void
    let onRemoveRules: (Set<UUID>) -> Void
    let onSaveRules: ([TitleFilterRule]) -> Void
    let onDelete: () -> Void
    let onEdited: () -> Void
    @State private var expanded = false
    @State private var showEditSheet = false
    @State private var showFilterSheet = false
    @State private var filterSheetGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One line when it fits; below ~560 pt the action buttons wrap to a
            // second row instead of crushing the title/URL block.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    leadingControls
                    titleBlock
                    expandSpace
                    rowButtons
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        leadingControls
                        titleBlock
                        expandSpace
                    }
                    HStack(spacing: 12) {
                        Spacer()
                        rowButtons
                    }
                }
            }
            if expanded && subscription.isEnabled {
                UpcomingEventList(
                    events: events,
                    error: error,
                    colorHex: subscription.colorHex,
                    rules: subscription.titleFilters,
                    onMute: onMute,
                    onRemoveRules: onRemoveRules
                )
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .onChange(of: subscription.isEnabled) { enabled in
            if !enabled { expanded = false }
        }
        .sheet(isPresented: $showEditSheet) {
            EditCalendarView(subscription: $subscription, existingURLs: existingURLs) {
                onEdited()
            }
        }
    }

    private var leadingControls: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $subscription.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(subscription.isEnabled ? "Disable calendar (stops sync and reminders)" : "Enable calendar")
                .accessibilityLabel("\(subscription.isEnabled ? "Disable" : "Enable") calendar \(subscription.name)")
            ColorPicker("", selection: Binding(
                get: { Palette.color(hex: subscription.colorHex) },
                set: { subscription.colorHex = Palette.hexString(from: NSColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .scaleEffect(x: 0.75, y: 0.75)
            .frame(width: 24, height: 20)
            .padding(.leading, 2)
            .accessibilityLabel("Event color for \(subscription.name)")
        }
    }

    /// Clickable dead space between the title block and the action buttons —
    /// the same expand/collapse as the chevron, deliberately WITHOUT any visual
    /// affordance of its own (no hover highlight, cursor stays default).
    private var expandSpace: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(Rectangle())
            .onTapGesture {
                guard subscription.isEnabled else { return }
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(subscription.name).font(.system(size: 13, weight: .semibold))
            Text(Self.displayURL(subscription.url)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help("Full URL is visible in the edit sheet")
            if let error = error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
            } else if let warning = warning {
                Text(warning).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .opacity(subscription.isEnabled ? 1 : 0.5)
    }

    private var rowButtons: some View {
        HStack(spacing: 12) {
            filterButton
            Button {
                showEditSheet = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit name or URL")
            .accessibilityLabel("Edit calendar \(subscription.name)")
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove calendar")
            .accessibilityLabel("Remove calendar \(subscription.name)")
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(-6)
            .disabled(!subscription.isEnabled)
            .help(subscription.isEnabled ? "Show upcoming events" : "Calendar disabled")
            .accessibilityLabel(expanded ? "Hide events for \(subscription.name)" : "Show events for \(subscription.name)")
        }
    }

    /// Muted-meetings rule editor entry. The live count is an overlay badge (not
    /// flow text) so the icon's layout box stays identical to the neighboring
    /// edit/trash icons — mixed image+text labels sit visibly higher otherwise.
    private var filterButton: some View {
        Button {
            filterSheetGeneration += 1
            showFilterSheet = true
        } label: {
            // offset(y: 2): optical nudge so the circle glyph centers on the
            // neighboring edit/trash icons (renders high otherwise). The badge
            // is an overlay — decoration only, never part of the layout box.
            Image(systemName: "line.3.horizontal.decrease.circle")
                .overlay(alignment: .bottomTrailing) {
                    if !subscription.titleFilters.isEmpty {
                        Text("\(subscription.titleFilters.count)")
                            .font(.system(size: 8, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 11, minHeight: 11)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 5, y: 4)
                            .allowsHitTesting(false)
                    }
                }
                .offset(y: 2)
        }
        .buttonStyle(.borderless)
        .help(subscription.titleFilters.isEmpty ? "Muted meetings — none yet" : "Muted meetings (\(subscription.titleFilters.count) rules)")
        .accessibilityLabel("Muted meetings rules for \(subscription.name)")
        .sheet(isPresented: $showFilterSheet) {
            TitleFilterEditorSheet(
                calendarName: subscription.name,
                rules: subscription.titleFilters,
                events: events
            ) { rules in
                onSaveRules(rules)
            }
            .id(filterSheetGeneration)
        }
    }

    /// Sanitized feed URL for display outside the editor: shared iCal links
    /// embed secret tokens in path/query, so rows show only the host. The full
    /// URL remains visible (and editable) inside the edit sheet.
    static func displayURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else { return urlString }
        let path = url.path
        return path.isEmpty || path == "/" ? host : "\(host)/…"
    }
}

/// One calendar from EventKit: toggle = use it, color = tint for its events
/// (seeded from the calendar's own color on first enable), funnel = muted-meeting
/// rules, chevron = upcoming events.
struct NativeCalendarRow: View {
    let info: NativeCalendarInfo
    let isOn: Bool
    let colorHex: String
    let events: [MeetingEvent]
    /// Rules of the persisted record (empty when the calendar was never enabled —
    /// then there is no record and no rule storage yet).
    let rules: [TitleFilterRule]
    let calendarID: UUID?
    let onToggle: (Bool) -> Void
    let onColor: (String) -> Void
    let onMute: (MeetingEvent) -> Void
    let onRemoveRules: (Set<UUID>) -> Void
    let onSaveRules: ([TitleFilterRule]) -> Void
    @State private var expanded = false
    @State private var showFilterSheet = false
    @State private var filterSheetGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Wrap the chevron to a second row in narrow windows.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    leadingControls
                    titleBlock
                    expandSpace
                    actionButtons
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        leadingControls
                        titleBlock
                        expandSpace
                    }
                    HStack {
                        Spacer()
                        actionButtons
                    }
                }
            }
            if expanded && isOn {
                UpcomingEventList(
                    events: events,
                    error: nil,
                    colorHex: colorHex,
                    rules: rules,
                    onMute: onMute,
                    onRemoveRules: onRemoveRules
                )
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .onChange(of: isOn) { enabled in
            if !enabled { expanded = false }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            filterButton
            expandButton
        }
    }

    /// Muted-meetings rule editor. Needs a persisted record (our stable UUID) —
    /// a never-enabled calendar has none, so the button waits for first enable.
    /// Disabled-but-previously-enabled calendars keep editing their rules.
    /// The count is an overlay badge so the icon aligns with the chevron.
    private var filterButton: some View {
        Button {
            filterSheetGeneration += 1
            showFilterSheet = true
        } label: {
            // offset(y: 2): optical nudge so the circle glyph centers on the
            // neighboring chevron (renders high otherwise). The badge is an
            // overlay — decoration only, never part of the layout box.
            Image(systemName: "line.3.horizontal.decrease.circle")
                .overlay(alignment: .bottomTrailing) {
                    if !rules.isEmpty {
                        Text("\(rules.count)")
                            .font(.system(size: 8, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 11, minHeight: 11)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 5, y: 4)
                            .allowsHitTesting(false)
                    }
                }
                .offset(y: 2)
        }
        .buttonStyle(.borderless)
        .disabled(calendarID == nil)
        .help(calendarID == nil ? "Enable the calendar first" : (rules.isEmpty ? "Muted meetings — none yet" : "Muted meetings (\(rules.count) rules)"))
        .accessibilityLabel("Muted meetings rules for \(info.title)")
        .sheet(isPresented: $showFilterSheet) {
            if calendarID != nil {
                TitleFilterEditorSheet(
                    calendarName: info.title,
                    rules: rules,
                    events: events
                ) { rules in
                    onSaveRules(rules)
                }
                .id(filterSheetGeneration)
            }
        }
    }

    /// Clickable dead space between the title block and the action buttons —
    /// the same expand/collapse as the chevron, deliberately WITHOUT any visual
    /// affordance of its own (no hover highlight, cursor stays default).
    private var expandSpace: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isOn else { return }
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }
    }

    private var leadingControls: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isOn }, set: { onToggle($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(isOn ? "Stop reminders for this calendar" : "Show reminders for this calendar")
                .accessibilityLabel("\(isOn ? "Stop reminders for" : "Show reminders for") \(info.title)")
            ColorPicker("", selection: Binding(
                get: { Palette.color(hex: colorHex) },
                set: { onColor(Palette.hexString(from: NSColor($0))) }
            ), supportsOpacity: false)
            .labelsHidden()
            .scaleEffect(x: 0.75, y: 0.75)
            .frame(width: 24, height: 20)
            .padding(.leading, 2)
            .disabled(!isOn)
            .help(isOn ? "Tint for this calendar's events" : "Enable the calendar to pick a color")
            .accessibilityLabel("Event color for \(info.title)")
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(info.title).font(.system(size: 13, weight: .semibold))
            Text(info.sourceTitle.isEmpty ? "Apple Calendars" : "via \(info.sourceTitle)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .opacity(isOn ? 1 : 0.5)
    }

    private var expandButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(-6)
        .disabled(!isOn)
        .help(isOn ? "Show upcoming events" : "Calendar disabled")
        .accessibilityLabel(expanded ? "Hide events for \(info.title)" : "Show events for \(info.title)")
    }
}

/// Transactional rule editor (sheet, same pattern as `EditCalendarView`): edits
/// a LOCAL draft; Save commits the whole list atomically, Cancel/Esc discards
/// it. Keystrokes never touch persisted rules — no didSet churn, no transient
/// unmute flashes while typing a regex. Empty rows drop at Save; invalid regex
/// or over-length patterns BLOCK Save (visible validation, never silent).
struct TitleFilterEditorSheet: View {
    let calendarName: String
    /// This calendar's upcoming events — powers the "mutes N of M" feedback line.
    let events: [MeetingEvent]
    let onSave: ([TitleFilterRule]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: [TitleFilterRule]

    init(calendarName: String, rules: [TitleFilterRule], events: [MeetingEvent], onSave: @escaping ([TitleFilterRule]) -> Void) {
        self.calendarName = calendarName
        self.events = events
        self.onSave = onSave
        _draft = State(initialValue: rules)
    }

    /// Rows that carry content but are invalid — they block Save. Empty rows are
    /// NOT errors: they are "not a rule yet" and drop out at Save.
    private var rowErrors: [UUID: String] {
        var errors: [UUID: String] = [:]
        for rule in draft {
            let trimmed = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if rule.mode == .regex {
                if trimmed.count > TitleFilterRule.maxRegexPatternLength {
                    errors[rule.id] = "Pattern too long (max \(TitleFilterRule.maxRegexPatternLength) characters)"
                } else if (try? NSRegularExpression(pattern: trimmed)) == nil {
                    errors[rule.id] = "Invalid regular expression"
                }
            }
        }
        return errors
    }

    /// What Save would commit: the draft minus empty rows (the store runs the
    /// shared normalization — trim, dedupe, cap — on top).
    private var effectiveRules: [TitleFilterRule] {
        draft.filter { !$0.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Counted with ONE matcher over all rules so events matched by several
    /// rules are counted once (per-rule sums double-counted).
    private var feedbackText: String? {
        guard !events.isEmpty else { return nil }
        let matcher = TitleFilterMatcher(rules: TitleFilterRule.normalized(effectiveRules))
        let count = events.filter { matcher.matches(title: $0.title) }.count
        if count == 0 { return "Your current filters don't mute any of the \(events.count) upcoming meetings." }
        return "Your current filters mute \(count) of \(events.count) upcoming meetings."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Muted Meetings: \(calendarName)")
                .font(.title2.bold())
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Meetings whose title matches get no reminder. They stay in your lists, grayed out.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let feedback = feedbackText {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if draft.isEmpty {
                        emptyState
                    } else if draft.count <= 6 {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach($draft) { $rule in
                                ruleRow($rule)
                            }
                        }
                        .padding(.vertical, 3)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach($draft) { $rule in
                                    ruleRow($rule)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .frame(height: 360)
                    }
                }
                Button {
                    draft.append(TitleFilterRule(pattern: "", mode: .exact))
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .disabled(draft.count >= TitleFilterRule.maxRulesPerCalendar)
                .help(draft.count >= TitleFilterRule.maxRulesPerCalendar ? "Rule limit reached (\(TitleFilterRule.maxRulesPerCalendar))" : "Add a title rule")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(effectiveRules)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!rowErrors.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.slash").font(.title3).foregroundStyle(.secondary)
            Text("No muted meetings")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func ruleRow(_ rule: Binding<TitleFilterRule>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                TextField(rule.wrappedValue.mode == .regex ? "e.g. (?i)^Standup .*$" : "Full meeting title", text: rule.pattern)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: rule.mode) {
                    Text("Title").tag(TitleFilterRule.MatchMode.exact)
                    Text("Regex").tag(TitleFilterRule.MatchMode.regex)
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
                .labelsHidden()
                .accessibilityLabel("Match mode for \(Fmt.ellipsized(rule.wrappedValue.pattern, limit: 24))")
                Button {
                    draft.removeAll { $0.id == rule.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove rule")
                .accessibilityLabel("Remove rule \(Fmt.ellipsized(rule.wrappedValue.pattern, limit: 24))")
            }
            if let error = rowErrors[rule.wrappedValue.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// URL intake shared by Add/Edit: webcal→https, validation, normalization for
/// duplicate detection (scheme/host lowercased, trailing slash dropped; path
/// and query stay verbatim — they carry the secret token).
enum CalendarURL {
    static func normalize(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("webcal://") {
            trimmed = "https://" + String(trimmed.dropFirst("webcal://".count))
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let renderedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        var normalized = "\(scheme)://\(renderedHost)"
        if let port = components.port { normalized += ":\(port)" }
        normalized += path
        if let query = components.percentEncodedQuery {
            normalized += "?" + query
        }
        return normalized
    }

    /// Explicit consent before sending a private calendar token over plaintext.
    static func confirmInsecureHTTP(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "http" else { return true }
        let alert = NSAlert()
        alert.messageText = "Use an unencrypted HTTP link?"
        alert.informativeText = "Calendar links usually contain a private token. HTTP sends it in plain text — anyone on your network could read your calendar. HTTPS is strongly recommended."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Use HTTP Anyway")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct EditCalendarView: View {
    @Binding var subscription: CalendarSubscription
    let existingURLs: [String]
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var urlString: String
    @State private var errorText: String?
    @State private var didChangeURL = false

    init(subscription: Binding<CalendarSubscription>, existingURLs: [String], onSave: @escaping () -> Void) {
        _subscription = subscription
        self.existingURLs = existingURLs
        self.onSave = onSave
        _name = State(initialValue: subscription.wrappedValue.name)
        _urlString = State(initialValue: subscription.wrappedValue.url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Calendar")
                .font(.title2.bold())
            TextField("Name (e.g. Work)", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("iCal URL (https://…/basic.ics)", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .onChange(of: urlString) { _ in
                    didChangeURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines) != subscription.url
                }
            if let errorText = errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { submit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func submit() {
        guard let normalized = CalendarURL.normalize(urlString) else {
            errorText = "That doesn't look like a valid calendar URL."
            return
        }
        if didChangeURL,
           let own = CalendarURL.normalize(subscription.url), own != normalized,
           existingURLs.compactMap(CalendarURL.normalize).contains(normalized) {
            errorText = "That calendar link is already added."
            return
        }
        guard CalendarURL.confirmInsecureHTTP(normalized) else { return }
        subscription.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? subscription.name : name.trimmingCharacters(in: .whitespaces)
        if normalized != subscription.url {
            subscription.url = normalized
        }
        dismiss()
        onSave()
    }
}

struct AddCalendarView: View {
    var existingURLs: [String]
    var onAdd: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlString = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Calendar")
                .font(.title2.bold())
            TextField("Name (e.g. Work)", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("iCal URL (https://…/basic.ics)", text: $urlString)
                .textFieldStyle(.roundedBorder)
            if let errorText = errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            DisclosureGroup("Where do I find my iCal link?") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("• Google Calendar → Settings → Integrate calendar → \"Secret address in iCal format\"")
                    Text("• Outlook / Microsoft 365 → Calendar → Share & export → Publish to web (ICS)")
                    Text("• iCloud → Calendar app → share a calendar publicly → copy the webcal link (webcal:// works too)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add & Sync") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func submit() {
        guard let normalized = CalendarURL.normalize(urlString) else {
            errorText = "That doesn't look like a valid calendar URL."
            return
        }
        if existingURLs.compactMap(CalendarURL.normalize).contains(normalized) {
            errorText = "That calendar link is already added."
            return
        }
        guard CalendarURL.confirmInsecureHTTP(normalized) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        onAdd(trimmedName.isEmpty ? "Calendar" : trimmedName, normalized)
        dismiss()
    }
}

/// Small capsule badge that opens a URL — friendlier than a bare blue link.
struct BadgeLink<Content: View>: View {
    let url: URL
    let label: Content
    @State private var hovering = false

    init(url: URL, @ViewBuilder label: () -> Content) {
        self.url = url
        self.label = label()
    }

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            label
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.14 : 0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { hovering = $0 }
    }
}

/// Action-based sibling of `BadgeLink` — same capsule look, runs a closure
/// instead of opening a URL (e.g. "vX available" opens the update window).
struct BadgeButton<Content: View>: View {
    let action: () -> Void
    let label: Content
    @State private var hovering = false

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Content) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.14 : 0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { hovering = $0 }
    }
}

/// One sidebar navigation entry: icon + title, fixed-width trailing slot for
/// the ⌘N shortcut hint (revealing it never shifts anything), selection +
/// hover backgrounds. ⌘N is bound via `keyboardShortcut`.
private struct SidebarRow: View {
    let section: SettingsSection
    let shortcutNumber: Int
    let isSelected: Bool
    let showShortcut: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .frame(width: 16)
                // Constant font: no width change on selection, so titles never
                // wobble or suddenly truncate when the row becomes active.
                Text(section.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                // Reserved-width slot: the hint only fades in/out, so no other
                // element ever moves when it appears.
                Text("⌘\(shortcutNumber)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.secondary)
                    .opacity(showShortcut ? 1 : 0)
                    .frame(width: 24, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(rowBackground))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(shortcutNumber)")), modifiers: .command)
        .onHover { hovering = $0 }
        // VoiceOver reads the plain title — the ⌘N hint is a visual power-user
        // affordance and would only be noise in the label.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(section.title) section")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var rowBackground: Color {
        if isSelected { return Color.primary.opacity(0.09) }
        if hovering { return Color.primary.opacity(0.05) }
        return Color.primary.opacity(0)
    }
}

/// Reports each settings section's top edge within the scroll view, so the
/// sidebar selection can follow manual scrolling.
struct SectionTopKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { current, _ in current })
    }
}

private let settingsContentBottomKey = "__contentBottom"

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var alerts: AlertController
    @EnvironmentObject var updates: UpdateController
    @State private var showAddSheet = false
    @State private var showBrowserMeetingInfo = false
    @State private var showStartedCountdownInfo = false
    @StateObject private var commandHints = CommandHoldTracker()
    @State private var selectedSection: SettingsSection = .calendars
    /// While a sidebar jump animates, the scroll-position tracker is paused —
    /// otherwise intermediate positions overwrite the just-selected entry
    /// (selection visibly bounces back and forth).
    @State private var suppressSelectionTracking = false
    @State private var selectionResumeWorkItem: DispatchWorkItem?
    /// Section card currently emphasized by a sidebar jump — brief accent
    /// flash so jumps are visible even when no scrolling happens.
    @State private var highlightedSection: SettingsSection?
    @State private var highlightDismissWorkItem: DispatchWorkItem?

    /// Below this width the sidebar disappears and the form takes the full window.
    static let sidebarThreshold: CGFloat = 880

    var body: some View {
        GeometryReader { geo in
            let sidebarVisible = geo.size.width >= Self.sidebarThreshold
            ScrollViewReader { proxy in
                HStack(alignment: .top, spacing: 0) {
                    if sidebarVisible {
                        sidebar(proxy: proxy, hintsVisible: commandHints.showHints)
                            .padding(EdgeInsets(top: 24, leading: 16, bottom: 24, trailing: 10))
                            .frame(width: 224, alignment: .topLeading)
                            .transition(.opacity)
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 1)
                            .padding(.vertical, 24)
                            .frame(maxHeight: .infinity)
                    }
                    scrollContent
                }
                .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
            }
        }
        .onAppear { commandHints.install() }
        .onDisappear { commandHints.remove() }
        .sheet(isPresented: $showAddSheet) {
            AddCalendarView(existingURLs: store.subscriptions.map(\.url)) { name, url in
                store.addSubscription(name: name, urlString: url)
            }
        }
    }

    // MARK: - Sidebar navigation

    private func sidebar(proxy: ScrollViewProxy, hintsVisible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(SettingsSection.allCases.enumerated()), id: \.element) { index, section in
                SidebarRow(
                    section: section,
                    shortcutNumber: index + 1,
                    isSelected: selectedSection == section,
                    showShortcut: hintsVisible
                ) {
                    jump(to: section, proxy: proxy)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: selectedSection)
    }

    private func jump(to section: SettingsSection, proxy: ScrollViewProxy) {
        selectedSection = section
        // Pause scroll-following until the animated jump settles.
        suppressSelectionTracking = true
        selectionResumeWorkItem?.cancel()
        let resume = DispatchWorkItem { suppressSelectionTracking = false }
        selectionResumeWorkItem = resume
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: resume)
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(section.rawValue, anchor: .top)
        }
        flash(section)
    }

    /// Brief accent flash of the target card — feedback for jumps that land on
    /// an already-visible section (where no scrolling would show anything).
    private func flash(_ section: SettingsSection) {
        highlightDismissWorkItem?.cancel()
        // Reset without animation, re-apply on the next runloop tick, so
        // re-jumping to the same section still animates.
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { highlightedSection = nil }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) { highlightedSection = section }
        }
        let dismiss = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.45)) { highlightedSection = nil }
        }
        highlightDismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: dismiss)
    }

    // MARK: - Scroll content

    private var scrollContent: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    trackedSection(.calendars) { calendarsSection }
                    trackedSection(.native) { nativeSection }
                    trackedSection(.reminder) { reminderSection }
                    trackedSection(.general) { generalSection }
                    trackedSection(.about) { aboutSection }
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: SectionTopKey.self,
                            value: [settingsContentBottomKey: geo.frame(in: .named("settingsScroll")).maxY]
                        )
                    }
                    .frame(height: 0)
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "settingsScroll")
            .onPreferenceChange(SectionTopKey.self) { tops in
                guard !suppressSelectionTracking else { return }
                selectedSection = Self.activeSection(
                    from: tops,
                    viewportHeight: viewport.size.height,
                    contentBottom: tops[settingsContentBottomKey]
                )
            }
        }
    }

    /// Tags a section for `scrollTo`, reports its vertical position so the
    /// sidebar selection can follow manual scrolling, and carries the jump
    /// emphasis flash.
    private func trackedSection(_ section: SettingsSection, content: () -> some View) -> some View {
        content()
            .id(section.rawValue)
            .overlay(
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.05))
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1.5)
                }
                .opacity(highlightedSection == section ? 1 : 0)
                .allowsHitTesting(false)
            )
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SectionTopKey.self,
                        value: [section.rawValue: geo.frame(in: .named("settingsScroll")).minY]
                    )
                }
            )
    }

    /// The section whose header is nearest the reading line below the top edge.
    static func activeSection(from tops: [String: CGFloat]) -> SettingsSection {
        let present = SettingsSection.allCases.filter { tops[$0.rawValue] != nil }
        return present.min {
            abs((tops[$0.rawValue] ?? 0) - 140) < abs((tops[$1.rawValue] ?? 0) - 140)
        } ?? .calendars
    }

    static func activeSection(from tops: [String: CGFloat], viewportHeight: CGFloat, contentBottom: CGFloat?) -> SettingsSection {
        // The final card cannot normally reach the top threshold. At the exact
        // bottom of the scroll view, select it rather than leaving General active.
        if let bottom = contentBottom,
           let firstTop = tops[SettingsSection.calendars.rawValue],
           firstTop < 0,
           bottom <= viewportHeight + 1 {
            return .about
        }
        return activeSection(from: tops)
    }

    private var addButton: some View {
        Button {
            showAddSheet = true
        } label: {
            Label("Add Calendar…", systemImage: "plus")
        }
    }

    private var refreshButton: some View {
        Button {
            store.refresh()
        } label: {
            Label(store.isRefreshing ? "Syncing…" : "Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.isRefreshing)
    }

    @ViewBuilder private var lastSyncedText: some View {
        if let last = store.lastRefresh {
            Text("Last synced \(Fmt.ago(last))").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func confirmDelete(_ subscription: CalendarSubscription) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(subscription.name)”?"
        alert.informativeText = "Reminders for this calendar will stop. You can add it again anytime with the same link."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store.removeSubscription(subscription.id)
        }
    }

    private func upcomingEvents(for subscription: CalendarSubscription) -> [MeetingEvent] {
        guard subscription.isEnabled else { return [] }
        let now = Date()
        return store.events.filter { $0.calendarID == subscription.id && store.isVisible($0, at: now) }
    }

    private func sectionHeader(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var calendarsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(SettingsSection.calendars.title, SettingsSection.calendars.symbol)
            Text("Paste the shared iCal (ICS) links of the calendars you want reminders for.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if store.subscriptions.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.plus").font(.title2).foregroundStyle(.secondary)
                    Text("No calendars yet. Add one to get started.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
            } else {
                VStack(spacing: 8) {
                    ForEach($store.subscriptions) { $subscription in
                        SubscriptionRow(
                            subscription: $subscription,
                            events: upcomingEvents(for: subscription),
                            error: store.errors[subscription.id],
                            warning: store.warnings[subscription.id],
                            existingURLs: store.subscriptions.map(\.url),
                            onMute: { event in store.toggleMute(for: event) },
                            onRemoveRules: { ids in
                                store.setTitleFilters(calendarID: subscription.id, rules: TitleFilterRule.removing(ids: ids, from: subscription.titleFilters))
                            },
                            onSaveRules: { rules in
                                store.setTitleFilters(calendarID: subscription.id, rules: rules)
                            }
                        ) {
                            confirmDelete(subscription)
                        } onEdited: {
                            store.resync(subscriptionID: subscription.id)
                        }
                    }
                }
            }
            HStack {
                // Wide: one row. Narrow: Add on top, Refresh + last-synced below.
                ViewThatFits(in: .horizontal) {
                    HStack {
                        addButton
                        Spacer()
                        lastSyncedText
                        refreshButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        addButton
                        VStack(alignment: .leading, spacing: 2) {
                            refreshButton
                            lastSyncedText
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Apple Calendar (EventKit)

    private var nativeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(SettingsSection.native.title, SettingsSection.native.symbol)
            Text("Or use your Apple Calendars directly: iCloud, Google, Exchange, CalDAV and more, no links needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            switch store.nativeAuthorization {
            case .authorized:
                nativeAuthorizedContent
            case .notDetermined:
                nativeGrantView
            default:
                nativeDeniedView
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private var nativeAuthorizedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.nativeCalendarInfos.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.plus").font(.title2).foregroundStyle(.secondary)
                    Text("No calendars found. Add an account to your Apple Calendars first, then hit Refresh.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
            } else {
                ForEach(store.nativeCalendarInfos) { info in
                    nativeRow(for: info)
                }
                Toggle("Hide events I've declined", isOn: $store.settings.skipDeclined)
                    .font(.system(size: 12))
            }
            // Stale rows render independently of `nativeCalendarInfos` — an
            // enabled calendar whose EventKit counterpart vanished must stay
            // forgettable even when NO calendars are currently available.
            staleNativeRows
        }
    }

    private var nativeGrantView: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Read your Apple Calendars directly")
                    .font(.system(size: 12, weight: .medium))
                Text("You'll be asked for permission once. Your calendar data stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.requestNativeAccess()
            } label: {
                Label("Grant Access…", systemImage: "lock.open")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }

    private var nativeDeniedView: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Calendar access is turned off for now.")
                    .font(.system(size: 12, weight: .medium))
                Text("Turn it on in System Settings → Privacy & Security → Calendars.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            } label: {
                Label("Open System Settings…", systemImage: "gear")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }

    private func nativeRow(for info: NativeCalendarInfo) -> some View {
        let persisted = store.nativeCalendars.first { $0.ekIdentifier == info.ekIdentifier }
        let isOn = persisted?.isEnabled ?? false
        let calendarID = persisted?.id
        let visible = visibleNativeEvents(calendarID: calendarID, enabled: isOn)
        return NativeCalendarRow(
            info: info,
            isOn: isOn,
            colorHex: persisted?.colorHex ?? info.colorHex,
            events: visible,
            rules: persisted?.titleFilters ?? [],
            calendarID: calendarID,
            onToggle: { on in store.setNativeCalendarEnabled(info, enabled: on) },
            onColor: { hex in store.setNativeCalendarColor(info, hex: hex) },
            onMute: { event in store.toggleMute(for: event) },
            onRemoveRules: { ids in
                if let calendarID {
                    store.setTitleFilters(calendarID: calendarID, rules: TitleFilterRule.removing(ids: ids, from: persisted?.titleFilters ?? []))
                }
            },
            onSaveRules: { rules in
                if let calendarID {
                    store.setTitleFilters(calendarID: calendarID, rules: rules)
                }
            }
        )
    }

    private func visibleNativeEvents(calendarID: UUID?, enabled: Bool) -> [MeetingEvent] {
        guard enabled, let calendarID else { return [] }
        let now = Date()
        return store.events.filter { $0.calendarID == calendarID && store.isVisible($0, at: now) }
    }

    /// Persisted native calendars whose EventKit counterpart vanished (account removed).
    @ViewBuilder private var staleNativeRows: some View {
        let available = Set(store.nativeCalendarInfos.map(\.ekIdentifier))
        let stale = store.nativeCalendars.filter { !available.contains($0.ekIdentifier) }
        if !stale.isEmpty {
            ForEach(stale) { native in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("“\(native.name)” is no longer available")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !native.titleFilters.isEmpty {
                        Text("\(native.titleFilters.count) muted \(native.titleFilters.count == 1 ? "rule" : "rules")")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Button("Forget") {
                        store.forgetNativeCalendar(native.id)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(SettingsSection.reminder.title, SettingsSection.reminder.symbol)
            Text("The fullscreen reminder opens this long before an event starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Flow layout: pills hug their content (one compact row when the
            // window is wide) and wrap as whole pills when it narrows —
            // no stretching, no mid-pill line breaks.
            FlowLayout(spacing: 6) {
                ForEach([0, 10, 30, 60, 120, 300, 600, 900], id: \.self) { seconds in
                    Button {
                        store.settings.leadSeconds = seconds
                    } label: {
                        Text(Fmt.leadTime(seconds))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(PresetButtonStyle(active: store.settings.leadSeconds == seconds))
                }
            }
            Stepper(value: $store.settings.leadSeconds, in: 0...7200, step: 15) {
                Text("Fine tune: \(Fmt.leadTime(store.settings.leadSeconds))")
            }
            Divider()
            Toggle("Don't interrupt me while I'm in a meeting", isOn: Binding(
                get: { store.settings.suppressRemindersDuringMeetings },
                set: { store.setMeetingSuppressionEnabled($0) }
            ))
            .disabled(store.meetingDetectionChecking || !MeetingActivityProbe.platformPotentiallySupported || store.meetingDetectionAvailable == false)
            Text("Uses local audio activity from meeting apps. No audio is recorded.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if store.meetingDetectionChecking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking local meeting detection...")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let error = store.meetingDetectionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if !MeetingActivityProbe.platformPotentiallySupported {
                Text("This option requires macOS 14 or later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if store.settings.suppressRemindersDuringMeetings {
                HStack(spacing: 6) {
                    Toggle("Include meetings in browsers", isOn: $store.settings.includeBrowserMeetings)
                    Button {
                        showBrowserMeetingInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showBrowserMeetingInfo, arrowEdge: .trailing) {
                        Text("macOS can identify the browser using the microphone, but not the responsible tab or website. This covers Google Meet and other web calls, but voice recording, dictation, or another site using the microphone can also be mistaken for a meeting.")
                            .font(.callout)
                            .padding(14)
                            .frame(width: 320, alignment: .leading)
                    }
                }
                .padding(.leading, 18)
            }
            Divider()
            Toggle("Play sound", isOn: $store.settings.soundEnabled)
            if store.settings.soundEnabled {
                HStack {
                    Picker("Sound", selection: $store.settings.soundName) {
                        ForEach(AppStore.soundNames, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    Button {
                        NSSound(named: NSSound.Name(store.settings.soundName))?.play()
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Divider()
            Button {
                alerts.presentPreview()
            } label: {
                Label("Preview Reminder", systemImage: "eye")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(SettingsSection.general.title, SettingsSection.general.symbol)
            Picker("Check calendars every", selection: $store.settings.refreshMinutes) {
                Text("5 min").tag(5)
                Text("15 min").tag(15)
                Text("30 min").tag(30)
                Text("60 min").tag(60)
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
            Toggle("Show countdown in menu bar", isOn: $store.settings.showMenuBarCountdown)
            HStack(spacing: 6) {
                Picker("Show elapsed start time for", selection: $store.settings.elapsedStartMinutes) {
                    Text("Never").tag(-1)
                    Text("Until meeting ends").tag(0)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("60 minutes").tag(60)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 320)
                Button {
                    showStartedCountdownInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("How recently started meetings affect the menu bar countdown")
                .accessibilityLabel("About elapsed start time")
                .popover(isPresented: $showStartedCountdownInfo, arrowEdge: .trailing) {
                    Text("After a meeting starts, now briefly counts backward so you can see that you may still join late. The selected duration is the maximum. If another meeting start is closer, now switches at the midpoint between both starts. This only affects the menu bar countdown; reminder delivery and running meetings in the menu are independent.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(width: 360, alignment: .leading)
                }
            }
            Toggle("Launch at Login", isOn: $store.settings.launchAtLogin)
            if case .requiresApproval = store.loginItemState {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Needs approval in System Settings → Login Items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    .controlSize(.small)
                }
            } else if case .failed = store.loginItemState, store.settings.launchAtLogin {
                Text("Couldn't keep Launch at Login active — check System Settings → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Divider()
            Toggle("Check for updates automatically", isOn: $store.settings.automaticUpdateChecks)
            // Wide: one row. Narrow: wraps to its own lines (ViewThatFits).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    updateStatusContent
                }
                VStack(alignment: .leading, spacing: 6) {
                    updateStatusContent
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private var updateStatusContent: some View {
        Button {
            updates.check(userInitiated: true)
        } label: {
            if updates.isChecking {
                Text("Checking…")
            } else {
                Text("Check Now")
            }
        }
        .disabled(updates.isChecking)
        if let manifest = updates.available {
            if updates.stagedVersion == manifest.version {
                Text("v\(manifest.version) is ready to install")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Install…") {
                    updates.presentAvailableFromMenu()
                }
            } else if let failure = updates.preparationFailure, failure.version == manifest.version {
                Text("Couldn't prepare v\(manifest.version)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(failure.reason)
                Button("Retry") {
                    updates.retryPreparation()
                }
            } else {
                Text("v\(manifest.version) is being prepared…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let last = updates.lastSuccessfulCheck {
            Text("Last checked \(Fmt.ago(last))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(SettingsSection.about.title, SettingsSection.about.symbol)
            // Wide: one row. Narrow: version, GitHub and website stack.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    aboutItems
                }
                VStack(alignment: .leading, spacing: 6) {
                    aboutItems
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private var aboutItems: some View {
        // Version badge → the changelog/release notes of exactly this version.
        // While an update is known-available, a SECOND badge appears next to
        // it — it opens the update window (not a URL): the version pill stays
        // about the running version, the availability pill is the action.
        BadgeLink(url: Self.changelogURL ?? Links.releases) {
            HStack(spacing: 5) {
                Image(systemName: "tag")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Version \(Self.version)").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let manifest = updates.available {
            BadgeButton {
                updates.presentAvailableFromMenu()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("v\(manifest.version) available").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        BadgeLink(url: Links.repo) {
            HStack(spacing: 5) {
                GitHubMark().fill(Color.secondary).frame(width: 11, height: 11)
                Text("GitHub").font(.caption).foregroundStyle(.secondary)
            }
        }
        BadgeLink(url: Links.website) {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("thomasboch.com").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Release notes ("changelog") for the running version.
    static var changelogURL: URL? {
        URL(string: Links.repo.absoluteString + "/releases/tag/v" + version)
    }

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }
}
