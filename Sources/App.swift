import SwiftUI
import AppKit
import EventKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()
    let alertController = AlertController()
    /// Created lazily (initializes off `store`; property initializers run
    /// before self). First touched in applicationDidFinishLaunching.
    lazy var updateController = UpdateController(store: store)
    private var menuBarController: MenuBarController?
    private var settingsWindow: NSWindow?
    private var updateWindow: NSWindow?
    /// A window request that arrived while a reminder was showing — shown
    /// when the alert closes (via `policyDidChange`).
    private var pendingUpdateWindow = false
    private var pendingFirstRunSettings = false
    private var windowRequestObserver: Any?
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
            self?.presentPendingUpdateWindow()
        }
        store.onAlert = { [weak alertController] events in
            alertController?.present(events)
        }
        updateController.onWindowRequest = { [weak self] in
            self?.presentUpdateWindow()
        }
        updateController.onTerminateForUpdate = { [weak self] in
            self?.terminateForUpdate()
        }
        // The helper relaunches us with NOW_UPDATE_ERROR when an install
        // failed — tell the user and stop auto-offering that version.
        if let reason = ProcessInfo.processInfo.environment["NOW_UPDATE_ERROR"], !reason.isEmpty {
            updateController.handleInstallFailure(reason: reason)
        }
        windowRequestObserver = updateController.$windowContent.receive(on: RunLoop.main).sink { [weak self] (content: UpdateWindowContent?) in
            guard content == nil, self?.updateController.windowContent == nil else { return }
            self?.closeUpdateWindow()
        }
        menuBarController = MenuBarController(store: store, alerts: alertController, updates: updateController, openSettings: { [weak self] in
            self?.openSettings()
        }, quit: { [weak self] in
            // Same flow as ⌘Q and the app menu: confirm when Settings is key,
            // dismiss a showing alert, else terminate.
            self?.handleQuitRequest()
        })
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Main queue delivery — hop into our MainActor context.
            MainActor.assumeIsolated {
                self?.store.refresh()
                self?.updateController.checkMaybeAutomatic()
            }
        }
        store.start()
        updateController.start()
        if store.subscriptions.isEmpty && !store.nativeCalendars.contains(where: \.isEnabled) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                if self.updateController.windowContent == nil {
                    self.openSettings()
                } else {
                    self.pendingFirstRunSettings = true
                }
            }
        }
        // Prove the normal AppKit/store startup path and main run loop stayed
        // alive before the install helper releases the rollback backup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NowApp.acknowledgeUpdatedStartup()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // "now" app menu — Quit goes through the custom flow (confirm in Settings,
        // dismiss-vs-quit while an alert shows), same as the ⌘Q local monitor,
        // which still takes precedence for the key combo.
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

    /// Shared quit behavior for ⌘Q, the app menu item, and the status menu:
    /// confirm while Settings is key, ask dismiss-vs-quit while a reminder is
    /// showing, otherwise terminate. Every Quit entry point routes through here.
    @objc func handleQuitRequest() {
        if let window = NSApp.keyWindow, window === settingsWindow {
            handleQuitFromSettings()
        } else if alertController.isOpen {
            handleQuitFromAlert()
        } else {
            NSApp.terminate(nil)
        }
    }

    /// Quit request while the fullscreen reminder is showing: quitting silently
    /// closing the reminder would be surprising — ask which one they meant.
    private func handleQuitFromAlert() {
        let alert = NSAlert()
        alert.messageText = "Quit now?"
        alert.informativeText = "A reminder is showing. Quit stops all reminders until you launch now again; Dismiss closes just the reminder."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit now")
        alert.addButton(withTitle: "Dismiss Reminder")
        alert.addButton(withTitle: "Cancel")
        // Sit above the .screenSaver-level reminder panel.
        alert.window.level = NSWindow.Level(NSWindow.Level.screenSaver.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        // The reminder's own key monitor (esc/return/s) must not eat keystrokes
        // while this dialog is up.
        alertController.modalAlertActive = true
        let result = alert.runModal()
        alertController.modalAlertActive = false
        switch result {
        case .alertFirstButtonReturn:
            NSApp.terminate(nil)
        case .alertSecondButtonReturn:
            alertController.close()
        default:
            break
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
            // Default 940×720 shows the section sidebar (threshold 880 — a bit
            // of headroom so the first tiny resize doesn't drop it); clamped to
            // the screen so small displays never get an overflowing window. On
            // a screen narrower than the threshold the sidebar simply doesn't
            // appear (form-only layout) — by design. The user's chosen frame is
            // remembered across launches via the autosave name.
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "now · Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView().environmentObject(store).environmentObject(alertController).environmentObject(updateController))
            window.minSize = NSSize(width: 520, height: 480)
            window.delegate = self
            window.setFrameAutosaveName("now-settings")
            if !window.setFrameUsingName("now-settings") {
                window.center()
            }
            // Clamp the titled outer frame, not just its content rectangle. This
            // keeps the default 940×720 content size on normal displays while
            // fitting the title bar and borders on smaller visible screens.
            var frame = window.frame
            let visibleScreen = NSScreen.screens.max {
                $0.visibleFrame.intersection(frame).width * $0.visibleFrame.intersection(frame).height <
                $1.visibleFrame.intersection(frame).width * $1.visibleFrame.intersection(frame).height
            }?.visibleFrame ?? screen
            frame.size.width = min(frame.width, visibleScreen.width)
            frame.size.height = min(frame.height, visibleScreen.height)
            frame.origin.x = min(max(frame.minX, visibleScreen.minX), visibleScreen.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visibleScreen.minY), visibleScreen.maxY - frame.height)
            window.setFrame(frame, display: false)
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

    /// The app is .regular (Dock icon + owns the menu bar) while Settings, the
    /// fullscreen alert, or the update window is visible, .accessory otherwise
    /// (menu-bar-only). Called whenever any of them appears/disappears —
    /// never set the policy anywhere else.
    private func syncActivationPolicy() {
        let wantRegular = (settingsWindow?.isVisible ?? false) || alertController.isOpen || (updateWindow?.isVisible ?? false)
        let current = NSApp.activationPolicy()
        if wantRegular, current == .accessory {
            NSApp.setActivationPolicy(.regular)
        } else if !wantRegular, current == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Update window

    /// Shows the update window — deferred while a reminder is showing: the
    /// alert is a .screenSaver-level fullscreen panel whose key monitor eats
    /// Return/Esc, so the window would sit underneath it, invisible.
    private func presentUpdateWindow() {
        guard updateController.windowContent != nil else { return }
        guard !alertController.isOpen else {
            pendingUpdateWindow = true
            return
        }
        if updateWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 424), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Update now"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: UpdateView(controller: updateController))
            window.delegate = self
            window.center()
            updateWindow = window
        }
        updateWindow?.makeKeyAndOrderFront(nil)
        updateController.updateWindowDidShow()
        syncActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A deferred request fires when the reminder alert closes.
    private func presentPendingUpdateWindow() {
        guard pendingUpdateWindow, !alertController.isOpen else { return }
        pendingUpdateWindow = false
        presentUpdateWindow()
    }

    private func closeUpdateWindow() {
        updateWindow?.orderOut(nil)
        syncActivationPolicy()
        if pendingFirstRunSettings {
            pendingFirstRunSettings = false
            DispatchQueue.main.async { [weak self] in self?.openSettings() }
        }
    }

    /// Install flow quit: closes the alert (the swap helper finishes after
    /// our PID dies) and terminates WITHOUT either quit confirmation — the
    /// user just explicitly asked to install & relaunch.
    private func terminateForUpdate() {
        updateWindow?.orderOut(nil)
        if alertController.isOpen { alertController.close() }
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // The update window "closing" is just hiding (orderOut semantics with
        // isReleasedWhenClosed = false); mirror the state to the controller so
        // a ⌘W close and the Later button agree.
        if let window = notification.object as? NSWindow, window === updateWindow {
            updateController.windowClosedExternally()
        }
        syncActivationPolicy()
        // Hardening: windowWillClose can run while `isVisible` is still true,
        // which would leave the Dock icon behind. Re-evaluate once more after
        // the close completes — `syncActivationPolicy()` is idempotent.
        DispatchQueue.main.async { [weak self] in
            self?.syncActivationPolicy()
        }
    }
}

@main
enum NowApp {
    @MainActor static let appDelegate = AppDelegate()

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
        if let index = arguments.firstIndex(of: "--update-check") {
            let base = updateCLIValue(after: index, arguments: arguments)
            updateCheckCLI(base)
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--update-smoke") {
            let base = updateCLIValue(after: index, arguments: arguments)
            updateSmokeCLI(base)
            exit(0)
        }
        if let reportPath = ProcessInfo.processInfo.environment["NOW_SMOKE_FAILURE_REPORT"], !reportPath.isEmpty {
            UpdateStaging.cleanupLaunchArtifacts(bundlePath: Bundle.main.bundlePath)
            let reason = ProcessInfo.processInfo.environment["NOW_UPDATE_ERROR"] ?? "unknown failure"
            let report = "\(UpdateLogic.currentVersion)|\(reason)"
            try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)
            exit(0)
        }
        // Smoke-test child: the install helper relaunched us (via
        // `open --env NOW_SMOKE_REPORT=…`) to prove the swap worked. Write
        // the version report, run the launch cleanup the real app would run,
        // and never start the UI.
        if let reportPath = ProcessInfo.processInfo.environment["NOW_SMOKE_REPORT"], !reportPath.isEmpty {
            acknowledgeUpdatedStartup()
            UpdateStaging.cleanupLaunchArtifacts(bundlePath: Bundle.main.bundlePath)
            try? UpdateLogic.currentVersion.write(toFile: reportPath, atomically: true, encoding: .utf8)
            exit(0)
        }
        // main() itself is nonisolated; everything below runs on the main thread.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.delegate = appDelegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }

    /// The value after a CLI flag, unless it looks like another flag (or is
    /// the --update-repo pair, which belongs to that flag).
    static func updateCLIValue(after index: Int, arguments: [String]) -> String? {
        guard arguments.count > index + 1 else { return nil }
        let next = arguments[index + 1]
        guard !next.hasPrefix("--") else { return nil }
        return next
    }

    /// EventKit counterpart of `--parse`: prints authorization status, every EKCalendar,
    /// and exactly which events a fetch would keep in the −6h…+14d window.
    /// Note: permission granted from a terminal run is attributed to the terminal app —
    /// for real testing launch now.app and grant there.
    static func nativeCLI(_ subcommand: String?) {
        MainActor.assumeIsolated {
            nativeCLIBody(subcommand)
        }
    }

    @MainActor private static func nativeCLIBody(_ subcommand: String?) {
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
        var totalMS = 0.0
        for info in infos {
            let native = NativeCalendar(ekIdentifier: info.ekIdentifier, name: info.title, colorHex: info.colorHex, colorIndex: 0)
            let fetchStart = Date()
            let events = source.fetchEvents(calendars: [native], skipDeclined: true, now: now)
            let ms = Date().timeIntervalSince(fetchStart) * 1000
            totalMS += ms
            print("CALENDAR \(info.title): keeping \(events.count) (\(String(format: "%.0f", ms)) ms)")
            for event in events {
                kept += 1
                print("  \(formatter.string(from: event.start)) → \(Fmt.time.string(from: event.end)) | \(event.title) | \(event.link?.absoluteString ?? "no link")")
            }
        }
        print("PARSED \(kept) EVENTS (all-day, cancelled and declined are skipped)")
        print("QUERY TIME total \(String(format: "%.0f", totalMS)) ms — budget: <50 ms warm / <500 ms cold per store")
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

    // MARK: Update CLI (--update-check / --update-smoke)

    /// The `--parse` of updates: prints exactly what the updater sees and
    /// would decide — running version, API response, matched asset, decision
    /// for manual AND automatic (age-gated) checks, accepted fingerprints.
    /// Read-only: never writes the updates defaults.
    static func updateCheckCLI(_ baseArgument: String?) {
        let arguments = ProcessInfo.processInfo.arguments
        var repoArgument: String?
        if let index = arguments.firstIndex(of: "--update-repo"), index + 1 < arguments.count {
            repoArgument = arguments[index + 1]
        }
        let base = UpdateFetch.resolvedBase(baseArgument)
        let repo = UpdateFetch.resolvedRepo(repoArgument)
        print("NOW \(UpdateLogic.currentVersion) (build \(UpdateLogic.currentBuild))")
        print("ACCEPTS \(UpdateLogic.pinnedFingerprints.joined(separator: " "))")
        for fingerprint in UpdateLogic.pinnedFingerprints {
            print("DR \(UpdateLogic.updateRequirement(fingerprint: fingerprint))")
        }
        guard let url = UpdateFetch.latestReleaseURL(base: base, repo: repo) else {
            print("DECISION error — invalid URL for base \(base)")
            return
        }
        print("API \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.setValue(UpdateFetch.userAgent(), forHTTPHeaderField: "User-Agent")
        if let token = UpdateFetch.authToken(base: base) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var status: Int?
        var fetchError: String?
        guard UpdateFetch.allows(url, apiBaseOverride: UpdateFetch.apiBaseOverride) else {
            print("DECISION error — update URL must use HTTPS")
            return
        }
        UpdateTransport.session.dataTask(with: request) { body, response, error in
            data = body
            status = (response as? HTTPURLResponse)?.statusCode
            fetchError = error?.localizedDescription
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let fetchError {
            print("HTTP error — \(fetchError)")
            return
        }
        print("HTTP \(status.map(String.init) ?? "?")")
        if status == 404 {
            print("DECISION up-to-date — no releases (404)")
            return
        }
        guard UpdateFetch.isSuccessfulStatus(status) else {
            print("DECISION error — server returned \(status.map(String.init) ?? "non-HTTP response")")
            return
        }
        guard let data else { return }
        guard let manifest = UpdateLogic.parseLatestRelease(data) else {
            print("DECISION error — no usable release/asset in response (\(data.count) bytes)")
            return
        }
        print("TAG v\(manifest.version) ASSET \(manifest.zipURL.lastPathComponent) SIZE \(manifest.assetSize) PUBLISHED \(ISO8601DateFormatter().string(from: manifest.publishedAt))")
        let manual = UpdateLogic.decide(manifest: manifest, currentVersion: UpdateLogic.currentVersion, skipped: nil, now: Date(), minAge: 0)
        let automatic = UpdateLogic.decide(manifest: manifest, currentVersion: UpdateLogic.currentVersion, skipped: nil, now: Date(), minAge: UpdateController.ageGate)
        func describe(_ decision: UpdateDecision) -> String {
            switch decision {
            case .available(let m): return "available — v\(m.version) is newer"
            case .upToDate: return "up-to-date"
            case .skippedVersion(let v): return "skipped — v\(v)"
            case .error(let e): return "error — \(e)"
            }
        }
        print("DECISION (manual) \(describe(manual))")
        print("DECISION (auto)   \(describe(automatic))")
    }

    /// Hidden smoke mode: runs the REAL updater flow (check → stage → verify →
    /// spawn swap helper → terminate) headless against an overridden API base.
    /// Exit codes: 0 spawned helper (or stuck-quit variant stayed alive),
    /// 2 REFUSED (guards/verification — nothing was touched), 3 UPTODATE,
    /// 4 ERROR. Never writes the updates defaults.
    static func updateSmokeCLI(_ baseArgument: String?) {
        MainActor.assumeIsolated {
            updateSmokeCLIBody(baseArgument)
        }
    }

    @MainActor private static func updateSmokeCLIBody(_ baseArgument: String?) {
        let arguments = ProcessInfo.processInfo.arguments
        var repoArgument: String?
        if let index = arguments.firstIndex(of: "--update-repo"), index + 1 < arguments.count {
            repoArgument = arguments[index + 1]
        }
        let base = UpdateFetch.resolvedBase(baseArgument)
        let repo = UpdateFetch.resolvedRepo(repoArgument)
        let bundlePath = Bundle.main.bundlePath
        print("SMOKE: old app \(bundlePath) v\(UpdateLogic.currentVersion) (build \(UpdateLogic.currentBuild))")
        guard let url = UpdateFetch.latestReleaseURL(base: base, repo: repo) else {
            print("SMOKE: ERROR invalid URL for base \(base)")
            exit(4)
        }
        let fetchSemaphore = DispatchSemaphore(value: 0)
        var outcome: UpdateFetch.Outcome?
        Task {
            outcome = await UpdateFetch.fetch(url: url, base: base)
            fetchSemaphore.signal()
        }
        runLoopWait(fetchSemaphore)
        guard let outcome else {
            print("SMOKE: ERROR no fetch outcome")
            exit(4)
        }
        if outcome.status == 404 {
            print("SMOKE: UPTODATE 404 no releases")
            exit(3)
        }
        if let error = outcome.error {
            print("SMOKE: ERROR \(error)")
            exit(4)
        }
        guard UpdateFetch.isSuccessfulStatus(outcome.status) else {
            print("SMOKE: ERROR server returned \(outcome.status.map(String.init) ?? "non-HTTP response")")
            exit(4)
        }
        guard let data = outcome.data else {
            print("SMOKE: ERROR empty response")
            exit(4)
        }
        guard let manifest = UpdateLogic.parseLatestRelease(data) else {
            print("SMOKE: ERROR no usable release in payload")
            exit(4)
        }
        print("SMOKE: latest v\(manifest.version)")
        let decision = UpdateLogic.decide(manifest: manifest, currentVersion: UpdateLogic.currentVersion, skipped: nil, now: Date(), minAge: 0)
        guard case .available = decision else {
            print("SMOKE: UPTODATE \(decision)")
            exit(3)
        }
        let stageSemaphore = DispatchSemaphore(value: 0)
        var staged: Result<UpdateStaging.StagedUpdate, StageFailure>?
        var stagingLimits = StagingLimits.production
        if let value = envInt64("NOW_SMOKE_ARCHIVE_LIMIT") { stagingLimits.archiveBytes = value }
        if let value = envInt64("NOW_SMOKE_EXTRACTED_LIMIT") { stagingLimits.extractedBytes = value }
        Task {
            staged = await UpdateStaging.stage(manifest: manifest, bundlePath: bundlePath, limits: stagingLimits)
            stageSemaphore.signal()
        }
        runLoopWait(stageSemaphore)
        guard case .success(let update) = staged else {
            if case .failure(let stageFailure)? = staged {
                print("SMOKE: REFUSED \(stageFailure.reason)")
                exit(2)
            }
            print("SMOKE: ERROR staging produced no result")
            exit(4)
        }
        print("SMOKE: staged v\(update.manifest.version) at \(update.appURL.path)")
        if let problem = UpdateLogic.installLocationProblem(bundlePath) {
            print("SMOKE: REFUSED \(problem)")
            exit(2)
        }
        if UpdateInstaller.otherInstanceRunning() {
            print("SMOKE: REFUSED another instance of now is running")
            exit(2)
        }
        let env = ProcessInfo.processInfo.environment
        var extraEnv: [String: String] = [:]
        for key in ["NOW_SMOKE_REPORT", "NOW_SMOKE_FAILURE_REPORT", "NOW_SMOKE_HOME", "NOW_SMOKE_POLL_TIMEOUT", "NOW_SMOKE_HEALTH_TIMEOUT", "NOW_SMOKE_HELPER_FAULT", "NOW_SMOKE_HELPER_DONE"] {
            if let value = env[key], !value.isEmpty { extraEnv[key] = value }
        }
        if let fault = extraEnv["NOW_SMOKE_HELPER_FAULT"], !["backup", "relaunch", "health"].contains(fault) {
            print("SMOKE: ERROR unknown helper fault \(fault)")
            exit(4)
        }
        let backupPath = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
            .appendingPathComponent("now.app.old-\(UUID().uuidString)").path
        guard UpdateInstaller.spawnHelper(
            bundlePath: bundlePath,
            stagedAppPath: update.appURL.path,
            backupPath: backupPath,
            releasesURL: Links.releases.absoluteString,
            extraEnv: extraEnv
        ) else {
            print("SMOKE: ERROR helper spawn failed")
            exit(4)
        }
        if env["NOW_SMOKE_SKIP_QUIT"] == "1" {
            // Stuck-quit negative: stay alive past the helper's poll timeout —
            // the helper must bail WITHOUT touching anything.
            let wait = Double(env["NOW_SMOKE_POLL_TIMEOUT"] ?? "3") ?? 3
            print("SMOKE: staying alive \(wait + 2)s (stuck-quit variant)")
            Thread.sleep(forTimeInterval: wait + 2)
            print("SMOKE: still alive; helper should have bailed, nothing moved")
            exit(0)
        }
        print("SMOKE: INSTALLED v\(manifest.version) — terminating for swap")
        exit(0)
    }

    /// Services the main run loop while waiting — async URLSession/Task
    /// completions must be allowed to land (same pattern as --native).
    static func runLoopWait(_ semaphore: DispatchSemaphore) {
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    static func envInt64(_ key: String) -> Int64? {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let value = Int64(raw), value > 0 else { return nil }
        return value
    }

    /// The installer accepts startup only from the exact child PID it launched
    /// and only for its unguessable token. This runs before every CLI/UI branch.
    static func acknowledgeUpdatedStartup() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NOW_SMOKE_HELPER_FAULT"] != "health",
              let token = environment["NOW_HEALTH_TOKEN"], !token.isEmpty,
              let path = environment["NOW_HEALTH_ACK"], !path.isEmpty else { return }
        let acknowledgement = "\(getpid()):\(token)"
        try? acknowledgement.write(toFile: path, atomically: true, encoding: .utf8)
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
        let (rawEvents, parseWarnings) = ICSParser.parse(text)
        for warning in parseWarnings.prefix(10) {
            print("WARNING: \(warning)")
        }
        let withStart = rawEvents.filter { $0.dtStart != nil }
        print("RAW \(rawEvents.count) VEVENTs, \(withStart.count) with DTSTART, \(withStart.filter(\.isAllDay).count) all-day")
        let now = Date()
        let formatter = ISO8601DateFormatter()
        print("WINDOW \(formatter.string(from: now.addingTimeInterval(-6 * 3600))) … \(formatter.string(from: now.addingTimeInterval(14 * 86400)))")
        for event in withStart {
            print("  \(event.uid.prefix(12)) start=\(event.dtStart.map(formatter.string(from:)) ?? "nil") allDay=\(event.isAllDay) rrule=\(event.rrule != nil) status=\(event.status)")
        }
        let (events, buildWarnings) = ICSBuilder.meetings(fromICS: text, subscription: subscription, now: Date())
        for warning in buildWarnings.prefix(10) {
            print("WARNING: \(warning)")
        }
        print("PARSED \(events.count) EVENTS")
        for event in events {
            print("\(formatter.string(from: event.start)) → \(formatter.string(from: event.end)) | \(event.title) | \(event.link?.absoluteString ?? "no link")")
        }
    }
}
