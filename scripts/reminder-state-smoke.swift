import Foundation
import AppKit

@main
struct ReminderStateSmoke {
    struct Failure: Error { let message: String }

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        print("PASS: \(message)")
    }

    @MainActor static func waitFor(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try require(condition(), label)
    }

    @MainActor static func run(base: String) async throws {
        guard let domain = Bundle.main.bundleIdentifier, domain.hasPrefix("com.thomasboch.now.review-smoke.") else {
            throw Failure(message: "This test must run in its disposable test bundle")
        }
        // A unique bundle domain plus a volatile initial state prevents loading
        // or overwriting the real app's preferences (including legacy migration).
        let a = CalendarSubscription(name: "Synthetic A", url: base + "/a", colorIndex: 0)
        let b = CalendarSubscription(name: "Synthetic B", url: base + "/b", colorIndex: 1)
        let seed = Persisted(subscriptions: [a, b])
        UserDefaults.standard.setVolatileDomain([AppStore.storageKey: try JSONEncoder().encode(seed)], forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        }
        _ = NSApplication.shared
        let store = AppStore()
        // Never start AppStore: no EventKit fetch, login-item changes, or timers.
        var clock = Date()
        store.now = { clock }
        var deliveries: [String] = []
        store.onAlert = { deliveries.append(contentsOf: $0.map(\.uid)) }
        store.resync(subscriptionID: a.id)
        try await waitFor("initial synthetic feed loads") { store.events.contains { $0.uid == "a" } }
        store.tick()
        try require(deliveries == ["a"], "production tick records the first due reminder")
        let eventA = store.events.first { $0.uid == "a" }!
        let snoozeUntil = clock.addingTimeInterval(300)
        store.snooze([eventA.id: snoozeUntil])
        _ = await AppStore.fetchData(base + "/a-empty")
        store.resync(subscriptionID: a.id)
        try await waitFor("one source snapshot omits the event") { store.events.isEmpty }
        store.resync(subscriptionID: b.id)
        try await waitFor("another source publishes a snapshot") { store.events.contains { $0.uid == "b" } }
        store.subscriptions[1].colorHex = "#FF0000"
        _ = await AppStore.fetchData(base + "/a-full")
        store.resync(subscriptionID: a.id)
        try await waitFor("temporarily missing event returns") { store.events.contains { $0.uid == "a" } }
        store.tick()
        try require(deliveries == ["a"], "F09: unrelated refresh and recolor preserve the snooze")
        clock = snoozeUntil
        store.tick()
        try require(deliveries == ["a", "a"], "F09: retained snooze re-fires at its original deadline")

        let alerts = AlertController()
        let updates = UpdateController(store: store)
        let controller = MenuBarController(store: store, alerts: alerts, updates: updates, openSettings: {}, quit: {})
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let normalIDs = menu.items.compactMap { ($0.representedObject as? MeetingEvent)?.id }
        store.pauseIndefinitely()
        store.snooze([eventA.id: clock.addingTimeInterval(-1)])
        store.tick()
        try require(deliveries.count == 2, "F11: pause suppresses an otherwise due reminder")
        controller.menuNeedsUpdate(menu)
        let rows = menu.items.filter { $0.representedObject is MeetingEvent }
        try require(rows.compactMap { ($0.representedObject as? MeetingEvent)?.id } == normalIDs && rows.count == 2,
                    "F11: paused native menu retains the same agenda rows")
        try require(rows.allSatisfy { $0.isEnabled && $0.target === controller && $0.action.map(NSStringFromSelector) == "joinAction:" },
                    "F11: paused rows retain enabled Join actions and their targets")
        guard let resume = menu.items.first(where: { $0.title == "Resume Now" }), let action = resume.action else {
            throw Failure(message: "Resume action missing")
        }
        try require(NSApp.sendAction(action, to: resume.target, from: resume) && !store.isPaused,
                    "F11: native Resume action clears pause")
        store.tick()
        try require(deliveries.count == 3, "F11: reminder delivery resumes after Resume Now")
        // Retain the actual scheduled timer independently, then release its
        // owner. Reflection keeps this lifecycle check out of the production API.
        var disposable: MenuBarController? = MenuBarController(store: store, alerts: alerts, updates: updates, openSettings: {}, quit: {})
        weak var releasedController = disposable
        guard let timer = Mirror(reflecting: disposable!).children.first(where: { $0.label == "buttonTimer" })?.value as? Timer else {
            throw Failure(message: "Controller timer missing")
        }
        try require(timer.isValid, "B3: controller owns a live repeating timer")
        disposable = nil
        try require(releasedController == nil, "B3: controller deinitializes when released")
        try require(!timer.isValid, "B3: deinit invalidates the scheduled timer")
        // Never invoke Join: synthetic URLs must not open a browser.
    }

    @MainActor static func main() async {
        setbuf(stdout, nil)
        do {
            try await run(base: CommandLine.arguments[1])
            print("REMINDER STATE SMOKE OK")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
