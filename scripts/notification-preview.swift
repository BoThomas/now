import AppKit
import NowCore
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No render bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let output = URL(fileURLWithPath: directory)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    static func verifyPopupLayout() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        func fixture(rows: Int) -> some View {
            VStack {
                PopupScrollView(maximumHeight: 200) {
                    VStack(alignment: .leading) {
                        ForEach(0..<rows, id: \.self) { Text("Overflow test row \($0)") }
                    }
                }
                Text("Pinned footer").frame(height: 30)
            }
            .padding(20).frame(width: 460).fixedSize(horizontal: false, vertical: true)
            .background(PopupWindowSizing())
        }
        let host = NSHostingView(rootView: fixture(rows: 60))
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
        }
        func scrollView(in view: NSView) -> PopupScrollContainer? {
            if let scroll = view as? PopupScrollContainer { return scroll }
            return view.subviews.compactMap { scrollView(in: $0) }.first
        }
        settle()
        guard let scroll = scrollView(in: host), let document = scroll.documentView else {
            fatalError("Popup must expose its native scroll view")
        }
        precondition(scroll.scrollerStyle == .legacy && scroll.autohidesScrollers)
        precondition(scroll.verticalScroller?.isHidden == false, "Overflow scrollbar must be visible before interaction")
        precondition(document.frame.height > scroll.contentSize.height)
        precondition(abs(window.contentLayoutRect.height - 278) < 4, "Popup must cap content and keep footer visible")
        let tallHeight = window.frame.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        precondition(abs(scroll.documentVisibleRect.maxY - document.frame.maxY) < 2, "Final row must be reachable")
        host.rootView = fixture(rows: 2)
        settle()
        precondition(window.frame.height < tallHeight - 100, "Short content must shrink its window")
        precondition(scroll.verticalScroller?.isHidden == true, "Short content must hide the scroll track")
        precondition(scroll.documentVisibleRect.minY == 0, "Shrinking content must clamp the old scroll offset")
        window.close()
        print("POPUP LAYOUT OK — bounded height, visible scrollbar, reachable last row, content resizing")
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
            store.smokeCommitEvents(events)
            store.smokeFinishRefresh(fetched: [source], requestID: store.smokeBeginFullRefresh(subscriptionIDs: [source.id]))
            timer = AppStore.commonTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.smokeTick() }
            }
        }
    }
    func show() { NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}

/// Manual, offline review of every update-window state: the GUI counterpart
/// to the guide/update assertions in notification-smoke.swift. Fake transport,
/// synthetic store, scripted guide history: no network, no Notification
/// Center, no real preferences. The full staging/install/relaunch flow stays
/// with scripts/update-ui-demo.sh.
@MainActor
final class UpdateScreensPreview: NSObject, NSApplicationDelegate {
    private let root: URL
    private var store: AppStore!
    private var updates: UpdateController!
    private var preview: NSWindow!
    private var panel: NSWindow!

    init(root: URL) { self.root = root }

