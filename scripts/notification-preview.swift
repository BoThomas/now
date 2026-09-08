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
            store.finishRefresh(fetched: [source])
            timer = AppStore.commonTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.tick() }
            }
        }
    }
    func show() { NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}
