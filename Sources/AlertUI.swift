import SwiftUI
import AppKit

final class AlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AlertController: ObservableObject {
    @Published private(set) var shownEvents: [MeetingEvent] = []
    private var panel: AlertPanel?
    private var monitor: Any?
    /// Preview alerts (Settings → Preview Reminder) show fabricated events that
    /// are not in the store — reconciliation must not close them.
    private var isPreview = false
    /// True while a system dialog (e.g. the quit-vs-dismiss confirm) runs above
    /// the panel — the key monitor must let keystrokes through to it.
    var modalAlertActive = false
    /// Set by AppDelegate: flips the app .regular/.accessory. A timer-fired panel
    /// can't take keyboard focus while we're a background .accessory app (macOS
    /// ignores activate() without user interaction) — being .regular is what makes
    /// activation real. Called on present AND close.
    var policyDidChange: (() -> Void)?
    var store: AppStore?

    /// Fresh timer-fired panels swallow ALL keystrokes for this long after
    /// appearing: the panel steals key focus mid-sentence (see above), and
    /// keystrokes already in flight from whatever the user was typing must
    /// never trigger an action — Return joins a meeting, digits 1-9 join
    /// cards, "s" snoozes, Escape closes. The shortcut-hint row stays
    /// hidden until the guard expires, so its reveal doubles as the
    /// "keyboard is live" signal. Previews are exempt (user-initiated).
    static let keystrokeGuardInterval: TimeInterval = 1.0
    /// True while that window runs. Any click in the panel ends it early.
    @Published private(set) var isGuardingKeystrokes = false
    /// Bumped on every guard start/end — a pending expiry from an older
    /// panel must never disarm a newer one.
    private var keystrokeGuardGeneration = 0

    var isOpen: Bool { panel != nil }

