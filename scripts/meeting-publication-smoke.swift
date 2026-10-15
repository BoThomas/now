import Combine
import Foundation
import NowCore

private final class PublicationLoginItem: AppStore.LoginItemControlling {
    var currentStatus: AppStore.LoginItemStatus { .notRegistered }
    func register() throws { fatalError("Publication smoke must not register login items") }
    func unregister() throws { fatalError("Publication smoke must not unregister login items") }
}

@MainActor private final class PublicationCounts {
    var activity = 0
    var error = 0
    var store = 0
}

extension NotificationSmoke {
    /// No AppDelegate, NSApplication, windows, real probes, feeds or notifications.
    @MainActor static func publicationTests(root: URL) async {
        func require(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { print("FAIL: " + label); exit(1) }
        }
        var settings = AppSettings()
        settings.automaticUpdateChecks = false
        settings.launchAtLogin = false
        settings.inMeetingDelivery = .normal
        let source = MeetingActivitySource(snapshot: { fatalError("No live audio probes in publication smoke") })
        let store = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("publication-cache")),
            initialState: Persisted(subscriptions: [], settings: settings), meetingActivitySource: source)
        store.loginItem = PublicationLoginItem()
        store.start()
        require(source.onActivityChange != nil && source.onProbeFailure != nil, "production callbacks installed")
        require(store.meetingActivity == .unknown && store.meetingDetectionError == nil, "initial detection state")
        let counts = PublicationCounts()
        let activityToken = store.$meetingActivity.dropFirst().sink { _ in counts.activity += 1 }
        let errorToken = store.$meetingDetectionError.dropFirst().sink { _ in counts.error += 1 }
        let storeToken = store.objectWillChange.sink { counts.store += 1 }

        // These synchronous main-actor callbacks cannot race asynchronous refreshes.
        for _ in 0..<20_000 { source.onActivityChange?(.unknown) }
        require(counts.store == 0, "20,000 unchanged unknown callbacks do not publish")
        for _ in 0..<20_000 { source.onActivityChange?(.inactive) }
        require(counts.activity == 1 && counts.error == 0, "inactive transition publishes once, not nil errors")
        for _ in 0..<20_000 { source.onProbeFailure?("First failure") }
        require(counts.error == 1, "repeated equal probe failure publishes once")
        source.onActivityChange?(.inactive)
        require(counts.activity == 1 && counts.error == 2 && store.meetingDetectionError == nil,
            "unchanged known activity still clears a previous error")
        source.onProbeFailure?("First failure")
        source.onProbeFailure?("Different failure")
        require(counts.error == 4, "a later failure and changed diagnostic remain observable")
        for _ in 0..<20_000 { source.onActivityChange?(.unknown) }
        require(counts.activity == 2 && counts.error == 4 && store.meetingDetectionError == "Different failure",
            "unknown transition publishes but never erases a failure")
        source.onActivityChange?(.inactive)
        require(counts.activity == 3 && counts.error == 5 && store.meetingDetectionError == nil,
            "recovery publishes activity and clears error")
        for _ in 0..<20_000 { source.onActivityChange?(.inactive) }
        require(counts.store == 8, "only three activity changes and five error changes invalidate the store")
        for _ in 0..<20_000 { source.onActivityChange?(.meeting(.zoom)) }
        require(counts.activity == 4, "equal detected meeting values publish once")
        source.onActivityChange?(.meeting(.teams))
        require(counts.activity == 5, "provider changes remain observable within detected meetings")
        source.onProbeFailure?("Meeting failure")
        source.onActivityChange?(.meeting(.teams))
        require(counts.store == 12 && counts.error == 7 && store.meetingDetectionError == nil,
            "unchanged detected meeting can recover a failure without a redundant activity publication")
        activityToken.cancel()
        errorToken.cancel()
        storeToken.cancel()
        await withCheckedContinuation { continuation in
            store.prepareForTermination { continuation.resume() }
        }
        print("PUBLICATION SMOKE OK — equal callbacks suppressed; transitions, unknown and recovery preserved")
    }
}
