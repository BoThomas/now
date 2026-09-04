import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private unowned let store: AppStore
    private unowned let alerts: AlertController
    private unowned let updates: UpdateController
    private let openSettingsHandler: () -> Void
    private let quitHandler: () -> Void
    private var buttonTimer: Timer?
    /// While the dropdown is tracking, updater state changes (a check
    /// finishing, an update appearing) rebuild the OPEN menu in place —
    /// `menuNeedsUpdate` alone only fires on the next open.
    private var menuIsTracking = false
    private var lastUpdateSignature = ""
    /// Structural changes (start/end boundaries, refreshes, midnight) rebuild
    /// the open menu; ordinary second ticks update row titles in place so the
    /// current hover/selection is not disturbed.
    private var lastMenuStructureSignature = ""
    private var trackingObservers: [Any] = []
    private var eventPopover: NSPopover?

    init(store: AppStore, alerts: AlertController, updates: UpdateController, openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.store = store
        self.alerts = alerts
        self.updates = updates
        self.openSettingsHandler = openSettings
        self.quitHandler = quit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.minimumWidth = 280
        statusItem.menu = menu
        trackingObservers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: menu, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuIsTracking = true }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: menu, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.menuIsTracking = false
                    if let trackedMenu = self?.statusItem.menu {
                        self?.clearEventTooltips(in: trackedMenu)
                    }
                }
            },
        ]
        // .common mode: the countdown keeps updating while the dropdown is
        // tracking (menu tracking runs a modal-ish run loop in .default mode).
        buttonTimer = AppStore.commonTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateButton() }
        }
        updateButton()
    }

    deinit {
        for observer in trackingObservers { NotificationCenter.default.removeObserver(observer) }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let now = Date()
        refreshOpenMenu(now: now)
        if store.isPaused {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: "now — reminders paused")
            button.setAccessibilityLabel("now — reminders paused")
            button.toolTip = "now — reminders paused"
            return
        }
        guard store.settings.showMenuBarCountdown,
              let focus = AppStore.menuBarFocus(events: store.events, lateMinutes: store.settings.lateMinutes, now: now) else {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "alarm", accessibilityDescription: "now")
            button.setAccessibilityLabel("now — no upcoming meetings")
            button.toolTip = "now — no current or upcoming meetings"
            return
        }
        button.image = nil
        let textFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let dotSize: CGFloat = 7
        let attachment = NSTextAttachment()
        let dots = Palette.dotClusterImage(colors: focus.events.map(\.nsColor), size: dotSize)
        attachment.image = dots
        attachment.bounds = CGRect(x: 0, y: textFont.capHeight / 2 - dotSize / 2, width: dots.size.width, height: dotSize)
        let text = NSMutableAttributedString(attachment: attachment)
        let countdown: String
        switch focus.kind {
        case .start:
            countdown = Fmt.barCountdown(to: focus.date, relativeTo: now)
        case .end:
            countdown = "ends \(Fmt.barCountdown(to: focus.date, relativeTo: now))"
        }
        text.append(NSAttributedString(string: " \(countdown)", attributes: [
            .font: textFont,
            .foregroundColor: NSColor.labelColor
        ]))
        button.attributedTitle = text
        button.setAccessibilityLabel(Self.accessibilityLabel(for: focus, now: now))
        button.toolTip = Self.statusTooltip(events: store.events, now: now)
    }

    nonisolated static func accessibilityLabel(for focus: MenuBarFocus, now: Date) -> String {
        let names = focus.events.map { $0.title.isEmpty ? "Untitled" : $0.title }.joined(separator: ", ")
        let subject = focus.events.count == 1 ? names : "\(focus.events.count) meetings: \(names)"
        switch focus.kind {
        case .start where focus.date <= now:
            if focus.date == now { return "now — \(subject), starting now" }
            return "now — \(subject), started \(Fmt.mmss(now.timeIntervalSince(focus.date))) ago"
        case .start:
            return "now — \(subject), starts in \(Fmt.mmss(focus.date.timeIntervalSince(now)))"
        case .end:
            return "now — \(subject), ends in \(Fmt.mmss(focus.date.timeIntervalSince(now)))"
        }
    }

    /// Hover context stays concise but exposes both useful clocks without
    /// widening the status item: every running meeting's end and the next
    /// unmuted start (including simultaneous starts).
    nonisolated static func statusTooltip(events: [MeetingEvent], now: Date) -> String {
        let eligible = events.filter { !$0.isMuted }
        let running = eligible
            .filter { $0.start <= now && now < $0.end }
            .sorted { ($0.end, $0.start, $0.title, $0.id) < ($1.end, $1.start, $1.title, $1.id) }
        let future = eligible
            .filter { $0.start > now }
            .sorted { ($0.start, $0.title, $0.id) < ($1.start, $1.title, $1.id) }
        var lines = running.prefix(3).map { event in
            "Now: \(event.title.isEmpty ? "Untitled" : event.title) — ends in \(Fmt.barCountdown(to: event.end, relativeTo: now))"
        }
        if let nextStart = future.first?.start {
            let next = future.filter { $0.start == nextStart }
            lines.append(contentsOf: next.prefix(3).map { event in
                "Next: \(event.title.isEmpty ? "Untitled" : event.title) — starts in \(Fmt.barCountdown(to: event.start, relativeTo: now))"
            })
        }
        return lines.isEmpty ? "now — no current or upcoming meetings" : lines.joined(separator: "\n")
    }

    /// Keep an open native menu live. Rebuilding it every second causes hover
    /// and keyboard selection to jump, so countdown-only ticks mutate the
    /// existing event items; structural or updater changes still rebuild.
    private func refreshOpenMenu(now: Date) {
        guard menuIsTracking, let menu = statusItem.menu else { return }
        let updateSignature = currentUpdateSignature
        let structureSignature = menuStructureSignature(at: now)
        if updateSignature != lastUpdateSignature || structureSignature != lastMenuStructureSignature {
            menuNeedsUpdate(menu)
            return
        }

        let eventItems = menu.items.compactMap { item -> (NSMenuItem, MeetingEvent)? in
            guard let event = item.representedObject as? MeetingEvent else { return nil }
            return (item, event)
        }
        guard !eventItems.isEmpty else { return }
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let measure: [NSAttributedString.Key: Any] = [.font: timeFont]
        let timeWidth = eventItems.map { (Fmt.time.string(from: $0.1.start) as NSString).size(withAttributes: measure).width }.max() ?? 0
        for (item, event) in eventItems {
            updateEventMenuItem(
                item,
                for: event,
                now: now,
                timeFont: timeFont,
                timeWidth: timeWidth,
                includeTooltip: item.isHighlighted
            )
        }
    }

    /// Native menu-item help tags can otherwise remain active after the
    /// pointer leaves the dropdown and cover the status-button help tag. Keep
    /// a help tag only on the row AppKit is actively highlighting.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        clearEventTooltips(in: menu)
        guard let item, let event = item.representedObject as? MeetingEvent else { return }
        item.toolTip = Self.tooltipText(for: event, now: Date())
    }

    private func clearEventTooltips(in menu: NSMenu) {
        for item in menu.items where item.representedObject is MeetingEvent {
            item.toolTip = nil
        }
    }

    private var currentUpdateSignature: String {
        "\(updates.available?.version ?? "")|\(updates.stagedVersion ?? "")|\(updates.isChecking)"
    }

    private func menuStructureSignature(at now: Date) -> String {
        let day = Calendar.current.startOfDay(for: now).timeIntervalSinceReferenceDate
        let eventStates = store.events.compactMap { event -> String? in
            guard AppStore.isVisible(event, at: now) else { return nil }
            let state = event.start <= now && now < event.end ? "now" : "future"
            // `representedObject` stores a value-type snapshot. Include every
            // field that affects row rendering, actions, or help text so a
            // refresh cannot leave the open menu displaying stale event data.
            let fields = [
                event.id,
                state,
                String(event.start.timeIntervalSinceReferenceDate),
                String(event.end.timeIntervalSinceReferenceDate),
                event.title,
                event.calendarName,
                event.colorHex,
                String(event.isMuted),
                event.link?.absoluteString ?? "",
                event.location ?? "",
                event.notes ?? "",
            ]
            return fields.map { "\($0.utf8.count):\($0)" }.joined()
        }.joined(separator: "|")
        return "\(store.isPaused)|\(day)|\(eventStates)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let now = Date()
        lastUpdateSignature = currentUpdateSignature
        lastMenuStructureSignature = menuStructureSignature(at: now)
        menu.removeAllItems()
        let visible = store.events.filter { AppStore.isVisible($0, at: now) }
        if store.isPaused {
            let until = store.pausedUntil == Date.distantFuture ? "indefinitely" : "until \(Fmt.time.string(from: store.pausedUntil ?? Date()))"
            menu.addItem(withTitle: "Reminders paused \(until)", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Resume Now", action: #selector(resumeAction), keyEquivalent: "").target = self
        } else if visible.isEmpty {
            menu.addItem(withTitle: store.events.isEmpty ? "No calendars loaded" : "No upcoming events", action: nil, keyEquivalent: "")
        } else {
            let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            let measure: [NSAttributedString.Key: Any] = [.font: timeFont]
            let timeWidth = visible.map { (Fmt.time.string(from: $0.start) as NSString).size(withAttributes: measure).width }.max() ?? 0
            let running = visible.filter { $0.start <= now && now < $0.end }
            let future = visible.filter { $0.start > now }
            var remainingSlots = 5

            func addSection(_ title: String, events: [MeetingEvent]) {
                let shown = Array(events.prefix(remainingSlots))
                guard !shown.isEmpty else { return }
                menu.addItem(sectionHeaderItem(title))
                for event in shown {
                    menu.addItem(eventMenuItem(for: event, now: now, timeFont: timeFont, timeWidth: timeWidth))
                }
                remainingSlots -= shown.count
            }

            addSection("NOW", events: running)

            var later: ArraySlice<MeetingEvent> = future[future.startIndex...]
            if let nextStart = future.first?.start {
                let nextCount = future.prefix { $0.start == nextStart }.count
                addSection(nextHeader(for: nextStart), events: Array(future.prefix(nextCount)))
                later = future.dropFirst(nextCount)
            }

            var currentLaterDay: Date?
            for event in later where remainingSlots > 0 {
                let day = Calendar.current.startOfDay(for: event.start)
                if currentLaterDay != day {
                    currentLaterDay = day
                    menu.addItem(sectionHeaderItem(laterHeader(for: day)))
                }
                menu.addItem(eventMenuItem(for: event, now: now, timeFont: timeFont, timeWidth: timeWidth))
                remainingSlots -= 1
            }
        }
        menu.addItem(.separator())
        if !store.isPaused {
            let pauseItem = menu.addItem(withTitle: "Pause Reminders", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let options: [(String, Int)] = [("For 1 hour", 1), ("For 3 hours", 2), ("Until tomorrow 9:00", 3), ("Indefinitely", 4)]
            for (label, tag) in options {
                let item = NSMenuItem(title: label, action: #selector(pauseAction), keyEquivalent: "")
                item.target = self
                item.tag = tag
                submenu.addItem(item)
            }
            pauseItem.submenu = submenu
        }
        let refreshItem = menu.addItem(withTitle: store.isRefreshing ? "Syncing…" : "Refresh Calendars", action: #selector(refreshAction), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.keyEquivalentModifierMask = .command
        // No queuing a second full refresh behind the running one.
        refreshItem.isEnabled = !store.isRefreshing
        if let last = store.lastRefresh {
            menu.addItem(withTitle: "Last synced \(Fmt.ago(last))", action: nil, keyEquivalent: "")
        }
        menu.addItem(withTitle: "Preview Reminder", action: #selector(previewAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",").target = self
        // One slot: "Update to vX…" REPLACES "Check for Updates…" while an
        // update is known-available. The menu bar itself stays meeting-only.
        if let manifest = updates.available {
            let updateItem = menu.addItem(withTitle: "Update to v\(manifest.version)…", action: #selector(updateAction), keyEquivalent: "")
            updateItem.target = self
            updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        } else {
            // A manual check always answers with the window (clicking this
            // dismisses the menu, so a transient title is never the feedback).
            let checkItem = menu.addItem(withTitle: updates.isChecking ? "Checking…" : "Check for Updates…", action: #selector(checkUpdateAction), keyEquivalent: "")
            checkItem.target = self
            checkItem.isEnabled = !updates.isChecking
        }
        let loginItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLoginAction), keyEquivalent: "")
        loginItem.target = self
        // Reflect the ACTUAL registration state, not just persisted intent.
        loginItem.state = store.loginItemState == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit now", action: #selector(quitAction), keyEquivalent: "q").target = self
    }

    private func sectionHeaderItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        return item
    }

    private func laterHeader(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "LATER TODAY" }
        if calendar.isDateInTomorrow(day) { return "LATER TOMORROW" }
        return "LATER \(Fmt.dayHeader(for: day))"
    }

    private func nextHeader(for start: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(start) { return "NEXT" }
        if calendar.isDateInTomorrow(start) { return "NEXT · TOMORROW" }
        return "NEXT · \(Fmt.dayHeader(for: start))"
    }

    /// Multi-line hover tooltip: title, when, location, notes. Values that are nothing
    /// but the join link (or Apple's `----( Video Call )----` wrapper around it) are
    /// suppressed (redundant — clicking the row opens it).
    private static func tooltipText(for event: MeetingEvent, now: Date) -> String {
        var lines: [String] = []
        lines.append(event.title.isEmpty ? "Untitled" : event.title)
        let calendar = Calendar.current
        let dateText = calendar.isDateInToday(event.start) ? "" : event.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " · "
        lines.append("\(dateText)\(Fmt.time.string(from: event.start)) – \(Fmt.time.string(from: event.end)) · \(Fmt.duration(event.end.timeIntervalSince(event.start)))")
        if now < event.start {
            lines.append("Starts in \(Fmt.barCountdown(to: event.start, relativeTo: now))")
        } else if now < event.end {
            let delta = Fmt.barCountdown(to: event.start, relativeTo: now)
            let started = delta == "now" ? "just now" : "\(delta.dropFirst()) ago"
            lines.append("Running · started \(started) · ends in \(Fmt.barCountdown(to: event.end, relativeTo: now))")
        }
        if let location = event.location, !location.isEmpty, !isJustJoinLink(location, event: event) {
            lines.append("Location: \(Fmt.ellipsized(location, limit: 100))")
        }
        if let notes = event.notes, !notes.isEmpty, !isJustJoinLink(notes, event: event), !LinkExtractor.isJoinLinkOnlyText(notes, link: event.link) {
            lines.append("Notes: \(Fmt.wrapped(notes, width: 72, maxLines: 4))")
        }
        if event.isMuted {
            lines.append("Reminders muted (title filter)")
        }
        return lines.joined(separator: "\n")
    }

    /// True when `text` (trimmed) is exactly the event's join link.
    private static func isJustJoinLink(_ text: String, event: MeetingEvent) -> Bool {
        guard let link = event.link else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == link.absoluteString
    }

    nonisolated static func menuStatusText(for event: MeetingEvent, lateMinutes: Int, now: Date) -> String {
        if now < event.start {
            guard Calendar.current.isDate(event.start, inSameDayAs: now) else { return "" }
            return "in \(Fmt.barCountdown(to: event.start, relativeTo: now))"
        }
        guard now < event.end else { return "" }
        if AppStore.isWithinStartedCountdownWindow(event, lateMinutes: lateMinutes, now: now) {
            return "\(Fmt.barCountdown(to: event.start, relativeTo: now)) · ends \(Fmt.time.string(from: event.end))"
        }
        return "\(Fmt.barCountdown(to: event.end, relativeTo: now)) left"
    }

    private func eventMenuItem(for event: MeetingEvent, now: Date, timeFont: NSFont, timeWidth: CGFloat) -> NSMenuItem {
        // Linkless events stay enabled: selecting one opens its useful event
        // details rather than pretending to be a Join action or doing nothing.
        let item = NSMenuItem(title: "", action: event.link == nil ? #selector(showEventDetailsAction) : #selector(joinAction), keyEquivalent: "")
        item.target = self
        item.representedObject = event
        updateEventMenuItem(item, for: event, now: now, timeFont: timeFont, timeWidth: timeWidth, includeTooltip: false)
        return item
    }

    private func updateEventMenuItem(
        _ item: NSMenuItem,
        for event: MeetingEvent,
        now: Date,
        timeFont: NSFont,
        timeWidth: CGFloat,
        includeTooltip: Bool
    ) {
        // Muted rows keep their calendar dot, faded. The title itself keeps its
        // NATIVE color — explicit foreground colors break menu selection
        // highlighting (hard-won constraint). State symbols follow the title
        // so ordinary rows do not pay for a permanently reserved icon column.
        item.image = Palette.dotImage(color: event.isMuted ? event.nsColor.withAlphaComponent(0.35) : event.nsColor)
        item.toolTip = includeTooltip ? Self.tooltipText(for: event, now: now) : nil
        let paragraph = NSMutableParagraphStyle()
        let timeRightEdge = timeWidth.rounded(.up)
        paragraph.tabStops = [
            NSTextTab(textAlignment: .right, location: timeRightEdge, options: [:]),
            NSTextTab(textAlignment: .left, location: timeRightEdge + 8, options: [:]),
        ]
        let timeAttributes: [NSAttributedString.Key: Any] = [.font: timeFont, .paragraphStyle: paragraph]
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph]
        let iconAttributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]
        let text = NSMutableAttributedString()

        func appendIcon(_ name: String, description: String, size: CGFloat) {
            let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: description),
                  let image = base.withSymbolConfiguration(configuration) else { return }
            text.append(NSAttributedString(string: " ", attributes: iconAttributes))
            image.isTemplate = true
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -1, width: size, height: size)
            text.append(NSAttributedString(attachment: attachment))
        }

        text.append(NSAttributedString(string: "\t", attributes: iconAttributes))
        text.append(NSAttributedString(string: Fmt.time.string(from: event.start), attributes: timeAttributes))
        text.append(NSAttributedString(string: "\t", attributes: titleAttributes))
        let title = " \(Fmt.ellipsized(event.title.isEmpty ? "Untitled" : event.title, limit: 48))"
        text.append(NSAttributedString(string: title, attributes: titleAttributes))
        if event.isMuted {
            appendIcon("bell.slash", description: "Reminders muted", size: 11)
        }
        if event.link == nil {
            appendIcon("personalhotspot.slash", description: "No meeting link", size: 12)
        }
        let status = Self.menuStatusText(for: event, lateMinutes: store.settings.lateMinutes, now: now)
        if !status.isEmpty {
            text.append(NSAttributedString(string: "  \(status)", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]))
        }
        var accessibilityParts = [event.title.isEmpty ? "Untitled" : event.title, Fmt.time.string(from: event.start)]
        if !status.isEmpty { accessibilityParts.append(status) }
        if event.isMuted { accessibilityParts.append("reminders muted") }
        if event.link == nil { accessibilityParts.append("no meeting link") }
        item.setAccessibilityLabel(accessibilityParts.joined(separator: ", "))
        item.attributedTitle = text
    }

    @objc private func joinAction(_ sender: NSMenuItem) {
        if let event = sender.representedObject as? MeetingEvent, let url = event.link {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showEventDetailsAction(_ sender: NSMenuItem) {
        guard let event = sender.representedObject as? MeetingEvent else { return }
        // Let menu tracking finish before anchoring a transient popover to the
        // status item; presenting it synchronously is immediately dismissed by
        // the click that selected the menu item.
        DispatchQueue.main.async { [weak self] in self?.showEventDetails(event) }
    }

    private func showEventDetails(_ event: MeetingEvent) {
        guard let button = statusItem.button else { return }
        eventPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 280)
        popover.contentViewController = NSHostingController(rootView: LinklessEventPopover(
            event: event,
            copyText: Self.eventDetailsText(for: event),
            close: { [weak self] in self?.eventPopover?.close() }
        ))
        eventPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Status-menu selection does not necessarily activate an accessory app.
        // Make the details popover key so its controls are immediately live and
        // it does not require a throwaway first click merely to activate.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    nonisolated static func eventDetailsText(for event: MeetingEvent) -> String {
        var lines = [
            event.title.isEmpty ? "Untitled event" : event.title,
            "\(event.start.formatted(date: .abbreviated, time: .shortened)) – \(Fmt.time.string(from: event.end))",
            "Calendar: \(event.calendarName)",
        ]
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            lines.append("Location: \(location)")
        }
        if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines.append("Notes: \(notes)")
        }
        return lines.joined(separator: "\n")
    }

    @objc private func pauseAction(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: store.pause(for: 3600)
        case 2: store.pause(for: 3 * 3600)
        case 3: store.pauseUntilMorning()
        case 4: store.pauseIndefinitely()
        default: break
        }
    }

    @objc private func resumeAction() {
        store.resume()
    }

    @objc private func refreshAction() {
        store.refresh()
    }

    @objc private func previewAction() {
        alerts.presentPreview()
    }

    @objc private func settingsAction() {
        openSettingsHandler()
    }

    @objc private func updateAction() {
        updates.presentAvailableFromMenu()
    }

    @objc private func checkUpdateAction() {
        updates.check(userInitiated: true)
    }

    @objc private func toggleLoginAction() {
        store.settings.launchAtLogin.toggle()
    }

    @objc private func quitAction() {
        // Routes through the custom flow (confirm when Settings is key, close
        // a showing alert) — never a bare terminate that would bypass both.
        quitHandler()
    }
}

private struct LinklessEventPopover: View {
    let event: MeetingEvent
    let copyText: String
    let close: () -> Void

    private var location: String? {
        guard let value = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private var notes: String? {
        guard let value = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private var mapsURL: URL? {
        guard let location, URL(string: location)?.scheme == nil else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: location)]
        return components?.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(event.color).frame(width: 9, height: 9).padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title.isEmpty ? "Untitled event" : event.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                    Text(event.calendarName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Image(systemName: "personalhotspot.slash")
                    .frame(width: 14)
                Text("No meeting link found")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .frame(width: 14)
                Text("\(event.start.formatted(date: .abbreviated, time: .shortened)) – \(Fmt.time.string(from: event.end))")
            }
            .font(.system(size: 12))
            if let location {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .frame(width: 14)
                    Text(location)
                        .lineLimit(2)
                }
                .font(.system(size: 12))
            }
            if let notes {
                Text(notes)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText, forType: .string)
                }
                if let mapsURL {
                    Button("Open in Maps") { NSWorkspace.shared.open(mapsURL) }
                }
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(minWidth: 360, maxWidth: 360, minHeight: 240, maxHeight: 360)
    }
}
