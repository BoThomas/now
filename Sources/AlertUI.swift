import SwiftUI
import AppKit

final class AlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AlertController: ObservableObject {
    @Published private(set) var shownEvents: [MeetingEvent] = []
    private var panel: AlertPanel?
    private var monitor: Any?
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
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isOpen else { return event }
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
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                if events.contains(where: { $0.start > Date() }) {
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
            Text("esc close · return join · s snooze")
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
