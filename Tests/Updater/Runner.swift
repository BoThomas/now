import Foundation
import NowCore

@main
enum UpdaterTestRunner {
    static func main() { NowApp.main() }

    @MainActor static func makeDelegate() -> AppDelegate {
        guard let cachePath = ProcessInfo.processInfo.environment["NOW_TEST_CACHE_ROOT"] else {
            preconditionFailure("Updater fixture requires a disposable cache")
        }
        var settings = AppSettings()
        settings.automaticUpdateChecks = false
        settings.launchAtLogin = false
        let cache = CalendarEventCache(directory: URL(fileURLWithPath: cachePath))
        return AppDelegate(store: AppStore(eventCache: cache, initialState: Persisted(settings: settings)))
    }
}
