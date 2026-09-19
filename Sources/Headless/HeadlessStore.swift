import Foundation
import NowCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// A six-color presentation palette for the headless port; decoder-local, like
/// the macOS shell's Palette, never a core policy.
enum HeadlessPalette {
    static let hexes = ["#1f6feb", "#8250df", "#2da44e", "#bf3989", "#953800", "#0969da"]

    static func hex(for index: Int) -> String { hexes[max(0, min(hexes.count - 1, index))] }
}

/// Atomic file writes mirroring the core POSIX adapter: 0700 directories,
/// 0600 files, temporary write then rename.
enum HeadlessFile {
    static func write(_ data: Data, to url: URL) {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let temporary = directory.appendingPathComponent(".write-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard rename(temporary.path, url.path) == 0 else { return }
        } catch {
            // Probe keeps running; startup logs surface the failure to the caller.
        }
    }

    static func permissions(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }
}

/// A manual clock for deterministic loop scenarios; safe to share across
/// concurrency domains while single test code advances it.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) { self.instant = instant }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return instant
    }

    func date() -> Date { now }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); instant = instant.addingTimeInterval(seconds); lock.unlock()
    }
}

/// The headless Linux shell probe: file preferences, ICS-only feeds, the shared
/// POSIX cache adapter with injected directories, and the reminder loop. It
/// mirrors AppStore's fetch → merge → commit → tick ordering through NowCore
/// policy owners; delivery is a logged line, not a native notification
/// transport (the transport gap stays open per the port roadmap).
actor HeadlessStore {
    struct LoadReport: Sendable {
        var preferencesRecovered = false
        var ledgerRecovered = false
        var restoredEvents = 0
    }

    static let maxFeedBytes = 5_000_000

    let root: URL
    let clock: @Sendable () -> Date
    private let logging: @Sendable (String) -> Void

    private(set) var prefs = Persisted()
    private(set) var ledger = ReminderLedger()
    private let cache: CalendarEventCache
    private var fetchTracker = FetchTracker()
    private var reminderSnapshots = ReminderSnapshotTracker()
    private var catchUpRefresh = CatchUpRefreshTracker()
    private var catchUpBoundary: [UUID: Date] = [:]
    private var catchUpIDs: Set<String> = []
    private var mutedByID: [String: Bool] = [:]
    private var isRefreshing = false
    private(set) var events: [MeetingEvent] = []
    private(set) var errors: [UUID: String] = [:]
    private(set) var warnings: [UUID: String] = [:]
    private var lastDue: [MeetingEvent] = []
    private(set) var deliveries: [String] = []

    init(root: URL, clock: @escaping @Sendable () -> Date = { Date() },
         logging: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.root = root
        self.clock = clock
        self.logging = logging
        cache = CalendarEventCache(directory: root.appendingPathComponent("cache"))
    }

    private func log(_ line: String) { logging(line) }

    // MARK: State load/persist

    func loadState() async -> LoadReport {
        var report = LoadReport()
        let audit = PreferenceDecoding()
        if let data = try? Data(contentsOf: root.appendingPathComponent("preferences.json")) {
            let decoder = ModelDecoding.decoder(calendarColor: { HeadlessPalette.hex(for: $0) })
            decoder.userInfo[PreferenceDecoding.key] = audit
            if let loaded = try? decoder.decode(Persisted.self, from: data) { prefs = loaded }
            else { report.preferencesRecovered = true }
            report.preferencesRecovered = report.preferencesRecovered || audit.recovered
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("ledger.json")), data.count <= 8_000_000 {
            if let loaded = try? JSONDecoder().decode(ReminderLedger.self, from: data) { ledger = loaded }
            else { report.ledgerRecovered = true }
        }
        let loadedCache = await cache.load(subscriptions: prefs.subscriptions)
        var restored: [MeetingEvent] = []
        let now = clock()
        for subscription in prefs.subscriptions where subscription.isEnabled {
            if let snapshot = loadedCache.snapshots[subscription.id], snapshot.matches(subscription) {
                restored += snapshot.events(subscription: subscription, now: now)
                warnings[subscription.id] = snapshot.warning
            }
        }
        // Disk restore is not a source observation; mirror restoreCachedEvents.
        commitEvents(restored, observedCalendarIDs: [])
        report.restoredEvents = restored.count
        log("LOADED prefs_recovered=\(report.preferencesRecovered) ledger_recovered=\(report.ledgerRecovered) restored=\(report.restoredEvents)")
        return report
    }

    func savePreferences() {
        if let data = try? JSONEncoder().encode(prefs) {
            HeadlessFile.write(data, to: root.appendingPathComponent("preferences.json"))
        }
    }

    func setPreferences(_ value: Persisted) {
        prefs = value
        savePreferences()
    }

    private func persistLedger() {
        if let data = try? JSONEncoder().encode(ledger) {
            HeadlessFile.write(data, to: root.appendingPathComponent("ledger.json"))
        }
    }

    // MARK: Refresh (fetch → merge → commit), mirroring AppStore.refresh/merge

    func startup() async -> LoadReport {
        let report = await loadState()
        beginCatchUp()
        await refresh()
        return report
    }

    func refresh() async {
        isRefreshing = true
        let enabled = prefs.subscriptions.filter(\.isEnabled)
        let requestID = fetchTracker.beginFull(subscriptionIDs: enabled.map(\.id))
        catchUpRefresh.started(requestID)
        var results: [FetchResult] = []
        for subscription in enabled {
            results.append(await Self.fetch(NowCore.FetchRequest(subscription: subscription, requestID: requestID), now: clock()))
        }
        await apply(results)
        isRefreshing = false
        if catchUpRefresh.finish(requestID) { catchUpBoundary = [:] }
        log("REFRESHED ok=\(results.filter { $0.error == nil }.count) failed=\(results.filter { $0.error != nil }.count) events=\(events.count) errors=\(errors.count)")
        tick()
    }

    /// One bounded transport read; http(s) mirrors the shell transport, file://
    /// is the probe's offline feed source.
    private static func readFeed(_ urlString: String) async -> (Data?, String?) {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else { return (nil, "Invalid URL") }
        if scheme == "http" || scheme == "https" {
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { return (nil, "Request failed") }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return (nil, "Bad response") }
            guard data.count <= maxFeedBytes else { return (nil, "Feed larger than \(maxFeedBytes / 1_000_000) MB") }
            return (data, nil)
        }
        guard scheme == "file" else { return (nil, "Invalid URL") }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, "Feed unavailable") }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFeedBytes + 1) else { return (nil, "Feed unavailable") }
        guard data.count <= maxFeedBytes else { return (nil, "Feed larger than \(maxFeedBytes / 1_000_000) MB") }
        return (data, nil)
    }

    /// Shared by feeds and tests; mirrors AppStore.decodeFeed with the portable
    /// link adapter instead of NSDataDetector.
    static func decodeFeed(_ data: Data, request: NowCore.FetchRequest, now: Date) -> FetchResult {
        let subscription = request.subscription
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return FetchResult(subscription: subscription, events: [], error: "Empty response", requestID: request.requestID)
        }
        let built = ICSBuilder.meetings(fromICS: text, subscription: subscription, now: now,
                                        colorHex: subscription.colorHex.isEmpty ? HeadlessPalette.hex(for: subscription.colorIndex) : subscription.colorHex,
                                        detectLink: { LinkExtractor.link(from: $0, urlsInText: PortableLinkDetector.urls(inText:)) })
        let warning = built.warnings.isEmpty ? nil : built.warnings.prefix(5).joined(separator: " · ")
        return FetchResult(subscription: subscription, events: built.events, error: built.error,
                           warning: warning, requestID: request.requestID, fetchedAt: now)
    }

    private static func fetch(_ request: NowCore.FetchRequest, now: Date) async -> FetchResult {
        let (data, transportError) = await readFeed(request.subscription.url)
        if let transportError {
            return FetchResult(subscription: request.subscription, events: [], error: transportError,
                               requestID: request.requestID, isOffline: transportError == "Feed unavailable")
        }
        guard let data else {
            return FetchResult(subscription: request.subscription, events: [], error: "Empty response", requestID: request.requestID)
        }
        return decodeFeed(data, request: request, now: now)
    }

    private func apply(_ results: [FetchResult]) async {
        let merged = CalendarSnapshotMerge.merge(current: events, results: results, live: prefs.subscriptions,
                                                 previousErrors: errors, previousWarnings: warnings,
                                                 latestRequestIDs: fetchTracker.latestPerSubscription,
                                                 colorHex: { $0.colorHex.isEmpty ? HeadlessPalette.hex(for: $0.colorIndex) : $0.colorHex })
        errors = merged.errors
        warnings = merged.warnings
        for result in results where result.error == nil {
            let snapshot = CalendarCacheSnapshot(subscription: result.subscription, events: result.events,
                                                 fetchedAt: result.fetchedAt ?? clock(), warning: result.warning)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                cache.save(snapshot) { _ in continuation.resume() }
            }
        }
        commitEvents(merged.events, observedCalendarIDs: merged.observedCalendarIDs)
    }

    /// The single commit transaction, mirroring AppStore.commitEvents ordering.
    private func commitEvents(_ newEvents: [MeetingEvent], observedCalendarIDs: Set<UUID>) {
        let now = clock()
        let sorted = ReminderReconciliation.normalizedEvents(newEvents)
        let enabledIDs = Set(prefs.subscriptions.filter(\.isEnabled).map(\.id))
        let retainedIDs = reminderSnapshots.retainedIDs(current: sorted, observedCalendarIDs: observedCalendarIDs,
                                                        enabledCalendarIDs: enabledIDs)
        let rearmableKeys = prefs.settings.reminderDelivery == .fullscreen ? Set(sorted.map(ReminderIdentity.eventKey)) : []
        ledger.reconcile(events: sorted, enabled: enabledIDs, observed: observedCalendarIDs, now: now,
                         rearmOnReschedule: rearmableKeys, previousEvents: events,
                         leads: prefs.settings.reminderLeadSeconds, receiptLeads: [:])
        var previousMuted = mutedByID
        for event in events { previousMuted[event.id] = event.isMuted }
        ReminderReconciliation.ratchetSilence(previousMutedByID: previousMuted, current: sorted,
                                              ledger: &ledger, leads: prefs.settings.reminderLeadSeconds, now: now)
        for event in sorted {
            if let boundary = catchUpBoundary[event.calendarID], event.start <= boundary, event.end > now {
                catchUpIDs.insert(event.id)
            }
        }
        catchUpIDs.formIntersection(retainedIDs)
        persistLedger()
        mutedByID = ReminderReconciliation.retainedMutedStates(previous: mutedByID, current: sorted, retainedIDs: retainedIDs)
        events = sorted
    }

    // MARK: Reminder loop, mirroring AppStore.tick

    func tick() {
        let now = clock()
        if let until = prefs.pausedUntil, now >= until { prefs.pausedUntil = nil }
        if isPaused { return }
        let due = events.filter { !ledger.due($0, leads: prefs.settings.reminderLeadSeconds, now: now).isEmpty }
        lastDue = due
        for event in due {
            switch route(event, now: now) {
            case .handled: acknowledge([event])
            case .deferReminder: break
            case .fullscreen:
                acknowledge([event])
                deliver("REMINDER", event, route: "fullscreen")
            case .notification:
                deliver("REMINDER", event, route: "notification")
                acknowledge([event])
            case .catchUp:
                guard !isRefreshing, !catchUpRefresh.pending else { break }
                deliver("CATCHUP", event, route: "catchup")
                acknowledge([event])
            }
        }
    }

    private func route(_ event: MeetingEvent, now: Date) -> ReminderRoute {
        if ledger.suppressAfterJoin(event, detectionEnabled: prefs.settings.needsMeetingDetection, activity: .unknown) {
            return .handled
        }
        return NotificationLogic.route(event: event, settings: prefs.settings, activity: .unknown,
                                       catchUp: catchUpIDs.contains(event.id),
                                       snoozed: ledger.entries[ReminderIdentity.eventKey(event)]?.snooze != nil,
                                       now: now)
    }

    private func acknowledge(_ handled: [MeetingEvent]) {
        for event in handled {
            ledger.accept(ledger.due(event, leads: prefs.settings.reminderLeadSeconds, now: clock()), event: event)
        }
        persistLedger()
    }

    private func deliver(_ tag: String, _ event: MeetingEvent, route routeName: String) {
        let line = "\(tag) id=\(event.id) title=\(event.title) route=\(routeName) link=\(event.link?.absoluteString ?? "-")"
        deliveries.append(line)
        log(line)
    }

    // MARK: Agenda actions (Join/Snooze/Pause)

    var isPaused: Bool {
        if let until = prefs.pausedUntil { return clock() < until }
        return false
    }

    /// Snoozes the events the last tick surfaced, mirroring the alert's main
    /// button over its shown cards.
    func snoozeDelivered(seconds: Int) {
        let now = clock()
        let targets = lastDue.filter { !$0.isMuted && $0.end > now }
        guard !targets.isEmpty else { return }
        let options = SnoozePolicy.options(events: targets, now: now, customSeconds: seconds)
        guard let plan = SnoozePolicy.selection(current: nil, options: options, defaultSeconds: seconds),
              let schedule = SnoozePolicy.schedule(plan: plan, events: targets, now: now) else { return }
        for (id, fireAt) in schedule {
            guard let event = events.first(where: { $0.id == id }), !event.isMuted, fireAt < event.end else { continue }
            ledger.schedule(event, until: fireAt, leads: prefs.settings.reminderLeadSeconds)
            log("SNOOZED id=\(id) until=\(Int(fireAt.timeIntervalSince1970))")
        }
        persistLedger()
    }

    @discardableResult
    func join(eventID: String) -> Bool {
        guard let event = events.first(where: { $0.id == eventID }), event.end > clock() else { return false }
        ledger.join(event)
        persistLedger()
        log("JOINED id=\(event.id)")
        return true
    }

    func pause(seconds: TimeInterval) {
        prefs.pausedUntil = clock().addingTimeInterval(seconds)
        savePreferences()
        log("PAUSED until=\(Int(prefs.pausedUntil!.timeIntervalSince1970))")
    }

    func pauseIndefinitely() {
        prefs.pausedUntil = .distantFuture
        savePreferences()
        log("PAUSED indefinitely")
    }

    func resume() {
        prefs.pausedUntil = nil
        savePreferences()
        log("RESUMED")
    }

    func beginCatchUp() {
        catchUpRefresh.begin()
        let boundary = clock()
        catchUpBoundary = Dictionary(uniqueKeysWithValues: prefs.subscriptions.filter(\.isEnabled).map(\.id).map { ($0, boundary) })
        for event in events where event.start <= boundary && event.end > boundary { catchUpIDs.insert(event.id) }
    }

    // MARK: Run modes

    /// One bounded pass: startup, tick, optional wait for reminders, optional
    /// snooze of what was delivered — used by restart probes.
    func runOnce(waitForReminders: Int, snoozeAfter seconds: Int?) async {
        _ = await startup()
        let deadline = clock().addingTimeInterval(40)
        while clock() < deadline {
            tick()
            if deliveries.count >= waitForReminders || waitForReminders == 0 { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if let seconds { snoozeDelivered(seconds: seconds) }
        await cache.flush()
        savePreferences()
        log("AGENDA \(agenda().count)")
        log("DONE")
    }

    /// The live loop: one-second ticks and refresh at the configured interval.
    func run(duration: TimeInterval) async {
        _ = await startup()
        let start = clock()
        let refreshInterval = TimeInterval(prefs.settings.refreshMinutes * 60)
        var nextRefresh = start + refreshInterval
        while clock() < start.addingTimeInterval(duration) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            tick()
            if clock() >= nextRefresh {
                await refresh()
                nextRefresh = clock() + refreshInterval
            }
        }
        await cache.flush()
        savePreferences()
        log("AGENDA \(agenda().count)")
        log("DONE")
    }

    func agenda() -> [MeetingEvent] {
        let now = clock()
        return events.filter { $0.end > now }.sorted { $0.start < $1.start }.prefix(10).map { $0 }
    }
}
