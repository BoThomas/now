import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private unowned let store: AppStore
    private unowned let alerts: AlertController
    private let openSettingsHandler: () -> Void
    private let quitHandler: () -> Void
    private var buttonTimer: Timer?

    init(store: AppStore, alerts: AlertController, openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.store = store
        self.alerts = alerts
        self.openSettingsHandler = openSettings
        self.quitHandler = quit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.minimumWidth = 280
        statusItem.menu = menu
        // .common mode: the countdown keeps updating while the dropdown is
        // tracking (menu tracking runs a modal-ish run loop in .default mode).
        buttonTimer = AppStore.commonTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateButton() }
        }
        updateButton()
    }

    private func updateButton() {
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

    func menuNeedsUpdate(_ menu: NSMenu) {
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
        return lines.joined(separator: "\n")
    }

    /// True when `text` (trimmed) is exactly the event's join link.
    private static func isJustJoinLink(_ text: String, event: MeetingEvent) -> Bool {
        guard let link = event.link else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == link.absoluteString
    }

    private func eventMenuItem(for event: MeetingEvent, timeFont: NSFont, tabLocation: CGFloat) -> NSMenuItem {
        // No-link events get an enabled, information-only row (a disabled item
        // would wrongly suggest the event itself is unavailable).
        let item = NSMenuItem(title: "", action: event.link == nil ? #selector(informationalAction) : #selector(joinAction), keyEquivalent: "")
        item.target = self
        item.representedObject = event.link
        item.image = Palette.dotImage(color: event.nsColor)
        item.toolTip = Self.tooltipText(for: event)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: tabLocation, options: [:])]
        let timeAttributes: [NSAttributedString.Key: Any] = [.font: timeFont, .paragraphStyle: paragraph]
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph]
        let text = NSMutableAttributedString(string: Fmt.time.string(from: event.start), attributes: timeAttributes)
        text.append(NSAttributedString(string: "\t", attributes: titleAttributes))
        var title = " \(Fmt.ellipsized(event.title.isEmpty ? "Untitled" : event.title, limit: 48))"
        if event.start <= Date() {
            title += "  ·  \(Fmt.barCountdown(to: event.start))"
        }
        text.append(NSAttributedString(string: title, attributes: titleAttributes))
        item.attributedTitle = text
        return item
    }

    @objc private func joinAction(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    /// Enabled no-op for no-link rows: selecting them must not look like a
    /// broken action, but there is nothing to open.
    @objc private func informationalAction() {}

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

    @objc private func toggleLoginAction() {
        store.settings.launchAtLogin.toggle()
    }

    @objc private func quitAction() {
        // Routes through the custom flow (confirm when Settings is key, close
        // a showing alert) — never a bare terminate that would bypass both.
        quitHandler()
    }
}
