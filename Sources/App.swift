import SwiftUI
import AppKit

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
                if let window = NSApp.keyWindow, window === self.settingsWindow {
                    self.handleQuitFromSettings()
                } else if self.alertController.isOpen {
                    self.alertController.close()
                } else {
                    NSApp.terminate(nil)
                }
                return nil
            }
            return event
        }
        store.alertController = alertController
        alertController.store = store
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
        if store.subscriptions.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openSettings()
            }
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
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
        NSApp.mainMenu = mainMenu
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
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 720), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "now · Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView().environmentObject(store).environmentObject(alertController))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
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
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.setActivationPolicy(.accessory)
        app.run()
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
