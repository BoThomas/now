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
                MainActor.assumeIsolated { self?.menuIsTracking = false }
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
        refreshOpenMenuForUpdateState()
        guard let button = statusItem.button else { return }
        if store.isPaused {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: "now — reminders paused")
            button.setAccessibilityLabel("now — reminders paused")
            return
        }
        guard store.settings.showMenuBarCountdown, let next = store.nextEvent else {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "alarm", accessibilityDescription: "now")
            button.setAccessibilityLabel("now — no upcoming meetings")
            return
        }
        button.image = nil
        let textFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let dotSize: CGFloat = 7
        let attachment = NSTextAttachment()
        attachment.image = Palette.dotImage(color: next.nsColor, size: dotSize)
        attachment.bounds = CGRect(x: 0, y: textFont.capHeight / 2 - dotSize / 2, width: dotSize, height: dotSize)
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: " \(Fmt.barCountdown(to: next.start))", attributes: [
            .font: textFont,
            .foregroundColor: NSColor.labelColor
        ]))
        button.attributedTitle = text
        let running = next.start <= Date()
        button.setAccessibilityLabel(running
            ? "now — \(next.title) is running, started \(Fmt.ago(next.start))"
            : "now — next meeting \(next.title) at \(Fmt.time.string(from: next.start)), in \(Fmt.mmss(next.start.timeIntervalSince(Date())))")
    }

    /// Rebuild the currently-tracking menu when updater state changed — the
    /// "Update to vX…" item must appear (or the "Checking…" state clear)
    /// without the user closing and reopening the dropdown.
    private func refreshOpenMenuForUpdateState() {
        let signature = "\(updates.available?.version ?? "")|\(updates.stagedVersion ?? "")|\(updates.isChecking)"
        guard menuIsTracking, signature != lastUpdateSignature else {
            lastUpdateSignature = signature
            return
        }
        lastUpdateSignature = signature
        if let menu = statusItem.menu {
            menuNeedsUpdate(menu)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        lastUpdateSignature = "\(updates.available?.version ?? "")|\(updates.stagedVersion ?? "")|\(updates.isChecking)"
        menu.removeAllItems()
        let upcoming = Array(store.upcoming.prefix(5))
        if store.isPaused {
            let until = store.pausedUntil == Date.distantFuture ? "indefinitely" : "until \(Fmt.time.string(from: store.pausedUntil ?? Date()))"
            menu.addItem(withTitle: "Reminders paused \(until)", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Resume Now", action: #selector(resumeAction), keyEquivalent: "").target = self
        } else if upcoming.isEmpty {
            menu.addItem(withTitle: store.events.isEmpty ? "No calendars loaded" : "No upcoming events", action: nil, keyEquivalent: "")
        } else {
            let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            let measure: [NSAttributedString.Key: Any] = [.font: timeFont]
            let timeWidth = upcoming.map { (Fmt.time.string(from: $0.start) as NSString).size(withAttributes: measure).width }.max() ?? 0
            let tabLocation = timeWidth.rounded(.up) + 4
            var currentDay: Date?
            for event in upcoming {
                let day = Calendar.current.startOfDay(for: event.start)
                if currentDay != day {
                    currentDay = day
                    menu.addItem(dayHeaderItem(for: day))
                }
                menu.addItem(eventMenuItem(for: event, timeFont: timeFont, tabLocation: tabLocation))
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

    private func dayHeaderItem(for day: Date) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: Fmt.dayHeader(for: day), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        return item
    }

    /// Multi-line hover tooltip: title, when, location, notes. Values that are nothing
    /// but the join link (or Apple's `----( Video Call )----` wrapper around it) are
    /// suppressed (redundant — clicking the row opens it).
    private static func tooltipText(for event: MeetingEvent) -> String {
        var lines: [String] = []
        lines.append(event.title.isEmpty ? "Untitled" : event.title)
        let calendar = Calendar.current
        let dateText = calendar.isDateInToday(event.start) ? "" : event.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " · "
        lines.append("\(dateText)\(Fmt.time.string(from: event.start)) – \(Fmt.time.string(from: event.end)) · \(Fmt.duration(event.end.timeIntervalSince(event.start)))")
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

    private func eventMenuItem(for event: MeetingEvent, timeFont: NSFont, tabLocation: CGFloat) -> NSMenuItem {
        // Linkless events stay enabled: selecting one opens its useful event
        // details rather than pretending to be a Join action or doing nothing.
        let item = NSMenuItem(title: "", action: event.link == nil ? #selector(showEventDetailsAction) : #selector(joinAction), keyEquivalent: "")
        item.target = self
        item.representedObject = event
        // Muted rows keep their calendar dot, faded. The title itself keeps its
        // NATIVE color — explicit foreground colors break menu selection
        // highlighting (hard-won constraint); muting is signaled by the dot plus
        // compact trailing state icons.
        item.image = Palette.dotImage(color: event.isMuted ? event.nsColor.withAlphaComponent(0.35) : event.nsColor)
        item.toolTip = Self.tooltipText(for: event)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: tabLocation, options: [:])]
        let timeAttributes: [NSAttributedString.Key: Any] = [.font: timeFont, .paragraphStyle: paragraph]
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph]
        let text = NSMutableAttributedString(string: Fmt.time.string(from: event.start), attributes: timeAttributes)
        text.append(NSAttributedString(string: "\t", attributes: titleAttributes))
        let title = " \(Fmt.ellipsized(event.title.isEmpty ? "Untitled" : event.title, limit: 48))"
        text.append(NSAttributedString(string: title, attributes: titleAttributes))
        if event.start <= Date() {
            text.append(NSAttributedString(string: "  \(Fmt.barCountdown(to: event.start))", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]))
        }
        var accessibilityLabel = event.title.isEmpty ? "Untitled" : event.title
        if event.isMuted {
            let attachment = NSTextAttachment()
            if let image = NSImage(systemSymbolName: "bell.slash", accessibilityDescription: "Reminders muted") {
                image.isTemplate = true
                attachment.image = image
                // y = -1 centers the 11pt box on the 13pt menu font's cap height
                // (y = -2 sat visibly low — bell glyphs carry their mass low).
                attachment.bounds = CGRect(x: 0, y: -1, width: 11, height: 11)
                text.append(NSAttributedString(string: "  ", attributes: titleAttributes))
                text.append(NSAttributedString(attachment: attachment))
            }
            accessibilityLabel += ", reminders muted"
        }
        if event.link == nil {
            text.append(NSAttributedString(string: "  ", attributes: titleAttributes))
            let attachment = NSTextAttachment()
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            if let base = NSImage(systemSymbolName: "personalhotspot.slash", accessibilityDescription: "No meeting link"),
               let image = base.withSymbolConfiguration(configuration) {
                image.isTemplate = true
                attachment.image = image
                attachment.bounds = CGRect(x: 0, y: -1, width: 12, height: 12)
                text.append(NSAttributedString(attachment: attachment))
            }
            accessibilityLabel += ", no meeting link"
        }
        if event.isMuted || event.link == nil {
            item.setAccessibilityLabel(accessibilityLabel)
        }
        item.attributedTitle = text
        return item
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
