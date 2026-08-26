import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private unowned let store: AppStore
    private unowned let alerts: AlertController
    private let openSettingsHandler: () -> Void
    private var buttonTimer: Timer?

    init(store: AppStore, alerts: AlertController, openSettings: @escaping () -> Void) {
        self.store = store
        self.alerts = alerts
        self.openSettingsHandler = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.minimumWidth = 280
        statusItem.menu = menu
        buttonTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateButton()
        }
        updateButton()
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        if store.isPaused {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: "Paused")
            return
        }
        guard store.settings.showMenuBarCountdown, let next = store.nextEvent else {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "alarm", accessibilityDescription: "now")
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
            for event in upcoming {
                var title = "\(Fmt.time.string(from: event.start))  \(event.title.isEmpty ? "Untitled" : event.title)"
                if event.start <= Date() {
                    title += "  ·  \(Fmt.barCountdown(to: event.start))"
                }
                let item = menu.addItem(withTitle: title, action: event.link == nil ? nil : #selector(joinAction), keyEquivalent: "")
                item.target = self
                item.representedObject = event.link
                item.image = Palette.dotImage(color: event.nsColor)
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
        menu.addItem(withTitle: store.isRefreshing ? "Syncing…" : "Refresh Calendars", action: #selector(refreshAction), keyEquivalent: "").target = self
        if let last = store.lastRefresh {
            menu.addItem(withTitle: "Last synced \(Fmt.ago(last))", action: nil, keyEquivalent: "")
        }
        menu.addItem(withTitle: "Preview Reminder", action: #selector(previewAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",").target = self
        let loginItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLoginAction), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = store.settings.launchAtLogin ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit now", action: #selector(quitAction), keyEquivalent: "q").target = self
    }

    @objc private func joinAction(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
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

    @objc private func toggleLoginAction() {
        store.settings.launchAtLogin.toggle()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
