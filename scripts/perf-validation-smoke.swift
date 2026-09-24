import Foundation
import NowCore
import AppKit

/// Measurement harness for the uptime/CPU analysis: drives production hot
/// paths (tick, menu timer, persistence, notification reconcile) with
/// synthetic data and times them. It runs ONLY inside the disposable bundle
/// created by scripts/perf-validation-smoke.py:
/// - unique preferences domain (removed on exit), volatile-seeded state,
/// - AppStore is constructed but NEVER `start()`ed: no timers, no EventKit
///   fetch, no login-item sync, no real notification transport,
/// - an injected cache directory and a fake NotificationTransport.
///
/// Sections:
///   M1 identity/due micro-benchmarks (per-event hashing in the 1 Hz tick)
///   M2 tick() ablation around notifySyncProblems persistence
///   M3 status-item 1 Hz rebuild + "Last synced" formatter
///   M4 open-menu tracking tick (structure signature + row updates)
///   M5 StoredPreferences.save costs (sync tracker, ledger, receipts)
///   M6 accelerated multi-day soak with an injected clock (boundedness)
///   M7 per-second notifications reconcile with live receipts
///   M8 CoreAudio meeting-probe baseline (informational)
@main
enum PerfValidationSmoke {
    struct Failure: Error { let message: String }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
        print("PASS: \(message)")
    }

    // MARK: Timing

    struct Timing { let median: Double; let p95: Double; let mean: Double }

    @MainActor
    static func measure(_ label: String, iterations: Int, warmup: Int = 15, scale: Double = 1, unit: String = "ms/op", _ body: () throws -> Void) rethrows -> Timing {
        for _ in 0..<warmup { try body() }
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let began = DispatchTime.now().uptimeNanoseconds
            try body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000 * scale)
        }
        samples.sort()
        let timing = Timing(median: samples[samples.count / 2],
                            p95: samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))],
                            mean: samples.reduce(0, +) / Double(samples.count))
        let padded = label.padding(toLength: 58, withPad: " ", startingAt: 0)
        print(String(format: "MEASURE %@ median %9.4f  p95 %9.4f  mean %9.4f  %@", padded, timing.median, timing.p95, timing.mean, unit))
        return timing
    }

    static func settle() async { try? await Task.sleep(nanoseconds: 120_000_000) }

    // MARK: Fixtures

    /// Events spread across the fetch window like a real accepted snapshot.
    @MainActor
    static func windowEvents(count: Int, calendarID: UUID, calendarName: String, now: Date, notes: String? = nil) -> [MeetingEvent] {
        let window: TimeInterval = 14 * 86400 + 6 * 3600
        return (0..<count).map { index in
            let start = now.addingTimeInterval(-6 * 3600 + window * Double(index) / Double(max(1, count)))
            return MeetingEvent(uid: "series-\(index % 40)", title: "Meeting \(index)",
                                start: start, end: start.addingTimeInterval(1800),
                                location: nil, notes: notes, link: URL(string: "https://zoom.us/j/9\(index % 100)"),
                                calendarID: calendarID, calendarName: calendarName, colorIndex: index % 10)
        }
    }

    // MARK: Run

    @MainActor
    static func main() async throws {
        guard let domain = Bundle.main.bundleIdentifier, domain.hasPrefix("com.thomasboch.now.perf-smoke.") else {
            throw Failure(message: "This measurement must run in its disposable test bundle")
        }
        let configuration = ProcessInfo.processInfo.environment["NOW_TEST_CONFIGURATION"] ?? "debug"
        print("PERF configuration=\(configuration) cores=\(ProcessInfo.processInfo.activeProcessorCount) domain=\(domain)")
        guard let cacheRoot = ProcessInfo.processInfo.environment["NOW_TEST_CACHE_ROOT"] else {
            throw Failure(message: "NOW_TEST_CACHE_ROOT is required")
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        _ = NSApplication.shared

        let subscription = CalendarSubscription(name: "Perf Synthetic", url: "http://127.0.0.1:1/unused", colorIndex: 0)
        var settings = AppSettings()
        settings.soundEnabled = false
        let clock = Date()
        let store = AppStore(eventCache: CalendarEventCache(directory: URL(fileURLWithPath: cacheRoot).appendingPathComponent("main")),
                             initialState: Persisted(subscriptions: [subscription], settings: settings))
        store.now = { clock }
        var deliveries = 0
        store.onAlert = { _ in deliveries += 1 }
        await store.restoreCachedEvents()

        let measureDefaults = UserDefaults(suiteName: domain + ".measure")!
        defer { measureDefaults.removePersistentDomain(forName: domain + ".measure") }

        // M1 — identity hashing done per event inside the 1 Hz tick's due filter.
        print("\n=== M1: per-event identity work in tick() ===")
        let probeEvent = windowEvents(count: 1, calendarID: subscription.id, calendarName: subscription.name, now: clock)[0]
        _ = measure("NotificationLogic.eventKey(event)", iterations: 2000, scale: 1000, unit: "us/op") {
            _ = NotificationLogic.eventKey(probeEvent)
        }
        _ = measure("NotificationLogic.fingerprint(event)", iterations: 2000, scale: 1000, unit: "us/op") {
            _ = NotificationLogic.fingerprint(probeEvent)
        }
        let ledger = ReminderLedger()
        let futureEvent = MeetingEvent(uid: "future", title: "Future", start: clock.addingTimeInterval(3600),
                                       end: clock.addingTimeInterval(5400), location: nil, notes: nil, link: nil,
                                       calendarID: subscription.id, calendarName: subscription.name, colorIndex: 0)
        _ = measure("ReminderLedger.due (future undue event)", iterations: 1000, scale: 1000, unit: "us/op") {
            _ = ledger.due(futureEvent, leads: [300], now: clock)
        }
        _ = measure("ReminderLedger.due (ended event, early exit)", iterations: 1000, scale: 1000, unit: "us/op") {
            _ = ledger.due(probeEvent, leads: [300], now: clock)
        }
        let dueEvent = MeetingEvent(uid: "due", title: "Due", start: clock.addingTimeInterval(-60), end: clock.addingTimeInterval(1800),
                                    location: nil, notes: nil, link: nil, calendarID: subscription.id, calendarName: subscription.name, colorIndex: 0)
        _ = measure("ReminderLedger.due (due event)", iterations: 1000, scale: 1000, unit: "us/op") {
            _ = ledger.due(dueEvent, leads: [300], now: clock)
        }
        _ = measure("ReminderLedger.suppressAfterJoin (due path)", iterations: 1000, scale: 1000, unit: "us/op") {
            _ = ledger.suppressAfterJoin(dueEvent, detectionEnabled: false, activity: .inactive)
        }

        // M5 — the exact production persistence call shapes (injected suite).
        print("\n=== M5: StoredPreferences.save costs ===")
        var syncTracker = SyncNotificationTracker()
        _ = syncTracker.candidates(failed: [UUID(), UUID(), UUID()], now: clock)
        _ = measure("save(syncTracker) [every tick via notifySyncProblems]", iterations: 400, unit: "ms/op") {
            StoredPreferences.save(syncTracker, key: "perf.sync", label: "Perf", defaults: measureDefaults)
        }
        for size in [500, 2000, 5000, 20000] {
            var sized = ReminderLedger()
            let ledgerEvents = windowEvents(count: size, calendarID: subscription.id, calendarName: subscription.name, now: clock)
            for (index, event) in ledgerEvents.enumerated() {
                if index % 10 == 0 { sized.schedule(event, until: event.start.addingTimeInterval(600), leads: [300]) }
                else { sized.record(event) }
            }
            _ = measure("save(ReminderLedger, \(size) entries) [per commitEvents]", iterations: 8, warmup: 2, unit: "ms/op") {
                StoredPreferences.save(sized, key: "perf.ledger.\(size)", label: "Perf", defaults: measureDefaults)
            }
        }
        for receiptsCount in [10, 50] {
            let payload: [String: ReminderNotification] = Dictionary(uniqueKeysWithValues: (0..<receiptsCount).map { index in
                let key = NotificationLogic.eventKey(probeEvent) + ".\(index)"
                let sanitized = ReminderNotification(id: "now.meeting.x.\(index)", keys: [key], fingerprints: [String(repeating: "a", count: 64)],
                                                     expires: clock.addingTimeInterval(3600), catchUp: false, title: "", body: "",
                                                     category: "now.meeting.false.false", sound: false,
                                                     deliveries: [key: ReminderDeliveryState(leads: [300])])
                return ("now.meeting.x.\(index)", sanitized)
            })
            _ = measure("save(receipts, \(receiptsCount) entries) [per reconcile change]", iterations: 12, warmup: 3, unit: "ms/op") {
                StoredPreferences.save(payload, key: "perf.receipts.\(receiptsCount)", label: "Perf", defaults: measureDefaults)
            }
        }

        // Sweep sizes for the per-second paths.
        let sizes = [250, 1000, 2000]
        var tickBeforeRefresh: [Int: Timing] = [:]
        var tickSteady: [Int: Timing] = [:]
        var menuTickBeforeBuild: [Int: Timing] = [:]
        var menuTickAfterBuild: [Int: Timing] = [:]

        print("\n=== M2a: tick() before initial refresh completes (notifySyncProblems early-returns) ===")
        for size in sizes {
            store.smokeCommitEvents(windowEvents(count: size, calendarID: subscription.id, calendarName: subscription.name, now: clock))
            tickBeforeRefresh[size] = measure("tick(), \(size) events, pre-refresh", iterations: 120) { store.smokeTick() }
        }

        // Complete the initial refresh once: notifySyncProblems now runs every tick.
        let request = store.smokeBeginFullRefresh(subscriptionIDs: [subscription.id])
        store.smokeFinishRefresh(fetched: [subscription], requestID: request)
        try require(UserDefaults.standard.data(forKey: "local.tboch.now.sync-notifications.v1") != nil,
                    "a completed initial refresh persists the sync tracker at least once")

        print("\n=== M2b: tick() steady state, sync-problem notifications OFF (still persists each tick) ===")
        for size in sizes {
            let committed = windowEvents(count: size, calendarID: subscription.id, calendarName: subscription.name, now: clock)
            store.smokeCommitEvents(committed)
            tickSteady[size] = measure("tick(), \(size) events, steady", iterations: 120) { store.smokeTick() }
            _ = measure("commitEvents(), \(size) events [per refresh/source]", iterations: 10, warmup: 2) {
                store.smokeCommitEvents(committed)
            }
        }

        print("\n=== M2c: tick() steady state, sync notifications ON with a failing source ===")
        store.smokeMerge(results: [FetchResult(subscription: subscription, events: [], error: "synthetic outage", requestID: 1)])
        store.settings.notifySyncErrors = true
        store.smokeCommitEvents(windowEvents(count: 1000, calendarID: subscription.id, calendarName: subscription.name, now: clock))
        _ = measure("tick(), 1000 events, sync-on failing source", iterations: 120) { store.smokeTick() }
        try require(store.errors[subscription.id] != nil, "synthetic merge produced a persistent source error")

        // M3 — status-item per-second rebuild and the retained Last-synced item.
        print("\n=== M3: menu bar 1 Hz rebuild ===")
        let alerts = AlertController()
        let updates = UpdateController(store: store, brewManaged: false)
        let controller = MenuBarController(store: store, alerts: alerts, updates: updates, openSettings: {}, quit: {})
        for size in sizes {
            store.smokeCommitEvents(windowEvents(count: size, calendarID: subscription.id, calendarName: subscription.name, now: clock))
            menuTickBeforeBuild[size] = measure("menu tick, \(size) events, menu never opened", iterations: 120) {
                controller.smokeMenuTick()
            }
        }
        _ = measure("Fmt.syncStatus (RelativeDateTimeFormatter alloc)", iterations: 400, scale: 1000, unit: "us/op") {
            _ = Fmt.syncStatus(clock.addingTimeInterval(-120), relativeTo: clock)
        }
        let focusColors = [NSColor.systemBlue, NSColor.systemPurple, NSColor.systemGreen]
        _ = measure("Palette.dotClusterImage (3 dots)", iterations: 400, scale: 1000, unit: "us/op") {
            _ = Palette.dotClusterImage(colors: focusColors, size: 7)
        }
        let menuEvents = windowEvents(count: 1000, calendarID: subscription.id, calendarName: subscription.name, now: clock)
        _ = measure("AppStore.menuBarFocus (1000 events)", iterations: 200, unit: "ms/op") {
            _ = AppStore.menuBarFocus(events: menuEvents, elapsedStartMinutes: 10, now: clock)
        }
        _ = measure("MenuBarController.statusTooltip (1000 events)", iterations: 200, unit: "ms/op") {
            _ = MenuBarController.statusTooltip(events: menuEvents, now: clock)
        }
        store.smokeCommitEvents(menuEvents)
        controller.menuNeedsUpdate(controller.smokeMenu)
        menuTickAfterBuild[1000] = measure("menu tick, 1000 events, after first open (dead item)", iterations: 120) {
            controller.smokeMenuTick()
        }

        // M4 — per-second cost while the dropdown is tracking.
        print("\n=== M4: open-menu tracking tick (signature + row updates) ===")
        let fatNotes = String(repeating: "agenda item with details. ", count: 80) // ~2 KB
        store.smokeCommitEvents(windowEvents(count: 1000, calendarID: subscription.id, calendarName: subscription.name, now: clock, notes: fatNotes))
        controller.menuNeedsUpdate(controller.smokeMenu)
        controller.smokeBeginTracking()
        _ = measure("refreshOpenMenu in-place, 1000 visible x 2KB notes", iterations: 60) {
            controller.smokeRefreshMenu(at: clock.addingTimeInterval(1))
        }
        controller.smokeEndTracking()
        _ = measure("menuNeedsUpdate rebuild, 1000 visible x 2KB notes", iterations: 20, warmup: 3) {
            controller.menuNeedsUpdate(controller.smokeMenu)
        }

        // M7 — per-second reconcile over accepted receipts.
        print("\n=== M7: notifications reconcile with live receipts ===")
        let notifications = ReminderNotificationController(transport: PerfNullTransport(), defaults: measureDefaults)
        store.connectNotifications(notifications)
        store.settings.notifySyncErrors = false
        store.settings.reminderDelivery = .notification
        let dueMeetings = (0..<12).map { index in
            MeetingEvent(uid: "receipt-\(index)", title: "Receipt \(index)", start: clock.addingTimeInterval(Double(30 + index)),
                         end: clock.addingTimeInterval(3600), location: nil, notes: nil, link: URL(string: "https://zoom.us/j/1\(index)"),
                         calendarID: subscription.id, calendarName: subscription.name, colorIndex: index % 10)
        }
        store.smokeCommitEvents(dueMeetings)
        store.smokeTick()
        await settle()
        let receiptsCount = store.notifications?.receipts.count ?? 0
        print("PERF receipts after due deliveries: \(receiptsCount)")
        try require(receiptsCount >= 10, "due meetings produced accepted notification receipts")
        _ = measure("notifications.reconcile() (\(receiptsCount) receipts)", iterations: 300) {
            notifications.reconcile()
        }
        _ = measure("tick() with \(receiptsCount) receipts, 12 events", iterations: 120) {
            store.smokeTick()
        }

        // M6 — accelerated multi-day soak on a fresh store: boundedness of
        // events, ledger, and receipts across simulated weeks.
        print("\n=== M6: accelerated 16-day soak (15-min refresh + 1 Hz tick cadence) ===")
        let soakDomain = domain + ".soak"
        let soakDefaults = UserDefaults(suiteName: soakDomain)!
        defer { soakDefaults.removePersistentDomain(forName: soakDomain) }
        var soakSettings = AppSettings()
        soakSettings.soundEnabled = false
        let soakSub = CalendarSubscription(name: "Soak", url: "http://127.0.0.1:1/unused", colorIndex: 0)
        var soakClock = Date(timeIntervalSince1970: 1_700_000_000)
        let soakStore = AppStore(eventCache: CalendarEventCache(directory: URL(fileURLWithPath: cacheRoot).appendingPathComponent("soak")),
                                  initialState: Persisted(subscriptions: [soakSub], settings: soakSettings))
        soakStore.now = { soakClock }
        var soakDeliveries = 0
        soakStore.onAlert = { _ in soakDeliveries += 1 }
        let soakController = ReminderNotificationController(transport: PerfNullTransport(), defaults: soakDefaults)
        soakStore.connectNotifications(soakController)
        await soakStore.restoreCachedEvents()
        let soakRequest = soakStore.smokeBeginFullRefresh(subscriptionIDs: [soakSub.id])
        soakStore.smokeFinishRefresh(fetched: [soakSub], requestID: soakRequest)

        let soakNotes = String(repeating: "note ", count: 200)
        let calendar = Calendar(identifier: .gregorian)
        func soakSnapshot(_ now: Date) -> [MeetingEvent] {
            let windowStart = now.addingTimeInterval(-6 * 3600)
            let windowEnd = now.addingTimeInterval(14 * 86400)
            let todayZero = calendar.startOfDay(for: now)
            return (-2...15).flatMap { dayOffset in
                (0..<10).compactMap { slot -> MeetingEvent? in
                    let start = todayZero.addingTimeInterval(Double(dayOffset) * 86400 + Double(9 * 3600 + slot * 3600))
                    guard start >= windowStart, start <= windowEnd else { return nil }
                    return MeetingEvent(uid: "standup-\(slot)", title: "Recurring \(slot)", start: start,
                                        end: start.addingTimeInterval(1800), location: nil, notes: soakNotes,
                                        link: URL(string: "https://zoom.us/j/42\(slot)"),
                                        calendarID: soakSub.id, calendarName: soakSub.name, colorIndex: slot % 10)
                }
            }
        }
        let days = 16
        let stepsPerDay = 96
        var ledgerEntriesSamples: [Int] = []
        var ledgerBytesSamples: [Int] = []
        var receiptsSamples: [Int] = []
        var eventsSamples: [Int] = []
        for step in 0...(days * stepsPerDay) {
            soakClock = soakClock.addingTimeInterval(900)
            soakStore.smokeCommitEvents(soakSnapshot(soakClock), observedCalendarIDs: [soakSub.id])
            soakStore.smokeTick()
            if step % stepsPerDay == 0 {
                let ledgerData = UserDefaults.standard.data(forKey: "local.tboch.now.reminder-ledger.v1")
                let entries = (ledgerData.flatMap { try? JSONDecoder().decode(ReminderLedger.self, from: $0) })?.entries.count ?? -1
                ledgerEntriesSamples.append(entries)
                ledgerBytesSamples.append(ledgerData?.count ?? 0)
                receiptsSamples.append(soakController.receipts.count)
                eventsSamples.append(soakStore.events.count)
            }
        }
        print("PERF soak events/day:     \(eventsSamples)")
        print("PERF soak ledger entries: \(ledgerEntriesSamples)")
        print("PERF soak ledger bytes:   \(ledgerBytesSamples)")
        print("PERF soak receipts:       \(receiptsSamples)")
        print("PERF soak deliveries:     \(soakDeliveries)")
        try require(abs(eventsSamples[2] - eventsSamples[eventsSamples.count - 1]) <= 2,
                    "event list stays bounded across simulated days (rolling fetch window)")
        try require((ledgerEntriesSamples.max() ?? 0) <= 200,
                    "reminder ledger stays bounded across simulated days")
        try require((ledgerBytesSamples.max() ?? 0) <= 200_000,
                    "persisted reminder history stays small across simulated days")
        try require((receiptsSamples.max() ?? 0) <= 32,
                    "notification receipts stay bounded across simulated days")
        try require((140...180).contains(soakDeliveries),
                    "each simulated occurrence reminds exactly once (no re-alert runaway)")

        // M8 — informational CoreAudio probe baseline on this machine.
        print("\n=== M8: CoreAudio meeting probe baseline ===")
        for round in 0..<3 {
            let began = DispatchTime.now().uptimeNanoseconds
            switch MeetingActivityProbe.snapshot() {
            case .success(let owners):
                let ms = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
                print(String(format: "PERF probe round %d: %.4f ms, %d active-input owners", round, ms, owners.count))
            case .failure(let error):
                print("PERF probe round \(round): unavailable (\(error.message))")
            }
        }

        // Summary — the per-second main-thread budget at each calendar size.
        print("\n=== Summary: steady 1 Hz main-thread budget (tick + menu tick) ===")
        for size in sizes {
            let tick = tickSteady[size]?.median ?? 0
            let menu = (menuTickAfterBuild[size] ?? menuTickBeforeBuild[size])?.median ?? 0
            let total = tick + menu
            print(String(format: "PERF budget %5d events: tick %8.4f ms + menu %8.4f ms = %8.4f ms/s  (~%.2f%% of one core)",
                         size, tick, menu, total, total / 10))
        }
        if let before = tickBeforeRefresh[1000]?.median, let steady = tickSteady[1000]?.median {
            print(String(format: "PERF tick steady-state delta after initial refresh: %+.4f ms (pre %.4f, steady %.4f; run-noise bound — the direct save(syncTracker) median above is the authoritative per-tick persistence cost)",
                         steady - before, before, steady))
        }
        if let beforeMenu = menuTickBeforeBuild[1000]?.median, let afterMenu = menuTickAfterBuild[1000]?.median {
            print(String(format: "PERF retained last-sync item adds ~%.4f ms per menu tick (before %.4f, after %.4f)",
                         max(0, afterMenu - beforeMenu), beforeMenu, afterMenu))
        }
        print("\nPERF validation completed")
    }
}

@MainActor
private final class PerfNullTransport: NotificationTransport {
    func permission() async -> NotificationPermission {
        NotificationPermission(authorization: .allowed, alerts: true, sound: true)
    }
    func requestPermission() async throws {}
    func add(_ notification: ReminderNotification) async throws {}
    func remove(_ ids: [String]) {}
}
