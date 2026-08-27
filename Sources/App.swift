import SwiftUI
import AppKit
import EventKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()
    let alertController = AlertController()
    private var menuBarController: MenuBarController?
    private var settingsWindow: NSWindow?
    private var wakeObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.type == .keyDown,
               event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "q",
               !event.modifierFlags.contains(.shift) {
                self.handleQuitRequest()
                return nil
            }
            return event
        }
        store.alertController = alertController
        alertController.store = store
        alertController.policyDidChange = { [weak self] in
            self?.syncActivationPolicy()
        }
        store.onAlert = { [weak alertController] events in
            alertController?.present(events)
        }
        menuBarController = MenuBarController(store: store, alerts: alertController) { [weak self] in
            self?.openSettings()
        }
        wakeObserver = NotificationCenter.default.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.store.refresh()
        }
        store.start()
        if store.subscriptions.isEmpty && !store.nativeCalendars.contains(where: \.isEnabled) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openSettings()
            }
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // "now" app menu — Quit goes through the custom flow (confirm / close alert),
        // same as the ⌘Q local monitor, which still takes precedence for the key combo.
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "now")
        appMenu.addItem(withTitle: "Quit now", action: #selector(handleQuitRequest), keyEquivalent: "q").target = self
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window menu — ⌘W/⌘M are menu key equivalents (not built-in window behaviors),
        // so Settings needs these items for close/minimize to work. The alert's monitor
        // swallows both silently while the fullscreen reminder is showing.
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// Shared quit behavior for ⌘Q and the "Quit now" menu item: confirm while
    /// Settings is key, dismiss a showing alert, otherwise terminate.
    @objc private func handleQuitRequest() {
        if let window = NSApp.keyWindow, window === settingsWindow {
            handleQuitFromSettings()
        } else if alertController.isOpen {
            alertController.close()
        } else {
            NSApp.terminate(nil)
        }
    }

    private func handleQuitFromSettings() {
        let alert = NSAlert()
        alert.messageText = "Quit now?"
        alert.informativeText = "Reminders will stop until you launch the app again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit now")
        alert.addButton(withTitle: "Close Settings")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSApp.terminate(nil)
        case .alertSecondButtonReturn:
            settingsWindow?.close()
        default:
            break
        }
    }

    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 720), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "now · Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView().environmentObject(store).environmentObject(alertController))
            window.center()
            window.delegate = self
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        // Being .regular is what actually puts our menus in the menu bar — an
        // .accessory app activating with a window often keeps the previous app's
        // menu bar on screen. syncActivationPolicy also runs when the window closes
        // (windowWillClose) to hand the menu bar back.
        syncActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The app is .regular (Dock icon + owns the menu bar) while Settings or the
    /// fullscreen alert is visible, .accessory otherwise (menu-bar-only). Called
    /// whenever either appears/disappears — never set the policy anywhere else.
    private func syncActivationPolicy() {
        let wantRegular = (settingsWindow?.isVisible ?? false) || alertController.isOpen
        let current = NSApp.activationPolicy()
        if wantRegular, current == .accessory {
            NSApp.setActivationPolicy(.regular)
        } else if !wantRegular, current == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        syncActivationPolicy()
    }
}

@main
enum NowApp {
    static let appDelegate = AppDelegate()

