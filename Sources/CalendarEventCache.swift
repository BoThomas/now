import Foundation
import NowCore

/// Application directory selection belongs to the macOS shell, never the core.
extension CalendarEventCache {
    convenience init(directory: URL? = nil) {
        self.init(directory: directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.thomasboch.now", isDirectory: true)
            .appendingPathComponent("CalendarCache-v1", isDirectory: true))
    }
}
