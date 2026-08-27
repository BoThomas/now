import SwiftUI
import AppKit

enum Links {
    static let repo = URL(string: "https://github.com/BoThomas/now")!
    static let releases = URL(string: "https://github.com/BoThomas/now/releases/latest")!
    static let website = URL(string: "https://thomasboch.com")!
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

/// Expandable "upcoming events" list shared by ICS subscription rows and native
/// Apple Calendar rows — same grammar in both places.
struct UpcomingEventList: View {
    let events: [MeetingEvent]
    let hasMoreEvents: Bool
    let error: String?
    let colorHex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if events.isEmpty {
                Text(error != nil ? "No events — fix the sync error above" : "No upcoming events in the next two weeks")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(dayText(event))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(Fmt.time.string(from: event.start))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                        }
                        .frame(width: 60, alignment: .leading)
                        Text(event.title.isEmpty ? "Untitled" : event.title)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        if let link = event.link {
                            Button {
                                NSWorkspace.shared.open(link)
                            } label: {
                                Label(hostText(link), systemImage: "video.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Palette.color(hex: colorHex))
                            }
                            .buttonStyle(.link)
                            .cursor(.pointingHand)
                            .help("Open \(link.absoluteString)")
                        }
                    }
                    .padding(.leading, 4)
                }
                if hasMoreEvents {
                    Text("and more…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
        }
        .padding(.top, 2)
    }

    private func dayText(_ event: MeetingEvent) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(event.start) { return "Today" }
        if calendar.isDate(event.start, inSameDayAs: Date().addingTimeInterval(86400)) { return "Tomorrow" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: event.start)).day ?? 0
        if days < 7 {
            return event.start.formatted(.dateTime.weekday(.abbreviated))
        }
        return event.start.formatted(.dateTime.day().month(.abbreviated))
    }

    private func hostText(_ link: URL) -> String {
        (link.host ?? "").replacingOccurrences(of: "www.", with: "")
    }
}

