import AppKit
import SwiftUI

/// Optional real Notification Center / Settings UI check using a disposable signed
/// bundle and synthetic events. Nothing reads or changes the installed app's data.
@MainActor
final class NotificationPreview: NSObject, NSApplicationDelegate {
    let root: URL
    var window: NSWindow!
    var store: AppStore!
    var alerts: AlertController!
    var updates: UpdateController!
    var menu: MenuBarController!
    var timer: Timer?
    init(root: URL) { self.root = root }
    static func run(root: URL) {
        let app = NSApplication.shared
        let delegate = NotificationPreview(root: root)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
    static func renderSettings(store: AppStore, alerts: AlertController, updates: UpdateController, directory: String) {
        render(SettingsView().environmentObject(store).environmentObject(alerts).environmentObject(updates),
               size: NSSize(width: 940, height: 720), name: "new-install-guide", directory: directory)
    }
    static func render<V: View>(_ view: V, size: NSSize, name: String, directory: String) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.controlActiveState, .active))
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No render bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let output = URL(fileURLWithPath: directory)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        var settings = AppSettings()
        settings.reminderDelivery = .notification
        settings.soundEnabled = false
        settings.notifyOnCatchUp = true
        settings.automaticUpdateChecks = false
        let source = CalendarSubscription(name: "Synthetic preview", url: "http://127.0.0.1:1/preview", colorIndex: 0)
        store = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("preview-cache")),
                         initialState: Persisted(subscriptions: [source], settings: settings))
        let transport = SystemNotificationTransport()
        let controller = ReminderNotificationController(transport: transport)
        transport.response = { [weak controller] in controller?.receive(id: $0, action: $1) }
        store.connectNotifications(controller)
        alerts = AlertController(); alerts.store = store; store.alertController = alerts
        store.onAlert = { [weak self] in self?.alerts.present($0) }
        updates = UpdateController(store: store)
        menu = MenuBarController(store: store, alerts: alerts, updates: updates, openSettings: { [weak self] in self?.show() }, quit: { NSApp.terminate(nil) })
        store.openNotificationAgenda = { [weak self] in self?.menu.openAgenda() }
        store.openNotificationSyncSettings = { [weak self] in self?.show() }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "now · Isolated notification preview"
        window.contentView = NSHostingView(rootView: SettingsView().environmentObject(store).environmentObject(alerts).environmentObject(updates))
        window.center(); show()
        Task {
            await store.restoreCachedEvents()
            let date = Date()
            let events = [0, 1].map { index in
                MeetingEvent(uid: "preview-\(index)", title: "Synthetic meeting \(index + 1)", start: date.addingTimeInterval(120), end: date.addingTimeInterval(1800),
                             location: nil, notes: nil, link: nil, calendarID: source.id, calendarName: source.name, colorIndex: index)
            }
            store.commitEvents(events)
            store.finishRefresh(fetched: [source], requestID: store.beginFullRefresh(subscriptionIDs: [source.id]))
            timer = AppStore.commonTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.tick() }
            }
        }
    }
    func show() { NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}

/// Runs the actual AppDelegate in a disposable domain with the build harness's
/// fake transport. No notification registration, Calendar query or feed fetch.
@MainActor
final class SetupAppSmoke {
    static func run(existingProfile: Bool, legacyProfile: Bool = false) {
        if existingProfile {
            let state = Persisted(subscriptions: [], settings: AppSettings())
            let defaults = legacyProfile ? UserDefaults(suiteName: AppStore.legacyDomain)! : UserDefaults.standard
            defaults.set(try! JSONEncoder().encode(state), forKey: AppStore.storageKey)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Exercise the actual startup-to-status-menu fallback without registering
        // with Notification Center or reading any real calendar.
        let coldID = "now.meeting.cold-start-smoke"
        let receipt = ReminderNotification(id: coldID, keys: ["missing-occurrence"], fingerprints: ["missing"],
            expires: Date().addingTimeInterval(1800), catchUp: false,
            title: "", body: "", category: "", sound: false)
        UserDefaults.standard.set(try! JSONEncoder().encode([coldID: receipt]), forKey: "local.tboch.now.notification-receipts.v1")
        var openedColdAgenda = false
        let agendaObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu, menu.delegate is MenuBarController else { return }
                openedColdAgenda = true
                let cancel: @MainActor @Sendable () -> Void = { menu.cancelTracking() }
                _ = AppStore.commonTimer(withTimeInterval: 0.1, repeats: false) { _ in
                    MainActor.assumeIsolated { cancel() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            delegate.notificationInteraction()
            delegate.store.notifications?.receive(id: coldID, action: "com.apple.UNNotificationDefaultActionIdentifier")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            Task { @MainActor in
                func require(_ result: Bool, _ label: String) {
                    if !result { print("FAIL: " + label); exit(1) }
                }
                require(openedColdAgenda, "cold missing-meeting click opens the actual menu-bar agenda")
                NotificationCenter.default.removeObserver(agendaObserver)
                require(delegate.store.hadSavedProfile == existingProfile, "profile presence captured before migration")
                if existingProfile {
                    require(NSApp.windows.contains { $0.title == "now · Settings" && $0.isVisible }, "existing empty profile opens Settings")
                    require(!delegate.setupAssistant.pending, "existing profile bypasses assistant")
                } else {
                    require(delegate.setupWindow?.isVisible == true, "fresh launch displays assistant without sources")
                    require(NSApp.activationPolicy() == .regular, "assistant owns app menus")
                    delegate.setupAssistant.next()
                    delegate.setupWindow?.close()
                    delegate.openSettings()
                    require(delegate.setupWindow?.isVisible == true && delegate.setupAssistant.state.step == .reminders,
                            "close and reopen resumes same step")
                    delegate.setupAssistant.draft.leadSeconds = 45
                    delegate.setupAssistant.next()
                    let completed = await delegate.setupAssistant.complete(store: delegate.store, permission: { false }, probe: { .success([]) })
                    require(completed, "fullscreen setup completes without permission")
                    delegate.finishInitialSetup()
                    require(delegate.setupWindow?.isVisible == false && NSApp.windows.contains { $0.title == "now · Settings" && $0.isVisible }, "finish opens source Settings and closes assistant")
                    require(delegate.store.settings.leadSeconds == 45, "real AppDelegate retains setup settings")
                }
                @MainActor func settingsVisible() -> Bool { NSApp.windows.contains { $0.title == "now · Settings" && $0.isVisible } }
                delegate.notificationInteraction()
                require(settingsVisible(), "notification preserves already-open Settings")
                NSApp.windows.first { $0.title == "now · Settings" }?.close()
                _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false)
                try? await Task.sleep(nanoseconds: 350_000_000)
                require(!settingsVisible(), "notification-before-reopen does not open Settings")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false)
                delegate.notificationInteraction()
                try? await Task.sleep(nanoseconds: 350_000_000)
                require(!settingsVisible(), "reopen-before-notification is cancelled")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false)
                try? await Task.sleep(nanoseconds: 350_000_000)
                require(settingsVisible(), "ordinary Finder reopen still opens Settings")
                delegate.notificationInteraction()
                require(!settingsVisible(), "late notification undoes only competing reopen window")
                print("SETUP APP SMOKE OK — " + (legacyProfile ? "legacy profile migration bypass" : (existingProfile ? "existing profile bypass" : "fresh launch, close/reopen, completion to Settings")))
                exit(0)
            }
        }
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
