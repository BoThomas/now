import SwiftUI
import AppKit

final class AlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AlertController: ObservableObject {
    @Published private(set) var shownEvents: [MeetingEvent] = []
    @Published var snoozeMenuOpen = false
    @Published var highlightedSnooze: SnoozePlan?
    private var panel: AlertPanel?
    private var displayObservers: [NSObjectProtocol] = []
    private var monitor: Any?
    /// Preview alerts (Settings → Preview Reminder) show fabricated events that
    /// are not in the store — reconciliation must not close them.
    private var isPreview = false
    private var previewSettings: AppSettings?
    /// True while a system dialog (e.g. the quit-vs-dismiss confirm) runs above
    /// the panel — the key monitor must let keystrokes through to it.
    var modalAlertActive = false
    /// Set by AppDelegate: flips the app .regular/.accessory. A timer-fired panel
    /// can't take keyboard focus while we're a background .accessory app (macOS
    /// ignores activate() without user interaction) — being .regular is what makes
    /// activation real. Called on present AND close.
    var policyDidChange: (() -> Void)?
    var store: AppStore?

    /// Fresh panels swallow ALL keystrokes for this long after appearing:
    /// the panel steals key focus mid-sentence (see above), and keystrokes
    /// already in flight from whatever the user was typing must never
    /// trigger an action — Return joins a meeting, digits 1-9 join cards,
    /// "s" snoozes, Escape closes. The shortcut-hint row stays hidden until
    /// the guard expires, so its reveal doubles as the "keyboard is live"
    /// signal. Previews arm it too — they must show the real behavior.
    static let keystrokeGuardInterval: TimeInterval = 1.0
    /// True while that window runs. Any click in the panel ends it early.
    @Published private(set) var isGuardingKeystrokes = false
    /// Bumped on every guard start/end — a pending expiry from an older
    /// panel must never disarm a newer one.
    private var keystrokeGuardGeneration = 0

    var isOpen: Bool { panel != nil }

    func present(_ events: [MeetingEvent], playSound: Bool = true, preview: Bool = false) {
        let next = Self.nextPresentation(existing: isOpen ? shownEvents : [], existingIsPreview: isOpen && isPreview,
                                         incoming: events, incomingIsPreview: preview)
        guard next.acceptsDelivery else { return }
        shownEvents = next.events
        isPreview = next.isPreview
        if !isPreview { previewSettings = nil }
        // Real reminders merge with real reminders. A real delivery replaces
        // fabricated preview cards and immediately restores reconciliation.
        if isOpen {
            reconcileSnoozeMenu(options: snoozeOptions(at: Date()))
            if playSound { store?.playSound() }
            return
        }
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
        observeDisplayChanges(for: panel)
        // Arm BEFORE the panel can become key — a keystroke landing in the
        // same instant the panel appears is by definition not aimed at it.
        beginKeystrokeGuard()
        // A timer-fired panel can't take keyboard focus while we're a background
        // .accessory app — macOS ignores activate() without user interaction, and
        // keystrokes would invisibly go to the app hidden behind the overlay (think:
        // typing Enter into a chat you can't see). The delegate flips us to .regular
        // (Dock icon + our menu bar show for the alert's duration) and back on close.
        policyDidChange?()
        panel.makeKeyAndOrderFront(nil)
        AppActivation.activate(forReminder: true)
        installMonitor()
        if playSound {
            store?.playSound()
        }
    }

    nonisolated static func previewEvent(at now: Date, settings: AppSettings = AppSettings()) -> MeetingEvent {
        MeetingEvent(
            uid: "preview",
            title: "Team Sync — Preview",
            start: now.addingTimeInterval(TimeInterval(settings.leadSeconds)),
            end: now.addingTimeInterval(TimeInterval(settings.leadSeconds + max(1800, settings.snoozeSeconds + 60))),
            location: "Zoom",
            notes: nil,
            link: URL(string: "https://zoom.us/j/1234567890"),
            calendarID: UUID(),
            calendarName: "Preview",
            colorIndex: 0
        )
    }

    func presentPreview(settings: AppSettings? = nil) {
        guard !isOpen || isPreview else { return }
        store?.notifications?.cancelMeetingPreview()
        let selected = settings ?? store?.settings ?? AppSettings()
        showPreview([Self.previewEvent(at: Date(), settings: selected)], settings: selected)
    }