    /// The preview bundle is LSUIElement (no menu bar for ⌘Q). Closing both
    /// windows ends the tour (and the wrapper's cleanup).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    static func run(root: URL) {
        let app = NSApplication.shared
        let delegate = UpdateScreensPreview(root: root)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("update-screens-cache")),
                         initialState: Persisted())
        let transport = FakeNotifications()
        store.connectNotifications(ReminderNotificationController(transport: transport))
        updates = UpdateController(store: store)
        NSApp.setActivationPolicy(.regular)
        preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                           styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        preview.isReleasedWhenClosed = false
        preview.title = "now · Update window preview"
        preview.contentView = NSHostingView(rootView: UpdateView(controller: updates).environment(\.controlActiveState, .active))
        preview.center()
        let previewFrame = preview.frame
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = "Update screens"
        panel.setFrameOrigin(NSPoint(x: previewFrame.minX - 340, y: previewFrame.minY))
        panel.contentView = NSHostingView(rootView: UpdateScreensPanel(updates: updates) { [weak self] content, guides, fluff in
            self?.present(content, guides: guides, fluff: fluff)
        })
        present(.installed(version: "9.9.9"), guides: .notificationsAndInfo)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func present(_ content: UpdateWindowContent, guides: UpdateScreensPanel.GuideCombo) {
        present(content, guides: guides, fluff: false)
    }

    private func present(_ content: UpdateWindowContent, guides: UpdateScreensPanel.GuideCombo, fluff: Bool) {
        // Scripted guide history in a throwaway domain: which cards count as
        // newly introduced decides what the What's New window shows.
        let domain = "now-update-screens-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        var history = FeatureGuideState()
        switch guides {
        case .none: history.encountered = [FeatureGuideCatalog.notificationsID, FeatureGuideCatalog.displayID]
        case .infoOnly: history.encountered = [FeatureGuideCatalog.notificationsID]
        case .notificationsAndInfo: history.encountered = []
        }
        StoredPreferences.save(history, key: FeatureGuideController.storageKey, label: "Scripted guide history", defaults: defaults)
        // Playground-only overflow fixture: a deliberately tall card appended
        // to the catalog so the page scroll and persistent scrollbar can be
        // verified. Never part of FeatureGuideCatalog itself.
        let catalog = fluff ? FeatureGuideCatalog.entries + [
            FeatureGuideDefinition(id: "playground-scroll-fluff", content: .information(
                title: "Overflow test card",
                message: (0..<9).map { "Fluff paragraph \($0 + 1). This paragraph exists only to push this card past the page height so scrolling and the persistent scrollbar can be checked by hand. Scroll to the end: this last line must be fully visible, and the navigation buttons must remain in place." }.joined(separator: "\n\n")
            ))
        ] : FeatureGuideCatalog.entries
        let controller = FeatureGuideController(defaults: defaults, catalog: catalog)
        controller.startupHealthAcknowledged(installedUpdate: true)
        store.featureGuides = controller
        defaults.removePersistentDomain(forName: domain)
        updates.windowContent = content
        preview.makeKeyAndOrderFront(nil)
    }
}

/// State picker for the manual update-window preview. See UpdateScreensPreview.
struct UpdateScreensPanel: View {
    enum GuideCombo: String, CaseIterable, Identifiable {
        case none = "No cards"
        case infoOnly = "Display card only"
        case notificationsAndInfo = "Notifications + display"
        var id: String { rawValue }
    }

    @ObservedObject var updates: UpdateController
    let show: (UpdateWindowContent, GuideCombo, Bool) -> Void
    @State private var guides: GuideCombo = .notificationsAndInfo
    @State private var scrollFluff = false
    @State private var longReleaseNotes = false
    @State private var multiVersionNotes = false

    private var manifest: UpdateManifest {
        UpdateManifest(version: "9.9.9",
                       zipURL: URL(string: "http://127.0.0.1:1/now-v9.9.9.zip")!,
                       assetSize: 12_000_000,
                       publishedAt: Date().addingTimeInterval(-2 * 86_400),
                       notes: releaseNotes)
    }

    private var releaseNotes: String {
        let summary = "A short intro paragraph that spans the summary line.\n\n### Added\n- Pick your reminder display\n- Release notes render headings and lists\n\n### Fixed\n- Install row in Settings wraps when narrow"
        guard longReleaseNotes else { return summary }
        let sections = ["Added", "Improved", "Fixed"].map { heading in
            "### \(heading)\n" + (1...12).map { index in
                "- Overflow example \(index): A longer release-note entry that wraps across multiple lines so you can check the changelog scroll area while the update status and action buttons stay visible."
            }.joined(separator: "\n")
        }
        return summary + "\n\n" + sections.joined(separator: "\n\n")
            + "\n\nEnd of long test changelog. This final line should be fully reachable."
    }