    func present(_ events: [MeetingEvent], playSound: Bool = true, armKeystrokeGuard: Bool = true) {
        guard !events.isEmpty else { return }
        // A newly due reminder must never REPLACE a visible one (its events
        // would be permanently discarded — they are already marked alerted) —
        // merge into the open panel instead.
        if isOpen {
            shownEvents = Self.mergedShown(existing: shownEvents, new: events)
            if playSound { store?.playSound() }
            return
        }
        shownEvents = events
        isPreview = false
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
        // Arm BEFORE the panel can become key — a keystroke landing in the
        // same instant the panel appears is by definition not aimed at it.
        if armKeystrokeGuard {
            beginKeystrokeGuard()
        } else {
            endKeystrokeGuard()
        }
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
        isPreview = true
        present([event], armKeystrokeGuard: false)
        isPreview = true // present() resets it for real deliveries
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

    /// Merges newly due events into the cards already on screen (deduped by
    /// id, deterministically ordered). Pure — unit-testable without a panel.
    nonisolated static func mergedShown(existing: [MeetingEvent], new: [MeetingEvent]) -> [MeetingEvent] {
        var merged = existing
        for event in new where !merged.contains(where: { $0.id == event.id }) {
            merged.append(event)
        }
        return AppStore.normalizedEvents(merged)
    }

    /// Drops cards whose event vanished from the store (cancelled, calendar
    /// removed/disabled, occurrence deleted) and picks up refreshed copies of
    /// changed events. A rescheduled meeting gets a NEW id, so its old card
    /// drops and the new time earns its own reminder when due again. Pure.
    nonisolated static func reconciledShownEvents(shown: [MeetingEvent], current: [MeetingEvent]) -> [MeetingEvent] {
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return shown.compactMap { byID[$0.id] }
    }

    /// Called from `AppStore.commitEvents` so an open alert tracks reality.
    func reconcile(withCurrent current: [MeetingEvent]) {
        guard isOpen, !isPreview else { return }
        let next = Self.reconciledShownEvents(shown: shownEvents, current: current)
        if next.isEmpty {
            close()
        } else {
            shownEvents = next
        }
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
        policyDidChange?()
        endKeystrokeGuard()
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    // MARK: - Keystroke guard

    private func beginKeystrokeGuard() {
        keystrokeGuardGeneration += 1
        isGuardingKeystrokes = true
        let presentedAt = Date()
        let generation = keystrokeGuardGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keystrokeGuardInterval) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.keystrokeGuardGeneration == generation else { return }
                self.isGuardingKeystrokes = Self.keystrokeGuardActive(
                    presentedAt: presentedAt,
                    now: Date(),
                    interval: Self.keystrokeGuardInterval
                )
            }
        }
    }

    private func endKeystrokeGuard() {
        keystrokeGuardGeneration += 1
        isGuardingKeystrokes = false
    }

    /// Pure: whether the guard still applies at `now` for a panel presented
    /// at `presentedAt`. Active strictly before the interval elapses — at the
    /// boundary exactly the keyboard is live again.
    nonisolated static func keystrokeGuardActive(presentedAt: Date, now: Date, interval: TimeInterval) -> Bool {
        now.timeIntervalSince(presentedAt) < interval
    }

    /// Snooze re-fires while `now < event.end` (AppStore.tick) — a running meeting can still be snoozed.
    private var isSnoozeable: Bool {
        let now = Date()
        return shownEvents.contains { now < $0.end }
    }

    /// True when keyboard focus sits on a control inside the panel (a Join,
    /// Snooze or Close button — e.g. via Full Keyboard Access) rather than on
    /// the panel itself. Return must then go to that control, not the global
    /// join shortcut.
    private var hasFocusedControl: Bool {
        guard let panel, let responder = panel.firstResponder else { return false }
        return responder !== panel && responder !== panel.contentView
    }

    // MARK: - Key handling

    /// Classification of a keyDown while the alert is open. Extracted as a
    /// pure function so the keyboard contract is unit-testable.
    enum KeyAction: Equatable {
        case close            // Escape
        case joinOrClose      // plain Return / Enter, nothing focused
        case pressFocused     // plain Return with a focused control — activate it
        case joinIndex(Int)   // plain digit 1-9 — join that shown event
        case snooze           // plain "s"
        case swallow          // ⌘W/⌘M — would only beep on the borderless panel
        case passThrough      // everything else (incl. modified Return)
    }

    nonisolated static func keyAction(modifiers: NSEvent.ModifierFlags, keyCode: UInt16, characters: String?, snoozeable: Bool, hasFocusedControl: Bool) -> KeyAction {
        let mods = modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if mods == .command,
           let key = characters?.lowercased(),
           key == "w" || key == "m" {
            return .swallow
        }
        if mods.isEmpty, characters?.lowercased() == "s" {
            return snoozeable ? .snooze : .swallow
        }
        if mods.isEmpty,
           let digit = characters?.first,
           digit.isNumber,
           let number = digit.wholeNumberValue,
           (1...9).contains(number) {
            return .joinIndex(number)
        }
        switch keyCode {
        case 53: // Escape
            return .close
        case 36, 76: // Return / keypad Enter
            // Modified Return always passes through. Plain Return ACTIVATES the
            // focused control (like Space does): with Full Keyboard Access on,
            // something is always focused, so merely passing Return through
            // would make the key completely dead — and a focused Join button
            // must never be overridden by the global "join first meeting".
            // With nothing focused, plain Return is the global join/close.
            if !mods.isEmpty { return .passThrough }
            return hasFocusedControl ? .pressFocused : .joinOrClose
        default:
            return .passThrough
        }
    }

    private func installMonitor() {
        // Also watches leftMouseDown: any click in the panel is deliberate
        // engagement — it ends the keystroke guard early so the keyboard is
        // live for whatever follows the click.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self = self, self.isOpen, !self.modalAlertActive else { return event }
            if event.type == .leftMouseDown {
                if self.isGuardingKeystrokes { self.endKeystrokeGuard() }
                return event
            }
            // Keystroke guard: the first moments after a timer-fired panel
            // appears, swallow EVERYTHING silently — keystrokes already in
            // flight from whatever the user was typing when the panel stole
            // key focus must never trigger an action (Return joins a
            // meeting, digits join cards, "s" snoozes, Escape closes).
            if self.isGuardingKeystrokes { return nil }
            let action = Self.keyAction(
                modifiers: event.modifierFlags,
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers,
                snoozeable: self.isSnoozeable,
                hasFocusedControl: self.hasFocusedControl
            )
            switch action {
            case .close:
                self.close()
                return nil
            case .joinOrClose:
                if let url = self.shownEvents.compactMap(\.link).first {
                    self.join(url)
                } else {
                    self.close()
                }
                return nil
            case .joinIndex(let number):
                // "3" joins the third card; out of range or link-less events
                // are swallowed quietly.
                if shownEvents.indices.contains(number - 1),
                   let url = self.shownEvents[number - 1].link {
                    self.join(url)
                }
                return nil
            case .pressFocused:
                // Translate Return into a Space keypress: macOS buttons activate
                // via Space, and the responder chain routes Space to whatever
                // FKA focused (SwiftUI buttons are NOT NSButton first responders,
                // so performClick on firstResponder isn't available — that path
                // beeps). Our own monitor passes keyCode 49 through untouched.
                if self.hasFocusedControl {
                    return NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: [],
                        timestamp: event.timestamp,
                        windowNumber: event.windowNumber,
                        context: nil,
                        characters: " ",
                        charactersIgnoringModifiers: " ",
                        isARepeat: false,
                        keyCode: 49
                    )
                }
                return event
            case .snooze:
                self.snoozeAll()
                return nil
            case .swallow:
                return nil
            case .passThrough:
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
                let accent = first.readableColorOnBlack
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
        let joinable = events.contains { $0.link != nil }
        var hints = ["esc close"]
        if events.count > 1 {
            if joinable {
                hints.append("return join first")
                hints.append("1-\(min(events.count, 9)) join")
            } else {
                hints.append("return close")
            }
        } else {
            hints.append(joinable ? "return join" : "return close")
        }
        if snoozeable { hints.append("s snooze") }
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
            // Hidden while the keystroke guard runs; its fade-in is the
            // "shortcuts are live" signal (preview panels show it at once).
            Text(hints.joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
                .opacity(controller.isGuardingKeystrokes ? 0 : 1)
                .animation(.easeOut(duration: 0.25), value: controller.isGuardingKeystrokes)
        }
        .padding(.bottom, 10)
    }
}

