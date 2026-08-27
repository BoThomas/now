import SwiftUI
import AppKit

final class AlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AlertController: ObservableObject {
    @Published private(set) var shownEvents: [MeetingEvent] = []
    private var panel: AlertPanel?
    private var monitor: Any?
    /// Set by AppDelegate: flips the app .regular/.accessory. A timer-fired panel
    /// can't take keyboard focus while we're a background .accessory app (macOS
    /// ignores activate() without user interaction) — being .regular is what makes
    /// activation real. Called on present AND close.
    var policyDidChange: (() -> Void)?
    var store: AppStore?

    var isOpen: Bool { panel != nil }

    func present(_ events: [MeetingEvent], playSound: Bool = true) {
        guard !events.isEmpty else { return }
        shownEvents = events
        closePanel()
        let panel = AlertPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        let host = NSHostingView(rootView: AlertView().environmentObject(self))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        if let screen = NSScreen.main {
            panel.setFrame(screen.frame, display: true)
        }
        self.panel = panel
        // A timer-fired panel can't take keyboard focus while we're a background
        // .accessory app — macOS ignores activate() without user interaction, and
        // keystrokes would invisibly go to the app hidden behind the overlay (think:
        // typing Enter into a chat you can't see). The delegate flips us to .regular
        // (Dock icon + our menu bar show for the alert's duration) and back on close.
        policyDidChange?()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installMonitor()
        if playSound {
            store?.playSound()
        }
    }

    func presentPreview() {
        let now = Date()
        let event = MeetingEvent(
            uid: "preview",
            title: "Team Sync — Preview",
            start: now.addingTimeInterval(120),
            end: now.addingTimeInterval(1920),
            location: "Zoom",
            notes: nil,
            link: URL(string: "https://zoom.us/j/1234567890"),
            calendarID: UUID(),
            calendarName: "Preview",
            colorIndex: 0
        )
        present([event])
    }

    func close() {
        closePanel()
        shownEvents = []
    }

    func snoozeAll() {
        store?.snooze(shownEvents.map(\.id))
        close()
    }

    func join(_ url: URL) {
        NSWorkspace.shared.open(url)
        close()
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
        policyDidChange?()
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Snooze re-fires while `now <= event.end` (AppStore.tick) — a running meeting can still be snoozed.
    private var isSnoozeable: Bool {
        let now = Date()
        return shownEvents.contains { now < $0.end }
    }

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isOpen else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
            // ⌘W/⌘M would only beep on the borderless panel — swallow them silently.
            if modifiers == .command,
               let key = event.charactersIgnoringModifiers?.lowercased(),
               key == "w" || key == "m" {
                return nil
            }
            // Plain "s" snoozes while any event is still running; consumed quietly otherwise.
            if modifiers.isEmpty,
               event.charactersIgnoringModifiers?.lowercased() == "s" {
                if self.isSnoozeable {
                    self.snoozeAll()
                }
                return nil
            }
            switch event.keyCode {
            case 53:
                self.close()
                return nil
            case 36, 76:
                if let url = self.shownEvents.compactMap(\.link).first {
                    self.join(url)
                } else {
                    self.close()
                }
                return nil
            default:
                return event
            }
        }
    }
}

struct AlertView: View {
    @EnvironmentObject var controller: AlertController
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let first = controller.shownEvents.first {
                let accent = first.color
                RadialGradient(colors: [accent.opacity(0.25), accent.opacity(0.06), .clear], center: UnitPoint(x: 0.5, y: 0.18), startRadius: 80, endRadius: 1100)
                    .ignoresSafeArea()
            }
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                content(now: timeline.date)
            }
        }
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.15)) { appeared = true }
        }
    }

    private func content(now: Date) -> some View {
        let events = controller.shownEvents
        return VStack(spacing: 0) {
            Spacer(minLength: 30)
            if events.count == 1 {
                SingleEventView(event: events[0], now: now)
            } else {
                MultiEventView(events: events, now: now)
            }
            Spacer(minLength: 30)
            footer(events: events)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(50)
    }

    private func footer(events: [MeetingEvent]) -> some View {
        // Snooze stays available while any event is running (it re-fires until end).
        let snoozeable = events.contains { $0.end > Date() }
        return VStack(spacing: 16) {
            HStack(spacing: 16) {
                if snoozeable {
                    Button {
                        controller.snoozeAll()
                    } label: {
                        Label("Snooze 1 min", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.large)
                    .keyboardShortcut("s", modifiers: [])
                }
                Button {
                    controller.close()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .controlSize(.large)
                .keyboardShortcut(.escape, modifiers: [])
            }
            Text(snoozeable ? "esc close · return join · s snooze" : "esc close · return join")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.bottom, 10)
    }
}

struct SingleEventView: View {
    @EnvironmentObject var controller: AlertController
    let event: MeetingEvent
    let now: Date

    var accent: Color { event.color }

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 8) {
                Circle().fill(accent).frame(width: 9, height: 9)
                Text(event.calendarName.uppercased())
                    .font(.system(size: 14, weight: .bold))
                    .tracking(2)
            }
            .foregroundStyle(.white.opacity(0.7))
            Text(event.title.isEmpty ? "Untitled event" : event.title)
                .font(.system(size: 64, weight: .heavy))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.35)
                .padding(.horizontal, 40)
            Text(statusText)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
            HStack(spacing: 20) {
                Label(timeRangeText, systemImage: "clock")
                Label(Fmt.duration(event.end.timeIntervalSince(event.start)), systemImage: "hourglass")
                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .lineLimit(1)
                } else if let link = event.link, let provider = LinkExtractor.providerName(for: link) {
                    Label(provider, systemImage: "mappin.and.ellipse")
                        .lineLimit(1)
                }
            }
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
            if let link = event.link {
                Button {
                    controller.join(link)
                } label: {
                    Label("Join Meeting", systemImage: "video.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.large)
            }
        }
    }

    var statusText: String {
        if now < event.start {
            return "STARTS IN \(Fmt.mmss(event.start.timeIntervalSince(now)))"
        }
        if now < event.end {
            return "NOW · ENDS IN \(Fmt.mmss(event.end.timeIntervalSince(now)))"
        }
        return "FINISHED"
    }

    var timeRangeText: String {
        let startText = Calendar.current.isDateInToday(event.start) ? Fmt.time.string(from: event.start) : event.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "\(startText) – \(Fmt.time.string(from: event.end))"
    }
}

struct MultiEventView: View {
    @EnvironmentObject var controller: AlertController
    let events: [MeetingEvent]
    let now: Date

    var body: some View {
        VStack(spacing: 24) {
            Text("\(events.count) EVENTS STARTING")
                .font(.system(size: 15, weight: .bold))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.6))
            VStack(spacing: 14) {
                ForEach(events) { event in
                    HStack(spacing: 20) {
                        Circle().fill(event.color).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title.isEmpty ? "Untitled event" : event.title)
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Text("\(Fmt.time.string(from: event.start)) – \(Fmt.time.string(from: event.end)) · \(event.calendarName) · \(status(event))")
                                .font(.system(size: 15))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                        if let link = event.link {
                            Button {
                                controller.join(link)
                            } label: {
                                Label("Join", systemImage: "video.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(event.color)
                            .controlSize(.large)
                        }
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
                    .frame(maxWidth: 860)
                }
            }
        }
    }

    private func status(_ event: MeetingEvent) -> String {
        if now < event.start { return "starts in \(Fmt.mmss(event.start.timeIntervalSince(now)))" }
        if now < event.end { return "now" }
        return "finished"
    }
}