    func cancelPreview() {
        if isPreview { close() }
    }

    private func showPreview(_ events: [MeetingEvent], settings: AppSettings) {
        guard !isOpen || isPreview else { return }
        previewSettings = settings
        present(events, playSound: false, preview: true)
        if settings.soundEnabled { NSSound(named: NSSound.Name(settings.soundName))?.play() }
    }

    func close() {
        snoozeMenuOpen = false
        closePanel()
        shownEvents = []
        isPreview = false
        previewSettings = nil
    }

    func snoozeAll() {
        guard let plan = Self.primarySnoozePlan(options: snoozeOptions(at: Date()), defaultSeconds: defaultSnoozeSeconds) else { return }
        applySnooze(plan)
    }

    func snoozeAll(after seconds: Int) {
        applySnooze(.duration(seconds))
    }

    func snoozeAllAtStart() {
        applySnooze(.atStart)
    }

    /// The configured default (0 = just in time; otherwise seconds).
    var defaultSnoozeSeconds: Int { previewSettings?.snoozeSeconds ?? store?.settings.snoozeSeconds ?? 60 }

    private func applySnooze(_ plan: SnoozePlan) {
        let now = Date()
        guard let schedule = Self.snoozeSchedule(plan: plan, events: shownEvents, now: now) else {
            // A meeting may have started/changed since the row was drawn.
            // Keep the reminder open and update the choices instead of losing it.
            reconcileSnoozeMenu(options: snoozeOptions(at: now))
            return
        }
        if isPreview {
            close()
        } else {
            store?.snooze(schedule)
            close()
        }
    }

    func join(_ url: URL) {
        switch Self.joinAction(for: url, shown: shownEvents, isPreview: isPreview) {
        case .ignore: return
        case .dismissPreview: close()
        case .open(let url):
            NSWorkspace.shared.open(url)
            close()
        }
    }

    /// Preview and production deliveries never share a panel's event set.
    nonisolated static func nextPresentation(existing: [MeetingEvent], existingIsPreview: Bool, incoming: [MeetingEvent], incomingIsPreview: Bool) -> (events: [MeetingEvent], isPreview: Bool, acceptsDelivery: Bool) {
        guard !incoming.isEmpty, !(incomingIsPreview && !existingIsPreview && !existing.isEmpty) else {
            return (existing, existingIsPreview, false)
        }
        if existingIsPreview || incomingIsPreview {
            return (AppStore.normalizedEvents(incoming), incomingIsPreview, true)
        }
        return (mergedShown(existing: existing, new: incoming), false, true)
    }

    enum JoinAction: Equatable {
        case ignore, dismissPreview, open(URL)
    }

