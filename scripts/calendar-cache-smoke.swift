import Foundation
import AppKit

final class OfflineProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var forcedOffline = CommandLine.arguments[1].hasPrefix("offline")
    static func setOffline(_ value: Bool) { lock.lock(); forcedOffline = value; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }; return forcedOffline
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) }
    override func stopLoading() {}
}

@main struct CacheSmoke {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        print("PASS: \(message)")
    }
    @MainActor static func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(condition(), label)
    }
    static func save(_ snapshot: CalendarCacheSnapshot, to cache: CalendarEventCache) async -> String? {
        await withCheckedContinuation { continuation in cache.save(snapshot) { continuation.resume(returning: $0) } }
    }
    @MainActor static func run() async throws {
        let args = CommandLine.arguments, phase = args[1], base = args[2]
        guard let domain = Bundle.main.bundleIdentifier, domain.hasPrefix("com.thomasboch.now.cache-smoke.") else { throw Failure(message: "requires disposable bundle") }
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        var a = CalendarSubscription(name: "Live A", url: base + "/a", colorIndex: 0)
        a.id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        var b = CalendarSubscription(name: "Live B", url: base + "/b", colorIndex: 1)
        b.id = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let cache = CalendarEventCache(directory: URL(fileURLWithPath: args[3]))
        _ = NSApplication.shared
        if phase == "gui" {
            try gui(a: a, b: b, domain: domain)
            return
        }
        if phase == "storage" {
            try await storage(cache: cache, a: a, b: b)
            return
        }
        let store = AppStore(eventCache: cache, initialState: Persisted(subscriptions: [a, b]))
        if phase == "edit" {
            // A → B → A before disk restoration must not revive the A snapshot.
            store.subscriptions[0].url = base + "/replacement"
            store.subscriptions[0].url = a.url
            await store.restoreCachedEvents()
            try require(!store.events.contains { $0.calendarID == a.id }, "source replacement during restore cannot resurrect saved A")
            await cache.flush()
            let disk = await cache.load(subscriptions: [a, b])
            try require(disk.snapshots[a.id] == nil && disk.snapshots[b.id] != nil, "URL replacement removes only its own disk snapshot")
            store.subscriptions[1].isEnabled = false
            await cache.flush()
            try require((await cache.load(subscriptions: [b])).snapshots[b.id] == nil, "disable deletes disk snapshot")
            return
        }
        await store.restoreCachedEvents()
        try require(store.lastChecked == nil, "\(phase): restore does not claim a successful refresh")
        if phase == "corrupt" {
            try require(store.events.count == 1 && store.events.first?.uid == "b" && store.cacheIssues[a.id] != nil, "corrupt source is isolated; other source restores")
            store.refresh()
            try await wait("corrupt cache recovery refresh") { !store.isRefreshing }
            await cache.flush()
            try await wait("corrupt cache warning clears") { store.cacheIssues.isEmpty }
            try require(store.events.count == 2, "corrupt cache refilled from network")
            return
        }
        if phase.hasPrefix("offline") {
            let expected = phase == "offline" ? 2 : 1
            try require(store.events.count == expected, "\(phase): correct events restored in a new process")
            try require(store.events.allSatisfy { $0.calendarName.hasPrefix("Live") }, "restore uses current subscription names")
            var deliveries: [String] = []
            store.onAlert = { deliveries += $0.map(\.uid) }
            store.pauseIndefinitely(); store.tick()
            try require(deliveries.isEmpty, "pause suppresses restored offline reminders")
            store.resume()
            store.tick(); store.tick()
            try require(deliveries == (phase == "offline" ? ["a"] : []), "offline reminder delivered once; successful empty snapshot remains empty")
            store.refresh()
            try await wait("offline transport failure completes") { !store.isRefreshing }
            try require(store.offlineCalendarIDs.count == 2 && store.events.count == expected, "offline failure retains restored agenda")
            let menu = NSMenu()
            let alerts = AlertController()
            let updates = UpdateController(store: store)
            defer { withExtendedLifetime((alerts, updates)) {} }
            let controller = MenuBarController(store: store, alerts: alerts, updates: updates, openSettings: {}, quit: {})
            controller.menuNeedsUpdate(menu)
            let item = menu.items.first { $0.title.hasPrefix("Offline · Using saved calendars") }
            try require(item?.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.systemRed,
                        "offline status occupies existing red menu error row")
            try require(store.calendarCacheStatus(a.id)?.contains("Last successful sync:") == true, "cache age available in Settings")
            if phase == "offline" {
                OfflineProtocol.setOffline(false)
                store.refresh()
                try await wait("same-process connectivity recovery") { !store.isRefreshing }
                try require(store.offlineCalendarIDs.isEmpty && store.errors.isEmpty && store.calendarSyncProblemTitle == nil,
                            "connectivity recovery clears the red Offline row without restarting")
                try require(store.cacheInfo.values.allSatisfy { !$0.usingSavedData }, "recovery removes saved-data state")
                store.tick()
                try require(deliveries == ["a"], "network recovery does not repeat the offline reminder")
                await cache.flush()
            }
            return
        }
        store.refresh()
        try await wait("\(phase): refresh completes") { !store.isRefreshing }
        await cache.flush()
        let loaded = await cache.load(subscriptions: [a, b])
        if phase == "mixed" {
            try require(store.errors.count == 1 && store.offlineCalendarIDs.isEmpty && store.events.count == 2, "HTTP failure keeps saved source while healthy peer refreshes; no false offline claim")
        } else if phase == "empty" {
            try require(store.events.count == 1 && loaded.snapshots[a.id]?.meetings.isEmpty == true, "successful empty calendar replaces populated disk snapshot")
        } else {
            try require(store.events.count == 2 && loaded.snapshots.count == 2, "\(phase): both successful sources saved")
            try require(store.errors.isEmpty && store.offlineCalendarIDs.isEmpty, "\(phase): successful refresh clears errors")
            try require(store.cacheInfo.values.allSatisfy { !$0.usingSavedData }, "fresh results replace restored-data status")
            if phase == "recovery" { try require(store.events.allSatisfy { $0.title.hasPrefix("Recovered") }, "recovery replaces saved event content") }
        }
        // Feed an old request after a newer accepted request. Disk must follow the same gate.
        let old = FetchResult(subscription: a, events: [], error: nil, requestID: -1)
        store.merge(results: [old]); await cache.flush()
        let afterOld = await cache.load(subscriptions: [a])
        try require(afterOld.snapshots[a.id]?.meetings.count == loaded.snapshots[a.id]?.meetings.count, "stale fetch cannot overwrite newer disk snapshot")
    }

    @MainActor static func gui(a: CalendarSubscription, b: CalendarSubscription, domain: String) throws {
        var settings = AppSettings()
        settings.automaticUpdateChecks = false
        let state = Persisted(subscriptions: [a, b], settings: settings, pausedUntil: .distantFuture)
        UserDefaults.standard.setVolatileDomain([AppStore.storageKey: try JSONEncoder().encode(state)], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated {
                guard delegate.store.events.count == 2, delegate.store.lastChecked != nil,
                      let event = delegate.store.events.first(where: { $0.uid == "a" }) else {
                    print("FAIL: real AppDelegate startup did not load calendars"); exit(1)
                }
                print("PASS: real AppDelegate startup and run loop alive after four seconds")
                let updated = MeetingEvent(uid: event.uid, title: "Quit snapshot", start: event.start,
                    end: event.end, location: event.location, notes: event.notes, link: event.link,
                    calendarID: a.id, calendarName: a.name, colorIndex: a.colorIndex)
                delegate.store.merge(results: [FetchResult(subscription: a, events: [updated], error: nil,
                    requestID: delegate.store.fetchTracker.latestPerSubscription[a.id] ?? 0, fetchedAt: Date())])
                UserDefaults.standard.removePersistentDomain(forName: domain)
                // Actual AppKit terminateLater/reply path must drain the queued write.
                app.terminate(nil)
            }
        }
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor static func storage(cache: CalendarEventCache, a: CalendarSubscription, b: CalendarSubscription) async throws {
        let date = Date()
        let empty = CalendarCacheSnapshot(subscription: a, events: [], fetchedAt: date, warning: nil)
        try require(await save(empty, to: cache) == nil, "valid empty snapshot saves")
        let path = cache.directory.appendingPathComponent(a.id.uuidString + ".json")
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        try require(mode == 0o600, "cache files are readable only by their owner")
        let oversized = CalendarCacheSnapshot(subscription: a, events: [], fetchedAt: date, warning: String(repeating: "x", count: 3_000_000))
        try require(await save(oversized, to: cache) != nil, "oversized snapshot fails visibly")
        try require((await cache.load(subscriptions: [a])).snapshots[a.id] == nil, "failed replacement cannot resurrect older snapshot")
        // Aggregate limit: exact fit succeeds, one extra byte fails only this source.
        let aggregate = CalendarEventCache(directory: cache.directory.appendingPathComponent("aggregate"))
        try FileManager.default.createDirectory(at: aggregate.directory, withIntermediateDirectories: true)
        let encodedSize = try JSONEncoder().encode(empty).count
        let filler = aggregate.directory.appendingPathComponent(b.id.uuidString + ".json")
        FileManager.default.createFile(atPath: filler.path, contents: nil)
        let handle = try FileHandle(forWritingTo: filler)
        try handle.truncate(atOffset: UInt64(CalendarEventCache.maxTotalBytes - encodedSize))
        try require(await save(empty, to: aggregate) == nil, "aggregate cache accepts exact 64 MB boundary")
        try handle.truncate(atOffset: UInt64(CalendarEventCache.maxTotalBytes - encodedSize + 1))
        try handle.close()
        try require(await save(empty, to: aggregate) != nil, "aggregate cache rejects one byte over budget")
        try require(!FileManager.default.fileExists(atPath: aggregate.directory.appendingPathComponent(a.id.uuidString + ".json").path)
                    && FileManager.default.fileExists(atPath: filler.path), "budget failure removes own stale snapshot, not another source")
        let expired = CalendarCacheSnapshot(subscription: a, events: [], fetchedAt: date.addingTimeInterval(-15 * 86400), warning: nil)
        try require(await save(expired, to: cache) == nil, "expired snapshot remains readable metadata")
        let store = AppStore(eventCache: cache, initialState: Persisted(subscriptions: [a, b]))
        await store.restoreCachedEvents()
        try require(store.calendarSyncProblemTitle?.contains("coverage expired") == true && store.calendarCacheStatus(a.id)?.contains("refresh needed") == true,
                    "exhausted coverage explains refresh requirement instead of empty agenda")
        // Queue a write followed immediately by source retirement.
        cache.save(empty) { _ in }
        cache.remove([a.id]); await cache.flush()
        try require((await cache.load(subscriptions: [a])).snapshots[a.id] == nil, "queued source removal wins over earlier write")
        let blocked = CalendarEventCache(directory: cache.directory.appendingPathComponent("not-a-directory"))
        try Data("file".utf8).write(to: blocked.directory)
        try require(await save(empty, to: blocked) != nil, "disk failure is reported without losing the live agenda")
    }

    static func main() {
        setbuf(stdout, nil)
        if CommandLine.arguments[1] == "gui" {
            MainActor.assumeIsolated {
                do {
                    let base = CommandLine.arguments[2]
                    var a = CalendarSubscription(name: "Live A", url: base + "/a", colorIndex: 0)
                    a.id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
                    var b = CalendarSubscription(name: "Live B", url: base + "/b", colorIndex: 1)
                    b.id = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
                    try gui(a: a, b: b, domain: Bundle.main.bundleIdentifier!)
                } catch { print("FAIL: \(error)"); exit(1) }
            }
        } else {
            Task {
                do { try await run(); exit(0) }
                catch { print("FAIL: \(error)"); exit(1) }
            }
            RunLoop.main.run()
        }
    }
}
