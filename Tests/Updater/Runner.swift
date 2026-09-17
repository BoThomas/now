import Foundation
import NowCore
import AppKit

@main
enum UpdaterTestRunner {
    static func main() {
        if ProcessInfo.processInfo.environment["NOW_TEST_DEMO_SMOKE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { startDemoSmoke() }
        }
        NowApp.main()
    }

    static var demoRoot: URL? {
        ProcessInfo.processInfo.environment["NOW_TEST_DEMO_ROOT"].map { URL(fileURLWithPath: $0) }
    }
    static var demoTrash: URL? { demoRoot?.appendingPathComponent("home/.Trash") }
    static var featureCatalog: [FeatureGuideDefinition] {
        guard demoRoot != nil,
              ProcessInfo.processInfo.environment["NOW_TEST_DEMO_VERSION"] != UpdateLogic.currentVersion else {
            return FeatureGuideCatalog.entries
        }
        return FeatureGuideCatalog.entries.filter { $0.id != FeatureGuideCatalog.displayID }
    }

    @MainActor static func makeDelegate() -> AppDelegate {
        guard let cachePath = ProcessInfo.processInfo.environment["NOW_TEST_CACHE_ROOT"] else {
            preconditionFailure("Updater fixture requires a disposable cache")
        }
        var settings = AppSettings()
        settings.automaticUpdateChecks = false
        settings.launchAtLogin = false
        let cache = CalendarEventCache(directory: URL(fileURLWithPath: cachePath))
        let store: AppStore
        if let root = demoRoot {
            // The interactive fixture preserves its isolated profile across the real relaunch.
            precondition(cachePath == root.appendingPathComponent("cache").path)
            precondition(Bundle.main.bundleURL.resolvingSymlinksInPath().path == root.appendingPathComponent("run/now.app").resolvingSymlinksInPath().path)
            precondition(AppPreferences.standard.data(forKey: AppStore.storageKey) != nil,
                         "The demo must seed its own profile; never fall through to migration")
            store = AppStore(eventCache: cache)
        } else {
            store = AppStore(eventCache: cache, initialState: Persisted(settings: settings))
        }
        store.loginItem = UpdaterTestLoginItem()
        return AppDelegate(store: store)
    }

    @MainActor private static var smokeTimer: Timer?
    @MainActor private static var installStarted = false
    @MainActor private static func startDemoSmoke() {
        guard demoRoot != nil else { fatalError("GUI smoke requires a demo session") }
        if ProcessInfo.processInfo.environment["NOW_TEST_DEMO_VERSION"] != UpdateLogic.currentVersion {
            NowApp.appDelegate.updateController.check(userInitiated: true)
        }
        smokeTimer = AppStore.commonTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { demoSmokeTick() }
        }
    }

    @MainActor private static func demoSmokeTick() {
        let delegate = NowApp.appDelegate
        let controller = delegate.updateController
        let target = ProcessInfo.processInfo.environment["NOW_TEST_DEMO_VERSION"]!
        if UpdateLogic.currentVersion == target {
            guard controller.windowContent == .installed(version: target),
                  NSApp.windows.contains(where: { $0.isVisible && $0.title == "Update Complete" }) else { return }
            precondition(controller.smokeState.pendingInstallVersion == nil)
            precondition(delegate.store.settings.reminderScreen == .mainDisplay)
            precondition(delegate.store.subscriptions.isEmpty && delegate.store.nativeCalendars.isEmpty)
            precondition(delegate.store.featureGuides?.updateIDs == [FeatureGuideCatalog.displayID])
            try! Data(target.utf8).write(to: demoRoot!.appendingPathComponent("gui-success"))
            smokeTimer?.invalidate()
        } else if controller.stagedVersion == target && !installStarted {
            installStarted = true
            controller.install()
        }
    }
}

/// The pinned bundle ID must never change the installed app's Notification Center or login item.
@MainActor
final class UpdaterTestNotifications: NotificationTransport {
    var response: ((String, String) -> Void)?
    private var allowed = false
    func permission() async -> NotificationPermission {
        NotificationPermission(authorization: allowed ? .allowed : .notRequested, alerts: true, sound: true)
    }
    func requestPermission() async throws { allowed = true }
    func add(_ notification: ReminderNotification) async throws {}
    func remove(_ ids: [String]) {}
}

final class UpdaterTestLoginItem: AppStore.LoginItemControlling {
    var currentStatus: AppStore.LoginItemStatus = .notRegistered
    func register() throws { currentStatus = .enabled }
    func unregister() throws { currentStatus = .notRegistered }
}