    nonisolated static func joinAction(for url: URL, shown: [MeetingEvent], isPreview: Bool) -> JoinAction {
        guard shown.contains(where: { $0.link == url }) else { return .ignore }
        return isPreview ? .dismissPreview : .open(url)
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
    /// removed/disabled, occurrence deleted) or became title-muted, and picks up
    /// refreshed copies of changed events. A rescheduled meeting gets a NEW id,
    /// so its old card drops and the new time earns its own reminder when due
    /// again. Pure.
    nonisolated static func reconciledShownEvents(shown: [MeetingEvent], current: [MeetingEvent]) -> [MeetingEvent] {
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return shown.compactMap { byID[$0.id] }.filter { !$0.isMuted }
    }

    /// Called from `AppStore.commitEvents` so an open alert tracks reality.
    func reconcile(withCurrent current: [MeetingEvent]) {
        guard isOpen, !isPreview else { return }
        let next = Self.reconciledShownEvents(shown: shownEvents, current: current)
        if next.isEmpty {
            close()
        } else {
            shownEvents = next
            reconcileSnoozeMenu(options: snoozeOptions(at: Date()))
        }
    }

    private func observeDisplayChanges(for panel: AlertPanel) {
        let center = NotificationCenter.default
        for (name, object) in [
            (NSWindow.didChangeScreenNotification, panel as AnyObject?),
            (NSApplication.didChangeScreenParametersNotification, nil)
        ] {
            displayObservers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self, weak panel] _ in
                // Let AppKit finish moving the window before reading its destination.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let panel, self.panel === panel else { return }
                        let screens = NSScreen.screens
                        let destination = panel.screen.flatMap { current in
                            screens.first { $0 == current }
                        } ?? NSScreen.main ?? screens.first
                        guard let destination else { return }
                        if panel.frame != destination.frame {
                            panel.setFrame(destination.frame, display: true)
                        }
                        panel.contentView?.needsLayout = true
                        panel.contentView?.layoutSubtreeIfNeeded()
                    }
                }
            })
        }
    }

    private func closePanel() {
        displayObservers.forEach { NotificationCenter.default.removeObserver($0) }
        displayObservers.removeAll()
        snoozeMenuOpen = false
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
        Self.primarySnoozePlan(options: snoozeOptions(at: Date()), defaultSeconds: defaultSnoozeSeconds) != nil
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
        let mods = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
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
        case 53: // Only plain Escape dismisses; prevent AppKit fallback too.
            return mods.isEmpty ? .close : .swallow
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

    /// Join decisions are kept separate from key classification so mixed
    /// link/linkless cards have a directly testable keyboard contract.
    nonisolated static func primaryJoinURL(in events: [MeetingEvent]) -> URL? {
        events.compactMap(\.link).first
    }

    nonisolated static func indexedJoinURL(in events: [MeetingEvent], number: Int) -> URL? {
        guard events.indices.contains(number - 1) else { return nil }
        return events[number - 1].link
    }

    // MARK: - Snooze choices

    /// Shared choices must work for every active card. Ended cards do not
    /// constrain the group and are never added to a new snooze schedule.
    struct SnoozeOptions: Equatable {
        var atStartEnabled: Bool
        var enabledDurations: Set<Int>
        var anyEnabled: Bool { atStartEnabled || !enabledDurations.isEmpty }
        var plans: [SnoozePlan] {
            (atStartEnabled ? [.atStart] : []) + enabledDurations.sorted().map { .duration($0) }
        }
    }

    enum SnoozePlan: Equatable {
        case atStart
        case duration(Int)
    }

    nonisolated static func snoozeOptions(events: [MeetingEvent], now: Date, customSeconds: Int = 0) -> SnoozeOptions {
        let active = events.filter { now < $0.end }
        guard !active.isEmpty else { return SnoozeOptions(atStartEnabled: false, enabledDurations: []) }
        let atStart = active.allSatisfy { now < $0.start }
        let durations = Set(AppSettings.snoozeDurations(including: customSeconds).filter { seconds in
            active.allSatisfy { now.addingTimeInterval(TimeInterval(seconds)) < $0.end }
        })
        return SnoozeOptions(atStartEnabled: atStart, enabledDurations: durations)
    }

    func snoozeOptions(at now: Date) -> SnoozeOptions {
        Self.snoozeOptions(events: shownEvents, now: now, customSeconds: defaultSnoozeSeconds)
    }

    /// Validate again at activation time, using the same policy as the UI.
    nonisolated static func snoozeSchedule(plan: SnoozePlan, events: [MeetingEvent], now: Date) -> [String: Date]? {
        let customSeconds: Int
        switch plan {
        case .atStart: customSeconds = 0
        case .duration(let seconds): customSeconds = seconds
        }
        guard snoozeOptions(events: events, now: now, customSeconds: customSeconds).plans.contains(plan) else { return nil }
        return Dictionary(uniqueKeysWithValues: events.filter { now < $0.end }.map { event in
            switch plan {
            case .atStart: return (event.id, event.start)
            case .duration(let seconds): return (event.id, now.addingTimeInterval(TimeInterval(seconds)))
            }
        })
    }

    /// Duration defaults shorten to the longest safe duration; never lengthen.
    /// Just in time remains an alternative when no duration fits before start.
    /// After start, a just-in-time default falls back to the shortest duration.
    nonisolated static func primarySnoozePlan(options: SnoozeOptions, defaultSeconds: Int) -> SnoozePlan? {
        if defaultSeconds == 0 {
            if options.atStartEnabled { return .atStart }
            return options.enabledDurations.min().map { .duration($0) }
        }
        if let seconds = options.enabledDurations.filter({ $0 <= defaultSeconds }).max() {
            return .duration(seconds)
        }
        return options.atStartEnabled ? .atStart : nil
    }

    nonisolated static func snoozeMenuSelection(current: SnoozePlan?, options: SnoozeOptions, defaultSeconds: Int) -> SnoozePlan? {
        if let current, options.plans.contains(current) { return current }
        return primarySnoozePlan(options: options, defaultSeconds: defaultSeconds)
    }

    nonisolated static func movedSnoozeSelection(current: SnoozePlan?, options: SnoozeOptions, direction: Int) -> SnoozePlan? {
        let plans = options.plans
        guard !plans.isEmpty else { return nil }
        guard let current, let index = plans.firstIndex(of: current) else {
            return direction > 0 ? plans.first : plans.last
        }
        return plans[(index + (direction > 0 ? 1 : plans.count - 1)) % plans.count]
    }

    func reconcileSnoozeMenu(options: SnoozeOptions) {
        guard snoozeMenuOpen else { return }
        highlightedSnooze = Self.snoozeMenuSelection(current: highlightedSnooze, options: options, defaultSeconds: defaultSnoozeSeconds)
        if !options.anyEnabled { snoozeMenuOpen = false }
    }

    func toggleSnoozeMenu() {
        let options = snoozeOptions(at: Date())
        highlightedSnooze = Self.primarySnoozePlan(options: options, defaultSeconds: defaultSnoozeSeconds)
        snoozeMenuOpen = !snoozeMenuOpen && options.anyEnabled
    }

    enum SnoozeMenuKeyAction: Equatable {
        case dismiss, activate, dismissAndPassThrough, swallow, passThrough
        case move(Int)
    }

    nonisolated static func snoozeMenuKeyAction(modifiers: NSEvent.ModifierFlags, keyCode: UInt16, characters: String?) -> SnoozeMenuKeyAction {
        // Caps Lock and the hardware flags on arrow/keypad keys are not
        // shortcut modifiers. Command/Option/Control/Shift must be respected.
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        if mods == .command, let key = characters?.lowercased(), key == "w" || key == "m" { return .swallow }
        if keyCode == 53 && !mods.isEmpty { return .swallow }
        if keyCode == 48 && (mods.isEmpty || mods == .shift) { return .dismissAndPassThrough }
        guard mods.isEmpty else { return .passThrough }
        switch keyCode {
        case 53: return .dismiss
        case 125: return .move(1)
        case 126: return .move(-1)
        case 36, 76, 49: return .activate
        default: return .swallow
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
            if self.snoozeMenuOpen {
                let options = self.snoozeOptions(at: Date())
                switch Self.snoozeMenuKeyAction(modifiers: event.modifierFlags, keyCode: event.keyCode, characters: event.charactersIgnoringModifiers) {
                case .dismiss: self.snoozeMenuOpen = false
                case .move(let direction):
                    self.highlightedSnooze = Self.movedSnoozeSelection(current: self.highlightedSnooze, options: options, direction: direction)
                    if !options.anyEnabled { self.snoozeMenuOpen = false }
                case .activate:
                    // Resolve a stale choice before acting, even between UI ticks.
                    if let plan = Self.snoozeMenuSelection(current: self.highlightedSnooze, options: options, defaultSeconds: self.defaultSnoozeSeconds) {
                        self.applySnooze(plan)
                    } else {
                        self.snoozeMenuOpen = false
                    }
                case .dismissAndPassThrough:
                    self.snoozeMenuOpen = false
                    return event
                case .passThrough: return event
                case .swallow: break
                }
                return nil
            }
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
                if let url = Self.primaryJoinURL(in: self.shownEvents) {
                    self.join(url)
                } else {
                    self.close()
                }
                return nil
            case .joinIndex(let number):
                // "3" joins the third card; out of range or link-less events
                // are swallowed quietly.
                if let url = Self.indexedJoinURL(in: self.shownEvents, number: number) {
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
        .overlayPreferenceValue(SnoozeControlAnchor.self) { anchor in
            GeometryReader { geometry in
                if controller.snoozeMenuOpen, let anchor {
                    let bounds = geometry[anchor]
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { controller.snoozeMenuOpen = false }
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        snoozeMenuItems(options: controller.snoozeOptions(at: timeline.date))
                    }
                    .frame(width: 260)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: max(0, bounds.minY - 12), alignment: .bottom)
                    .offset(x: min(bounds.minX, max(0, geometry.size.width - 272)))
                }
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
            footer(events: events, now: now)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(50)
    }

    private func footer(events: [MeetingEvent], now: Date) -> some View {
        // Every active card must re-alert; the label shows the safe fallback.
        let options = controller.snoozeOptions(at: now)
        let plan = AlertController.primarySnoozePlan(options: options, defaultSeconds: controller.defaultSnoozeSeconds)
        let snoozeable = plan != nil
        let joinable = events.contains { $0.link != nil }
        // "esc close" sits last (right edge): Escape is the least likely
        // action, the join/snooze hints lead.
        var hints: [String] = []
        if events.count > 1 {
            if joinable {
                hints.append("return join first available")
                hints.append("numbered cards join")
            } else {
                hints.append("return dismiss")
            }
        } else {
            hints.append(joinable ? "return join" : "return dismiss")
        }
        if snoozeable { hints.append("s snooze") }
        hints.append("esc close")
        if controller.snoozeMenuOpen { hints = ["↑ ↓ choose", "return snooze", "esc back"] }
        return VStack(spacing: 16) {
            HStack(spacing: 8) {
                if let plan {
                    snoozeSplitButton(plan: plan)
                }
                if events.count != 1 || events[0].link != nil {
                    Button {
                        controller.close()
                    } label: {
                        Label("Close", systemImage: "xmark")
                    }
                    .buttonStyle(AlertSecondaryButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
            // Hidden while the keystroke guard runs; its fade-in is the
            // "shortcuts are live" signal (previews guard too, so they show
            // the real reveal).
            Text(hints.joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
                .opacity(controller.isGuardingKeystrokes ? 0 : 1)
                .animation(.easeOut(duration: 0.25), value: controller.isGuardingKeystrokes)
        }
        .padding(.bottom, 10)
        .onChange(of: options) { controller.reconcileSnoozeMenu(options: $0) }
    }

    /// Main snooze button label: the concrete outcome, never a mystery.
    private func snoozeMainLabel(plan: AlertController.SnoozePlan) -> String {
        switch plan {
        case .duration(let seconds):
            return "Snooze \(Fmt.leadTime(seconds))"
        case .atStart:
            return "Just in time"
        }
    }

    /// Snooze split control: ONE capsule — the main segment applies the
    /// primary plan (same as "s"), the attached chevron segment opens the
    /// choice menu. Segment highlights are plain rectangles; the shared
    /// capsule clip keeps them inside the pill (a per-segment Capsule would
    /// draw a pill-inside-the-pill).
    private func snoozeSplitButton(plan: AlertController.SnoozePlan) -> some View {
        HStack(spacing: 0) {
            Button {
                controller.snoozeAll()
            } label: {
                Label(snoozeMainLabel(plan: plan), systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.leading, 16)
                    .padding(.trailing, 10)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SplitSegmentButtonStyle())
            .keyboardShortcut("s", modifiers: [])
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 1, height: 20)
            Button {
                controller.toggleSnoozeMenu()
            } label: {
                Image(systemName: controller.snoozeMenuOpen ? "chevron.down" : "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SplitSegmentButtonStyle())
            .accessibilityLabel(Text("Snooze options"))
        }
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .clipShape(Capsule())
        // The control must stay rigid: the fullscreen footer sits between
        // Spacers, and any height-flexible child (a plain Rectangle divider,
        // a borderless Menu) lets the capsule drink the whole screen height.
        .fixedSize()
        .anchorPreference(key: SnoozeControlAnchor.self, value: .bounds) { $0 }
    }

    private func snoozeMenuItems(options: AlertController.SnoozeOptions) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SNOOZE REMINDER")
                .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 10).padding(.vertical, 8)
            if options.atStartEnabled {
                snoozeMenuRow("Just in time", detail: "At the meeting’s start", plan: .atStart, enabled: true)
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1).padding(.vertical, 3)
            }
            ForEach(AppSettings.snoozeDurations(including: controller.defaultSnoozeSeconds), id: \.self) { seconds in
                snoozeMenuRow(Fmt.leadTime(seconds), plan: .duration(seconds), enabled: options.enabledDurations.contains(seconds))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.12, green: 0.13, blue: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
    }

    private func snoozeMenuRow(_ title: String, detail: String? = nil, plan: AlertController.SnoozePlan, enabled: Bool) -> some View {
        Button {
            switch plan {
            case .atStart: controller.snoozeAllAtStart()
            case .duration(let seconds): controller.snoozeAll(after: seconds)
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
                }
                Spacer()
                if controller.highlightedSnooze == plan {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.3))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(controller.highlightedSnooze == plan && enabled ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering in
            if hovering && enabled { controller.highlightedSnooze = plan }
        }
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
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            HStack(spacing: 20) {
                Label(timeRangeText, systemImage: "clock")
                Label(Fmt.duration(event.end.timeIntervalSince(event.start)), systemImage: "hourglass")
                if let location = LinkExtractor.displayLocation(event.location, link: event.link) {
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
                }
                .buttonStyle(AlertJoinButtonStyle(color: event.alertButtonColor))
            } else {
                VStack(spacing: 12) {
                    Label("No meeting link found", systemImage: "personalhotspot.slash")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                    if let notes = displayNotes {
                        Text(notes)
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.62))
                            .multilineTextAlignment(.center)
                            .lineLimit(5)
                            .frame(maxWidth: 680)
                    }
                    Button {
                        controller.close()
                    } label: {
                        Label("Dismiss Reminder", systemImage: "checkmark")
                    }
                    .buttonStyle(AlertJoinButtonStyle(color: event.alertButtonColor))
                }
            }
        }
    }

    var accent: Color { event.color }
    /// The countdown/prominent controls use a contrast-safe variant so a
    /// user-picked near-black calendar color stays visible on the black panel.
    var readableAccent: Color { event.readableColorOnBlack }

    var displayNotes: String? {
        guard let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty else { return nil }
        return notes
    }

    var statusText: String {
        Fmt.reminderStatus(start: event.start, end: event.end, now: now)
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
            Text("\(events.count) MEETING REMINDERS")
                .font(.system(size: 15, weight: .bold))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.6))
            // Scrollable: on small displays / large accessibility text the last
            // cards and the footer controls must stay reachable.
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        HStack(spacing: 20) {
                            // Joinable cards show their 1-9 shortcut. Linkless
                            // cards use a neutral dot; the trailing label already
                            // explains the missing link without repeating its icon.
                            ZStack {
                                Circle().fill(event.link == nil ? Color.white.opacity(0.28) : Color(nsColor: event.readableNsColorOnBlack))
                                if event.link != nil {
                                    Text("\(index + 1)")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white)
                                }
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
                                .buttonStyle(AlertJoinButtonStyle(color: event.alertButtonColor, compact: true))
                            } else {
                                Label("No link", systemImage: "personalhotspot.slash")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.48))
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
        Fmt.reminderStatus(start: event.start, end: event.end, now: now, includeEndCountdown: false).lowercased()
    }
}

/// The system `.borderedProminent` style changes both fill and label colors
/// with the window's active state and the macOS Light/Dark appearance. A
/// fullscreen alert deliberately remains visible while inactive, so own the
/// complete appearance here instead of allowing a Light-mode inactive button
/// to become black-on-black.
struct AlertJoinButtonStyle: ButtonStyle {
    let color: Color
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 17 : 21, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 16 : 20)
            .padding(.vertical, compact ? 9 : 11)
            .background(
                Capsule().fill(color.opacity(configuration.isPressed ? 0.72 : 1))
            )
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Stable secondary actions for the same reason as `AlertJoinButtonStyle`:
/// native bordered controls fade into the black panel when an inactive alert
/// inherits the system's Light appearance.
struct AlertSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.72 : 1))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10))
            )
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Main segment of the snooze split control: transparent at rest (the shared
/// capsule behind the whole control provides the fill) and a plain rectangle
/// highlight while pressed — the control's capsule clip keeps it inside the
/// pill. Font/padding metrics mirror `AlertSecondaryButtonStyle` so heights
/// match the neighboring Close button.
struct SplitSegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0))
    }
}

private struct SnoozeControlAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