    /// Forged consolidated body for a jump like 1.10 → 2.1: grouped under
    /// the recognized categories, plus ungrouped preamble content.
    private var multiVersionBody: String {
        """
        2.0 rebuilt reminders for the notification age.

        ### Added
        - Pick your reminder display
        - Release notes render headings and lists

        ### Improved
        - Faster calendar sync

        ### Fixed
        - Install row in Settings wraps when narrow
        - Fullscreen panel keeps keyboard focus in the background
        """
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Guide cards (installed / What’s New)").font(.headline)
                Picker("Guide cards", selection: $guides) {
                    ForEach(GuideCombo.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Update available").font(.headline)
                Toggle("Use long test changelog", isOn: $longReleaseNotes)
                    .help("Adds long release notes to all three update-available states. Updates the current preview immediately.")
                    .onChange(of: longReleaseNotes) { _ in
                        if case .available = updates.windowContent {
                            updates.windowContent = .available(manifest)
                        }
                    }
                Toggle("Multi-version jump (consolidated What’s New)", isOn: $multiVersionNotes)
                    .help("Shows the forged consolidated notes a multi-version jump (e.g. 1.10 → 2.1) renders: everything since your current version, grouped under the changelog categories.")
                    .onChange(of: multiVersionNotes) { _ in
                        updates.smokeConsolidatedNotes = multiVersionNotes ? multiVersionBody : nil
                        if case .available = updates.windowContent {
                            updates.windowContent = .available(manifest)
                        }
                    }
                scene("Preparing the update…") {
                    updates.smokeStagedVersion = nil
                    updates.smokeIsVerifyingInstall = false
                    show(.available(manifest), guides, scrollFluff)
                }
                scene("Signature verified · ready to install") {
                    updates.smokeStagedVersion = manifest.version
                    updates.smokeIsVerifyingInstall = false
                    show(.available(manifest), guides, scrollFluff)
                }
                scene("Verifying update… (buttons disabled)") {
                    updates.smokeStagedVersion = manifest.version
                    updates.smokeIsVerifyingInstall = true
                    show(.available(manifest), guides, scrollFluff)
                }
                Text("Result windows").font(.headline)
                Toggle("Append tall overflow test card", isOn: $scrollFluff)
                    .help("Adds a deliberately long card page so scrolling and the persistent scrollbar can be checked.")
                scene("You're up to date") { show(.upToDate, guides, scrollFluff) }
                scene("Update installed") { show(.installed(version: "9.9.9"), guides, scrollFluff) }
                scene("What’s New (manual)") { show(.features(version: UpdateLogic.currentVersion), guides, scrollFluff) }
                Text("Problems").font(.headline)
                scene("Check failed (Try Again)") {
                    show(.problem(title: "Couldn’t check for updates",
                                  message: "The update server couldn’t be reached. Check your internet connection and try again.",
                                  retry: .check), guides, scrollFluff)
                }
                scene("Preparation failed") {
                    show(.problem(title: "Couldn’t prepare the update",
                                  message: "The downloaded update didn’t pass its signature check.",
                                  retry: .preparation), guides, scrollFluff)
                }
                scene("Install refused (no retry)") {
                    show(.problem(title: "Update not installed",
                                  message: "The new version didn’t start correctly. The previous version keeps running.",
                                  retry: nil), guides, scrollFluff)
                }
                Text("Interactions are real (fake transport): the in-card Enable Notifications… runs the permission flow, Next/Complete apply the current card, Skip This Version writes settings. The real staging/install/relaunch tour lives in scripts/update-ui-demo.sh.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(width: 320, height: 560)
    }

    private func scene(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(.bordered)
    }
}

/// Manual, offline walk-through of first-run setup: the real SetupAssistantView
/// on a disposable store with fake notification transport. The panel flips the
/// two dimensions setup reacts to (multiple displays, notification permission)
/// and restarts the assistant at any time. Finishing opens the sandboxed
/// Settings so the committed choices can be reviewed. Nothing here touches
/// real preferences, calendars, or Notification Center.
@MainActor
final class SetupScreensPreview: NSObject, ObservableObject, NSApplicationDelegate {
    private let root: URL
    private var store: AppStore!
    private var transport: FakeNotifications!
    private var notifications: ReminderNotificationController!
    private var alerts: AlertController!
    private var assistant: SetupAssistantController!
    private var assistantWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var panel: NSWindow!

    /// Mirrors the real Mac at launch; flip to review the conditional row.
    @Published var multiDisplay: Bool = NSScreen.screens.count > 1 {
        didSet { if oldValue != multiDisplay { showAssistant() } }
    }
    @Published var notificationsAllowed = false {
        didSet {
            if oldValue != notificationsAllowed {
                transport.status.authorization = notificationsAllowed ? .allowed : .notRequested
                notifications.refreshPermission(force: true)
            }
        }
    }

    init(root: URL) { self.root = root }

    static func run(root: URL) {
        let app = NSApplication.shared
        let delegate = SetupScreensPreview(root: root)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }

    /// The preview bundle is LSUIElement (no menu bar for ⌘Q). Closing the
    /// windows ends the tour (and the wrapper's cleanup).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        restart()
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = "Fresh install"
        panel.contentView = NSHostingView(rootView: SetupScreensPanel(preview: self))
        if let frame = assistantWindow?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.minX - 340, y: frame.minY))
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Fresh disposable state: new store, new draft, assistant back to step 1.
    func restart() {
        settingsWindow?.close()
        settingsWindow = nil
        let domain = "now-setup-screens-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        store = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("setup-screens-cache")),
                         initialState: Persisted())
        transport = FakeNotifications()
        transport.status.authorization = notificationsAllowed ? .allowed : .notRequested
        notifications = ReminderNotificationController(transport: transport)
        store.connectNotifications(notifications)
        alerts = AlertController()
        alerts.store = store
        store.alertController = alerts
        store.onAlert = { [weak self] in self?.alerts.present($0) }
        assistant = SetupAssistantController(isNewProfile: true, settings: AppSettings(), defaults: defaults)
        showAssistant()
    }