struct SingleEventView: View {
    @EnvironmentObject var controller: AlertController
    let event: MeetingEvent
    let now: Date

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
                .foregroundStyle(readableAccent)
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
                .tint(readableAccent)
                .controlSize(.large)
            }
        }
    }

    var accent: Color { event.color }
    /// The countdown/prominent controls use a contrast-safe variant so a
    /// user-picked near-black calendar color stays visible on the black panel.
    var readableAccent: Color { event.readableColorOnBlack }

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
            // Scrollable: on small displays / large accessibility text the last
            // cards and the footer controls must stay reachable.
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        HStack(spacing: 20) {
                            // Numbered badge: keys 1-9 join that card, and the
                            // number doubles as the calendar-color dot (contrast-
                            // safe fill for dark calendar colors).
                            ZStack {
                                Circle().fill(Color(nsColor: event.readableNsColorOnBlack))
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 20, height: 20)
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
                                .tint(event.readableColorOnBlack)
                                .controlSize(.large)
                            }
                        }
                        .padding(20)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
                        .frame(maxWidth: 860)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func status(_ event: MeetingEvent) -> String {
        if now < event.start { return "starts in \(Fmt.mmss(event.start.timeIntervalSince(now)))" }
        if now < event.end { return "now" }
        return "finished"
    }
}