    static func main() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--selftest") {
            SelfTest.run()
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--parse"), index + 1 < arguments.count {
            parseCLI(arguments[index + 1])
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--native") {
            let subcommand = arguments.count > index + 1 ? arguments[index + 1] : nil
            nativeCLI(subcommand)
            exit(0)
        }
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// EventKit counterpart of `--parse`: prints authorization status, every EKCalendar,
    /// and exactly which events a fetch would keep in the −6h…+14d window.
    /// Note: permission granted from a terminal run is attributed to the terminal app —
    /// for real testing launch now.app and grant there.
    static func nativeCLI(_ subcommand: String?) {
        let source = NativeCalendarSource()
        let status = source.authorizationStatus()
        print("NOTE: permission requested here is attributed to your terminal app —")
        print("      launch now.app normally for the app's own Calendar permission.")
        print("AUTHORIZATION: \(describeNativeStatus(status))")
        var authorized = status == .authorized
        if !authorized, status == .notDetermined {
            print("REQUESTING ACCESS… (answer the system prompt)")
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            Task {
                granted = await source.requestAccess()
                semaphore.signal()
            }
            // Service the main run loop while waiting instead of a bare wait(): the
            // macOS 13 legacy request path may deliver its completion on the main
            // queue, which a blocking wait would deadlock (the 14+ async path never
            // needs the main thread, so this is belt-and-braces).
            while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            authorized = granted
            print("ACCESS: \(granted ? "granted" : "not granted")")
        }
        guard authorized else {
            print("No calendar access — enable it in System Settings → Privacy & Security → Calendars.")
            return
        }
        let infos = source.availableCalendarInfos()
        print("CALENDARS (\(infos.count)):")
        for info in infos {
            print("  \(info.ekIdentifier.prefix(12))…  \(info.sourceTitle.isEmpty ? "-" : info.sourceTitle) / \(info.title)  \(info.colorHex)")
        }
        guard subcommand != "list" else { return }
        let now = Date()
        let formatter = ISO8601DateFormatter()
        print("WINDOW \(formatter.string(from: now.addingTimeInterval(-6 * 3600))) … \(formatter.string(from: now.addingTimeInterval(14 * 86400)))")
        var kept = 0
        for info in infos {
            let native = NativeCalendar(ekIdentifier: info.ekIdentifier, name: info.title, colorHex: info.colorHex, colorIndex: 0)
            let events = source.fetchEvents(calendars: [native], skipDeclined: true, now: now)
            print("CALENDAR \(info.title): keeping \(events.count)")
            for event in events {
                kept += 1
                print("  \(formatter.string(from: event.start)) → \(Fmt.time.string(from: event.end)) | \(event.title) | \(event.link?.absoluteString ?? "no link")")
            }
        }
        print("PARSED \(kept) EVENTS (all-day, cancelled and declined are skipped)")
    }

    static func describeNativeStatus(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        default: return "unknown(\(status.rawValue))"
        }
    }

    static func parseCLI(_ target: String) {
        var text = ""
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            guard let url = URL(string: target) else {
                print("Invalid URL")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            var fetchError: String?
            AppStore.session.dataTask(with: url) { data, _, error in
                if let data {
                    text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                }
                fetchError = error?.localizedDescription
                semaphore.signal()
            }.resume()
            semaphore.wait()
            if let fetchError = fetchError {
                print("FETCH FAILED: \(fetchError)")
                return
            }
        } else {
            guard let data = FileManager.default.contents(atPath: target) else {
                print("Cannot read file \(target)")
                return
            }
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
        guard text.uppercased().contains("BEGIN:VCALENDAR") else {
            print("Not an iCal feed (\(text.prefix(80))…)")
            return
        }
        let subscription = CalendarSubscription(name: "cli", url: target, colorIndex: 0)
        let rawEvents = ICSParser.parse(text)
        let withStart = rawEvents.filter { $0.dtStart != nil }
        print("RAW \(rawEvents.count) VEVENTs, \(withStart.count) with DTSTART, \(withStart.filter(\.isAllDay).count) all-day")
        let now = Date()
        let formatter = ISO8601DateFormatter()
        print("WINDOW \(formatter.string(from: now.addingTimeInterval(-6 * 3600))) … \(formatter.string(from: now.addingTimeInterval(14 * 86400)))")
        for event in withStart {
            print("  \(event.uid.prefix(12)) start=\(event.dtStart.map(formatter.string(from:)) ?? "nil") allDay=\(event.isAllDay) rrule=\(event.rrule != nil) status=\(event.status)")
        }
        let events = ICSBuilder.meetings(fromICS: text, subscription: subscription, now: Date())
        print("PARSED \(events.count) EVENTS")
        for event in events {
            print("\(formatter.string(from: event.start)) → \(formatter.string(from: event.end)) | \(event.title) | \(event.link?.absoluteString ?? "no link")")
        }
    }
}