    func showAssistant() {
        assistantWindow?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        // Closed windows must stay alive: restart reopens or replaces them,
        // and the default release-on-close would leave dangling references.
        window.isReleasedWhenClosed = false
        window.title = "Set up now (preview)"
        window.contentView = NSHostingView(rootView: SetupAssistantView(assistant: assistant, store: store,
            alerts: alerts, notifications: notifications, multiDisplay: multiDisplay, onFinish: { [weak self] in
                self?.setupFinished()
            }))
        window.center()
        window.makeKeyAndOrderFront(nil)
        assistantWindow = window
    }

    /// Completing setup opens the sandboxed Settings, like the real finish
    /// path opens source Settings.
    private func setupFinished() {
        let window = settingsWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
                                                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "now · Settings (sandbox)"
        window.contentView = NSHostingView(rootView: SettingsView().environmentObject(store).environmentObject(alerts)
            .environmentObject(UpdateController(store: store)))
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
        if panel != nil { panel.orderFrontRegardless() }
    }
}

/// Controls for the manual first-run preview. See SetupScreensPreview.
struct SetupScreensPanel: View {
    @ObservedObject var preview: SetupScreensPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Environment").font(.headline)
            Toggle("Multi-display Mac", isOn: $preview.multiDisplay)
                .help("Shows the conditional Show on question on the reminders step (only appears with Fullscreen selected).")
            Toggle("Notifications allowed", isOn: $preview.notificationsAllowed)
                .help("Flips the sandboxed permission state the setup reacts to.")
            Button("Restart fresh setup") { preview.restart() }
                .buttonStyle(.bordered)
            Text("Everything is sandboxed: fake transport, throwaway preferences. Completing setup opens the sandboxed Settings with your choices applied. Close all windows to quit.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }
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
        // The activation rounds below run past updater.start()'s +10 s
        // automatic check; this fixture never contacts the network.
        delegate.store.settings.automaticUpdateChecks = false
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
                // Focus requires a real desktop. Allow normal scheduling jitter
                // without relaxing the final focus/policy assertions.
                @MainActor func waitUntil(_ condition: @MainActor () -> Bool) async {
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
                        try? await Task.sleep(nanoseconds: 25_000_000)
                    }
                }
                require(openedColdAgenda, "cold missing-meeting click opens the actual menu-bar agenda")
                NotificationCenter.default.removeObserver(agendaObserver)
                require(delegate.store.hadSavedProfile == existingProfile, "profile presence captured before migration")
                if existingProfile {
                    require(!NSApp.windows.contains { $0.title == "now · Settings" && $0.isVisible }, "existing empty profile stays quiet")
                    require(!delegate.smokeSetupAssistant.pending, "existing profile bypasses assistant")
                    require(NSApp.windows.contains { $0.title == "What’s New" && $0.isVisible }, "manual upgrade presents unseen features without install marker")
                } else {
                    require(delegate.smokeSetupWindow?.isVisible == true, "fresh launch displays assistant without sources")
                    require(NSApp.activationPolicy() == .regular, "assistant owns app menus")
                    if CommandLine.arguments.contains("--activation-smoke") {
                        // Fresh-install onboarding opens at +0.4 s while the
                        // app runs in the background (no user gesture yet):
                        // on 2026-09-17 it appeared once and hid once on
                        // identical relaunches. Re-present through the
                        // production path from the background, repeatedly —
                        // the window must take the front every time.
                        for round in 0..<3 {
                            delegate.smokeSetupWindow?.close()
                            NSApp.deactivate()
                            await waitUntil { !NSApp.isActive }
                            require(!NSApp.isActive, "onboarding round \(round) starts in the background")
                            delegate.openSettings() // pending assistant routes to the setup window
                            await waitUntil { NSApp.isActive && delegate.smokeSetupWindow?.isKeyWindow == true }
                            require(NSApp.isActive, "onboarding takes focus from the background (round \(round))")
                            require(delegate.smokeSetupWindow?.isKeyWindow == true, "onboarding window is key and front (round \(round))")
                            require(NSApp.activationPolicy() == .regular, "onboarding owns app menu policy (round \(round))")
                        }
                    }
                    delegate.smokeSetupAssistant.next()
                    delegate.smokeSetupWindow?.close()
                    delegate.openSettings()
                    require(delegate.smokeSetupWindow?.isVisible == true && delegate.smokeSetupAssistant.state.step == .reminders,
                            "close and reopen resumes same step")
                    delegate.smokeSetupAssistant.draft.leadSeconds = 45
                    delegate.smokeSetupAssistant.next()
                    let completed = await delegate.smokeSetupAssistant.complete(store: delegate.store, permission: { false }, probe: { .success([]) })
                    require(completed, "fullscreen setup completes without permission")
                    delegate.smokeFinishInitialSetup()
                    require(delegate.smokeSetupWindow?.isVisible == false && NSApp.windows.contains { $0.title == "now · Settings" && $0.isVisible }, "finish opens source Settings and closes assistant")
                    require(delegate.store.settings.leadSeconds == 45, "real AppDelegate retains setup settings")
                }
                @MainActor func settingsVisible() -> Bool { NSApp.windows.contains { $0.title == "now · Settings" && $0.isVisible } }
                if existingProfile {
                    // Let startup feature-window activation settle before holding
                    // the menu open; it can otherwise dismiss a tracking menu.
                    for window in NSApp.windows where window.isVisible { window.close() }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    var reopenedDuringAgenda = false
                    var reopenedAfterAgenda = false
                    var duringTimer: Timer?
                    let beginObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
                        MainActor.assumeIsolated {
                            guard let menu = notification.object as? NSMenu, menu.delegate is MenuBarController else { return }
                            duringTimer = AppStore.commonTimer(withTimeInterval: 1.2, repeats: false) { _ in
                                MainActor.assumeIsolated {
                                    reopenedDuringAgenda = true
                                    _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false)
                                    menu.cancelTracking()
                                }
                            }
                        }
                    }
                    let endObserver = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { notification in
                        MainActor.assumeIsolated {
                            guard let menu = notification.object as? NSMenu, menu.delegate is MenuBarController else { return }
                            duringTimer?.invalidate()
                            // Foreground actions can deliver their reopen after
                            // menu tracking and the notification callback return.
                            _ = AppStore.commonTimer(withTimeInterval: 0.05, repeats: false) { _ in
                                MainActor.assumeIsolated {
                                    reopenedAfterAgenda = true
                                    _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false)
                                }
                            }
                        }
                    }
                    let date = Date()
                    let calendarID = UUID()
                    let meetings = [0, 1].map { index in
                        MeetingEvent(uid: "agenda-smoke-\(index)", title: "Synthetic meeting \(index + 1)",
                            start: date.addingTimeInterval(120), end: date.addingTimeInterval(1800),
                            location: nil, notes: nil, link: nil, calendarID: calendarID, calendarName: "Synthetic", colorIndex: index)
                    }
                    delegate.store.smokeCommitEvents(meetings)
                    let group = ReminderNotification(id: "now.meeting.agenda-smoke", keys: meetings.map(NotificationLogic.eventKey),
                        fingerprints: ["first", "second"], expires: date.addingTimeInterval(1800), catchUp: false,
                        title: "", body: "", category: "", sound: false)
                    delegate.notificationInteraction()
                    delegate.store.notifications?.onResponse?(group, "choose")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    NotificationCenter.default.removeObserver(beginObserver)
                    NotificationCenter.default.removeObserver(endObserver)
                    require(reopenedDuringAgenda, "group agenda stays open past the original one-second notification guard")
                    require(reopenedAfterAgenda, "notification reopen arrives after agenda dismissal")
                    require(!settingsVisible(), "notification agenda dismissal must not open Settings")
                    delegate.store.smokeCommitEvents([])
                }
                delegate.openSettings()
                require(settingsVisible(), "Settings remains available on explicit request")
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
                if CommandLine.arguments.contains("--activation-smoke") {
                    for window in NSApp.windows where window.isVisible { window.close() }
                    NSApp.deactivate()
                    await waitUntil { !NSApp.isActive }
                    require(!NSApp.isActive, "activation fixture starts in the background")
                    var preview = AppSettings(); preview.soundEnabled = false
                    delegate.alertController.presentPreview(settings: preview)
                    await waitUntil { NSApp.isActive && NSApp.keyWindow is AlertPanel }
                    require(delegate.alertController.isOpen && NSApp.isActive, "timer-style reminder activates the app")
                    require(NSApp.keyWindow is AlertPanel, "reminder panel owns keyboard focus")
                    require(NSApp.activationPolicy() == .regular, "reminder owns app menu policy")
                    delegate.alertController.close()
                    await waitUntil { NSApp.activationPolicy() == .accessory }
                    require(NSApp.activationPolicy() == .accessory, "closing reminder restores accessory policy")
                    // User-initiated windows must land in front of the active
                    // app's windows even when the request is NOT tied to a
                    // fresh click (2026-09-17: the update result, install
                    // confirmation, and onboarding opened behind other apps).
                    // The background re-entry below reproduces that handoff:
                    // async fetch completions and startup confirmations fire
                    // exactly this way. Repeated rounds expose ordering races.
                    let release = UpdateManifest(version: "999.0.0", zipURL: URL(string: "https://example.com/now.zip")!,
                                                 assetSize: 1, publishedAt: Date().addingTimeInterval(-86400), notes: "Synthetic")
                    for round in 0..<3 {
                        NSApp.deactivate()
                        await waitUntil { !NSApp.isActive }
                        require(!NSApp.isActive, "window fixture round \(round) starts in the background")
                        delegate.openSettings()
                        await waitUntil { NSApp.isActive && delegate.smokeSettingsWindow?.isKeyWindow == true }
                        require(NSApp.isActive, "Settings activates from the background (round \(round))")
                        require(delegate.smokeSettingsWindow?.isKeyWindow == true, "Settings is key window (round \(round))")
                        require(NSApp.activationPolicy() == .regular, "Settings owns app menu policy (round \(round))")
                        delegate.smokeSettingsWindow?.close()
                        await waitUntil { NSApp.activationPolicy() == .accessory }
                        NSApp.deactivate()
                        await waitUntil { !NSApp.isActive }
                        delegate.updateController.windowContent = .available(release)
                        await waitUntil { delegate.smokeUpdateWindow?.isKeyWindow == true }
                        require(NSApp.isActive && delegate.smokeUpdateWindow?.isKeyWindow == true,
                                "update window fronts from the background like an async fetch result (round \(round))")
                        require(delegate.smokeUpdateWindow?.title == "Update now", "update window title follows content")
                        delegate.updateController.dismissWindow()
                        await waitUntil { delegate.smokeUpdateWindow?.isVisible != true }
                        await waitUntil { NSApp.activationPolicy() == .accessory }
                    }
                    // The automatic 18-hour dwell escalation is passive: the
                    // window appears, but the app must not force itself in
                    // front of whatever the person is doing.
                    NSApp.deactivate()
                    await waitUntil { !NSApp.isActive }
                    delegate.updateController.smokeShowWindow(.available(release), userInitiated: false)
                    await waitUntil { delegate.smokeUpdateWindow?.isVisible == true }
                    require(delegate.smokeUpdateWindow?.isVisible == true, "passive dwell window becomes visible")
                    require(NSApp.activationPolicy() == .regular, "passive window still owns app menu policy")
                    require(!NSApp.isActive, "passive dwell escalation must not steal focus")
                    delegate.updateController.dismissWindow()
                    await waitUntil { NSApp.activationPolicy() == .accessory }
                    print("ACTIVATION SMOKE OK — background reminder takes keyboard focus and restores policy")
                }
                print("SETUP APP SMOKE OK — " + (legacyProfile ? "legacy profile migration bypass" : (existingProfile ? "existing profile bypass" : "fresh launch, close/reopen, completion to Settings")))
                exit(0)
            }
        }
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
