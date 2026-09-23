import AppKit
import NowCore

/// Single funnel for opening a join link from any meeting surface (menu,
/// fullscreen reminder, details popover, notification). Which URL opens is
/// decided by the pure `JoinTarget` policy; this adapter only answers the
/// "is an app registered for this URL?" question through LaunchServices and
/// performs the open. Must run on the main actor.
@MainActor
enum JoinOpener {
    /// The URL Join would open for `link` under `preferNative`.
    static func target(for link: URL, preferNative: Bool) -> URL {
        JoinTarget.resolve(link: link, preferNative: preferNative) { url in
            NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        }
    }

    static func open(_ link: URL, preferNative: Bool) {
        NSWorkspace.shared.open(target(for: link, preferNative: preferNative))
    }
}
