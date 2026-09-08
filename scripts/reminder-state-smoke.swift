import Foundation
import AppKit

@MainActor enum QuitSmoke {
    static var response: NSApplication.ModalResponse = .alertThirdButtonReturn
    static var buttons: [String] = []
    static var terminations = 0
    static func respond(to alert: NSAlert) -> NSApplication.ModalResponse {
        buttons = alert.buttons.map(\.title)
        return response
    }
    static func terminate() { terminations += 1 }

    static func run() throws {
        guard let domain = Bundle.main.bundleIdentifier, domain.hasPrefix("com.thomasboch.now.review-smoke.") else {
            throw ReminderStateSmoke.Failure(message: "Quit test requires disposable bundle")
        }
        UserDefaults.standard.setVolatileDomain([AppStore.storageKey: try JSONEncoder().encode(Persisted())], forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        }
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        delegate.updateWindow = window
        window.orderFront(nil)
        response = .alertThirdButtonReturn
        delegate.handleQuitRequest()
        try ReminderStateSmoke.require(buttons == ["Quit now", "Close Window", "Cancel"] && window.isVisible && terminations == 0,
            "update-window Quit offers shared confirmation; Cancel keeps app and window")
        response = .alertSecondButtonReturn
        delegate.handleQuitRequest()
        try ReminderStateSmoke.require(!window.isVisible && terminations == 0, "Close Window does not quit the app")
        window.orderFront(nil)
        response = .alertFirstButtonReturn
        delegate.handleQuitRequest()
        try ReminderStateSmoke.require(terminations == 1, "confirmed Quit invokes termination")
        response = .alertThirdButtonReturn
        delegate.handleQuitFromWindow(window, closeTitle: "Close Settings")
        try ReminderStateSmoke.require(buttons == ["Quit now", "Close Settings", "Cancel"], "Settings retains its existing dialog choices")
        window.close()
    }
}

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
        var settingsOpened = false
        let controller = MenuBarController(store: store, alerts: alerts, updates: updates, openSettings: { settingsOpened = true }, quit: {})
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let information = menu.items.filter { $0.action == nil && $0.submenu == nil && !$0.isSeparatorItem }
        try require(!information.isEmpty && information.allSatisfy { !$0.isEnabled }, "menu informational rows are disabled before AppKit validation")
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
        func requestCounts() async throws -> [String: Int] {
            let (data, _) = await AppStore.fetchData(base + "/stats")
            guard let data else { throw Failure(message: "Request counts unavailable") }
            return try JSONDecoder().decode([String: Int].self, from: data)
        }
        let beforeAdd = try await requestCounts()
        clock = clock.addingTimeInterval(1)
        store.addSubscription(name: "Synthetic C", urlString: base + "/c")
        try await waitFor("B7b: addition completes a full refresh") { !store.isRefreshing && store.events.contains { $0.uid == "c" } }
        let afterAdd = try await requestCounts()
        try require(["/a", "/b", "/c"].allSatisfy { afterAdd[$0, default: 0] - beforeAdd[$0, default: 0] == 1 },
                    "B7b: adding requests each enabled feed exactly once")
        try require(store.lastChecked == clock, "B7b: successful full refresh records completion time")
        let cachedB = store.events.first { $0.uid == "b" }!
        _ = await AppStore.fetchData(base + "/b-fail")
        clock = clock.addingTimeInterval(1)
        store.refresh()
        try await waitFor("B7b: partial failure completes") { !store.isRefreshing }
        try require(store.lastChecked == clock && store.errors[b.id] != nil, "B7b: failed check advances time and retains its error")
        try require(store.events.first { $0.uid == "a" }?.title == "Updated A", "B7b: healthy calendar still updates when another fails")
        try require(store.events.first { $0.uid == "b" }?.title == cachedB.title, "B7b: failed calendar retains cached events")
        controller.menuNeedsUpdate(menu)
        try require(menu.items.contains { $0.title.hasPrefix("Last synced ") }, "B7b: dropdown labels check completion accurately")
        guard let failure = menu.items.first(where: { $0.title == "1 calendar failed to sync · Details…" }), let failureAction = failure.action else {
            throw Failure(message: "Sync failure details action missing")
        }
        try require((failure.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == NSColor.systemRed, "sync failure summary is red")
        try require(NSApp.sendAction(failureAction, to: failure.target, from: failure) && settingsOpened, "B7b: failure summary opens Settings")
        _ = await AppStore.fetchData(base + "/b-ok")
        store.refresh()
        try await waitFor("B7b: recovery completes") { !store.isRefreshing }
        controller.menuNeedsUpdate(menu)
        try require(store.errors.isEmpty && !menu.items.contains { $0.title.contains("failed to sync") }, "B7b: recovery removes failure summary")
        _ = await AppStore.fetchData(base + "/b-fail")
        store.refresh()
        try await waitFor("B7b: repeat failure completes") { !store.isRefreshing }
        let beforeRemove = try await requestCounts()
        clock = clock.addingTimeInterval(1)
        store.removeSubscription(b.id)
        try require(store.errors[b.id] == nil, "B7b: removing source immediately clears its error")
        try await waitFor("B7b: removal completes a full refresh") { !store.isRefreshing }
        let afterRemove = try await requestCounts()
        try require(["/a", "/c"].allSatisfy { afterRemove[$0, default: 0] - beforeRemove[$0, default: 0] == 1 } && afterRemove["/b"] == beforeRemove["/b"],
                    "B7b: removing requests remaining feeds once and never the removed feed")
        try require(store.lastChecked == clock, "B7b: removal refresh updates completion time")

        _ = await AppStore.fetchData(base + "/all-fail")
        clock = clock.addingTimeInterval(1)
        let cachedIDs = Set(store.events.map(\.id))
        store.refresh()
        try await waitFor("B7b: total failure completes") { !store.isRefreshing }
        controller.menuNeedsUpdate(menu)
        try require(store.lastChecked == clock && store.errors.count == 2 && Set(store.events.map(\.id)) == cachedIDs,
                    "B7b: total failure advances check time and preserves all cached events")
        try require(menu.items.contains { $0.title == "2 calendars failed to sync · Details…" }, "B7b: failure summary pluralizes multiple failures")
        _ = await AppStore.fetchData(base + "/all-ok")
        store.subscriptions[0].isEnabled = false
        let beforeEnable = try await requestCounts()
        let fullCheckTime = store.lastChecked
        store.subscriptions[0].isEnabled = true
        try await waitFor("B7b: re-enabled calendar loads") { store.events.contains { $0.uid == "a" } && store.errors[a.id] == nil }
        let afterEnable = try await requestCounts()
        try require(afterEnable["/a", default: 0] - beforeEnable["/a", default: 0] == 1 && afterEnable["/c"] == beforeEnable["/c"] && store.lastChecked == fullCheckTime,
                    "B7b: re-enable remains targeted and does not claim a new full check")

        let trackedMenu = controller.smokeMenu
        controller.menuNeedsUpdate(trackedMenu)
        let originalRows = trackedMenu.items
        controller.smokeBeginTracking()
        controller.smokeRefreshMenu(at: clock.addingTimeInterval(2))
        controller.smokeEndTracking()
        try require(trackedMenu.items.count == originalRows.count && zip(trackedMenu.items, originalRows).allSatisfy { $0 === $1 },
                    "elapsed sync label does not replace menu rows on timer ticks")
        try require(trackedMenu.items.filter { $0.action == nil && $0.submenu == nil }.allSatisfy { !$0.isEnabled },
                    "informational rows remain disabled after a tracking tick")

        clock = clock.addingTimeInterval(7)
        store.tick()
        let expectedSyncLabel = Fmt.syncStatus(store.lastChecked!, relativeTo: store.displayTime)
        try require(store.displayTime == clock && trackedMenu.items.contains { $0.title == expectedSyncLabel },
                    "menu sync label follows the same published clock as Settings without a menu timer tick")

        let reference = Date()
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let widths = [1.0, 9.0, 10.0, 59.0].map { seconds in
            (Fmt.syncStatus(reference.addingTimeInterval(-seconds), relativeTo: reference) as NSString).size(withAttributes: [.font: font]).width
        }
        try require(abs(widths[0] - widths[1]) < 0.1 && abs(widths[2] - widths[3]) < 0.1 && widths[2] > widths[0],
                    "sync digits stay steady within each digit count without reserved padding")

        // The preceding targeted recovery deliberately left the other source's
        // failure intact. Recover it before testing a successful empty agenda.
        store.refresh()
        try await waitFor("all sources recover before agenda checks") { !store.isRefreshing && store.errors.isEmpty }
        let fixtureTime = Date(timeIntervalSince1970: 1_800_000_000)
        clock = fixtureTime
        let many = (0..<20).map { index in
            MeetingEvent(uid: "limit-\(index)", title: "Meeting \(index)", start: fixtureTime.addingTimeInterval(Double(index) * 60),
                end: fixtureTime.addingTimeInterval(3600 + Double(index) * 60), location: nil, notes: nil, link: nil,
                calendarID: a.id, calendarName: "Synthetic A", colorIndex: 0)
        }
        store.commitEvents(many)
        for limit in AppSettings.allowedMenuMeetingLimits {
            store.settings.menuMeetingLimit = limit
            controller.menuNeedsUpdate(menu)
            let shown = menu.items.compactMap { $0.representedObject as? MeetingEvent }
            try require(shown.map(\.id) == Array(many.prefix(limit)).map(\.id), "native menu shows exactly \(limit) ordered meetings")
            try require(store.upcoming.count == 20, "menu limit leaves the full Settings agenda available")
        }
        controller.menuNeedsUpdate(trackedMenu)
        controller.smokeBeginTracking()
        store.settings.menuMeetingLimit = 3
        controller.smokeRefreshMenu(at: clock)
        controller.smokeEndTracking()
        try require(trackedMenu.items.filter { $0.representedObject is MeetingEvent }.count == 3,
                    "changing the limit rebuilds a tracked menu")
        try require(store.menuBarFocus?.date == fixtureTime, "focus uses the injected clock")
        clock = many.last!.end
        try require(store.upcoming.isEmpty && store.menuBarFocus == nil, "visibility and focus expire at the injected end boundary")
        controller.menuNeedsUpdate(menu)
        try require(menu.items.contains { $0.title == "No upcoming meetings" }, "native menu shows successful empty agenda wording")
        store.pause(for: 60)
        try require(store.isPaused, "pause begins using injected time")
        clock = clock.addingTimeInterval(60)
        try require(!store.isPaused, "pause expires exactly at injected boundary")
        store.resume()

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
            if CommandLine.arguments.contains("--quit") { try QuitSmoke.run() }
            else { try await run(base: CommandLine.arguments[1]) }
            print("REMINDER STATE SMOKE OK")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