struct SubscriptionRow: View {
    @Binding var subscription: CalendarSubscription
    let events: [MeetingEvent]
    let hasMoreEvents: Bool
    let error: String?
    let onDelete: () -> Void
    let onEdited: () -> Void
    @State private var expanded = false
    @State private var showEditSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("", isOn: $subscription.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(subscription.isEnabled ? "Disable calendar (stops sync and reminders)" : "Enable calendar")
                ColorPicker("", selection: Binding(
                    get: { Palette.color(hex: subscription.colorHex) },
                    set: { subscription.colorHex = Palette.hexString(from: NSColor($0)) }
                ), supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(x: 0.75, y: 0.75)
                .frame(width: 24, height: 20)
                .padding(.leading, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(subscription.name).font(.system(size: 13, weight: .semibold))
                    Text(subscription.url).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let error = error {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
                    }
                }
                .opacity(subscription.isEnabled ? 1 : 0.5)
                Spacer()
                Button {
                    showEditSheet = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit name or URL")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove calendar")
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .disabled(!subscription.isEnabled)
                .help(subscription.isEnabled ? "Show upcoming events" : "Calendar disabled")
            }
            if expanded && subscription.isEnabled {
                UpcomingEventList(events: events, hasMoreEvents: hasMoreEvents, error: error, colorHex: subscription.colorHex)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .onChange(of: subscription.isEnabled) { enabled in
            if !enabled { expanded = false }
        }
        .sheet(isPresented: $showEditSheet) {
            EditCalendarView(subscription: $subscription) {
                onEdited()
            }
        }
    }
}

/// One calendar from EventKit: toggle = use it, color = tint for its events
/// (seeded from the calendar's own color on first enable), chevron = upcoming events.
struct NativeCalendarRow: View {
    let info: NativeCalendarInfo
    let isOn: Bool
    let colorHex: String
    let events: [MeetingEvent]
    let hasMoreEvents: Bool
    let onToggle: (Bool) -> Void
    let onColor: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(get: { isOn }, set: { onToggle($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(isOn ? "Stop reminders for this calendar" : "Show reminders for this calendar")
                ColorPicker("", selection: Binding(
                    get: { Palette.color(hex: colorHex) },
                    set: { onColor(Palette.hexString(from: NSColor($0))) }
                ), supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(x: 0.75, y: 0.75)
                .frame(width: 24, height: 20)
                .padding(.leading, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title).font(.system(size: 13, weight: .semibold))
                    Text(info.sourceTitle.isEmpty ? "Apple Calendars" : "via \(info.sourceTitle)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .opacity(isOn ? 1 : 0.5)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .disabled(!isOn)
                .help(isOn ? "Show upcoming events" : "Calendar disabled")
            }
            if expanded && isOn {
                UpcomingEventList(events: events, hasMoreEvents: hasMoreEvents, error: nil, colorHex: colorHex)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .onChange(of: isOn) { enabled in
            if !enabled { expanded = false }
        }
    }
}

struct EditCalendarView: View {
    @Binding var subscription: CalendarSubscription
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var urlString: String
    @State private var errorText: String?
    @State private var didChangeURL = false

    init(subscription: Binding<CalendarSubscription>, onSave: @escaping () -> Void) {
        _subscription = subscription
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
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("webcal://") {
            trimmed = "https://" + String(trimmed.dropFirst("webcal://".count))
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            errorText = "That doesn't look like a valid calendar URL."
            return
        }
        subscription.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? subscription.name : name.trimmingCharacters(in: .whitespaces)
        subscription.url = trimmed
        dismiss()
        onSave()
    }
}

struct AddCalendarView: View {
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
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("webcal://") {
            trimmed = "https://" + String(trimmed.dropFirst("webcal://".count))
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            errorText = "That doesn't look like a valid calendar URL."
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        onAdd(trimmedName.isEmpty ? "Calendar" : trimmedName, trimmed)
        dismiss()
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var alerts: AlertController
    @State private var showAddSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                calendarsSection
                nativeSection
                reminderSection
                generalSection
            }
            .padding(24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showAddSheet) {
            AddCalendarView { name, url in
                store.addSubscription(name: name, urlString: url)
            }
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
        return Array(store.events.filter { $0.calendarID == subscription.id && store.isVisible($0, at: now) }.prefix(8))
    }

    private func upcomingCount(for subscription: CalendarSubscription) -> Int {
        guard subscription.isEnabled else { return 0 }
        let now = Date()
        return store.events.filter { $0.calendarID == subscription.id && store.isVisible($0, at: now) }.count
    }

    private func sectionHeader(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var calendarsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("External Calendars", "calendar")
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
                            hasMoreEvents: upcomingCount(for: subscription) > 8,
                            error: store.errors[subscription.id]
                        ) {
                            confirmDelete(subscription)
                        } onEdited: {
                            store.resync(subscriptionID: subscription.id)
                        }
                    }
                }
            }
            HStack {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Calendar…", systemImage: "plus")
                }
                Spacer()
                if let last = store.lastRefresh {
                    Text("Last synced \(Fmt.ago(last))").font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    store.refresh()
                } label: {
                    Label(store.isRefreshing ? "Syncing…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Apple Calendar (EventKit)

    private var nativeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Apple Calendars", "calendar.badge.clock")
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
            VStack(spacing: 8) {
                ForEach(store.nativeCalendarInfos) { info in
                    nativeRow(for: info)
                }
                staleNativeRows
            }
            Toggle("Hide events I've declined", isOn: $store.settings.skipDeclined)
                .font(.system(size: 12))
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
            events: Array(visible.prefix(8)),
            hasMoreEvents: visible.count > 8,
            onToggle: { on in store.setNativeCalendarEnabled(info, enabled: on) },
            onColor: { hex in store.setNativeCalendarColor(info, hex: hex) }
        )
    }

    private func visibleNativeEvents(calendarID: UUID?, enabled: Bool) -> [MeetingEvent] {
        guard enabled, let calendarID else { return [] }
        let now = Date()
        return store.events.filter { $0.calendarID == calendarID && store.isVisible($0, at: now) }
    }

    /// Enabled native calendars whose EventKit counterpart vanished (account removed).
    @ViewBuilder private var staleNativeRows: some View {
        let available = Set(store.nativeCalendarInfos.map(\.ekIdentifier))
        let stale = store.nativeCalendars.filter { !available.contains($0.ekIdentifier) && $0.isEnabled }
        if !stale.isEmpty {
            ForEach(stale) { native in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("“\(native.name)” is no longer available")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
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
            sectionHeader("Reminder", "bell.badge")
            Text("The fullscreen reminder opens this long before an event starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach([0, 10, 30, 60, 120, 300, 600, 900], id: \.self) { seconds in
                    Button {
                        store.settings.leadSeconds = seconds
                    } label: {
                        Text(Fmt.leadTime(seconds))
                    }
                    .buttonStyle(PresetButtonStyle(active: store.settings.leadSeconds == seconds))
                }
            }
            Stepper(value: $store.settings.leadSeconds, in: 0...7200, step: 15) {
                Text("Fine tune: \(Fmt.leadTime(store.settings.leadSeconds))")
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
            sectionHeader("General", "gearshape")
            Picker("Check calendars every", selection: $store.settings.refreshMinutes) {
                Text("5 min").tag(5)
                Text("15 min").tag(15)
                Text("30 min").tag(30)
                Text("60 min").tag(60)
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
            Toggle("Show countdown in menu bar", isOn: $store.settings.showMenuBarCountdown)
            Picker("Show started meetings", selection: $store.settings.lateMinutes) {
                Text("Hide once started").tag(-1)
                Text("Until they end").tag(0)
                Text("5 min after start").tag(5)
                Text("15 min after start").tag(15)
                Text("30 min after start").tag(30)
                Text("60 min after start").tag(60)
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 300)
            Toggle("Launch at Login", isOn: $store.settings.launchAtLogin)
            HStack(spacing: 14) {
                Text("Version \(Self.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    GitHubMark().fill(Color.secondary).frame(width: 12, height: 12)
                    Link("GitHub", destination: Links.repo)
                        .font(.caption)
                }
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Link("thomasboch.com", destination: Links.website)
                        .font(.caption)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }
}
