import Foundation
import NowCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Linux v1 shell store: file preferences, ICS-only feeds, the shared
/// POSIX cache adapter with injected directories, and the reminder loop —
/// mirroring HeadlessStore's fetch → merge → commit → tick ordering through
/// NowCore policy owners. Delivery is a freedesktop toast (default-action
/// only, per the recorded probe decision); Join/Pause live in the tray menu.
actor LinuxStore {
    static let maxFeedBytes = 5_000_000
    /// Toast timeout: the probe showed non-critical toasts die within ~30 s
    /// regardless; -1 lets the daemon choose.
    static let toastTimeoutMs: Int32 = -1

    let root: URL
    let clock: @Sendable () -> Date
    private let logging: @Sendable (String) -> Void
    private let openJoin: @Sendable (URL) -> Void

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
    /// True while a delivered reminder is already snoozed; cleared when new
    /// reminders arrive so the snooze offer reappears.
    private var snoozePending = false

    // Tray surfaces (nonisolated D-Bus objects; calls hop out of the actor).
    private let connection: DBusConnection
    private let registrar: StatusNotifier.Registrar
    private let menu: DBusMenu.Publisher
    private var publishedTitle = ""
    /// XDG autostart directory; injected so tests never touch a real home.
    private let autostartDirectory: URL

    init(root: URL, connection: DBusConnection, clock: @escaping @Sendable () -> Date = { Date() },
         logging: @escaping @Sendable (String) -> Void = { _ in },
         openJoin: @escaping @Sendable (URL) -> Void = { _ in },
         autostartDirectory: URL? = nil) {
        self.root = root
        self.clock = clock
        self.logging = logging
        self.openJoin = openJoin
        self.cache = CalendarEventCache(directory: root.appendingPathComponent("cache"))
        self.connection = connection
        var trayConfiguration = StatusNotifier.ItemConfiguration()
        trayConfiguration.iconThemePath = root.appendingPathComponent("icons").path
        self.registrar = StatusNotifier.Registrar(connection: connection, configuration: trayConfiguration, logging: logging)
        self.menu = DBusMenu.Publisher(connection: connection, path: StatusNotifier.ItemConfiguration().menuPath)
        self.autostartDirectory = autostartDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/autostart")
        menu.onAction { [weak self] action in
            guard let self else { return }
            Task { await self.handle(action: action) }
        }
    }

    /// The tray item's bus name, for clients and diagnostics.
    var trayServiceName: String { registrar.serviceName }

    /// Syncs the XDG autostart entry with the launch-at-login preference.
    /// Per the Omarchy probe, entries apply at next login; the toggle's copy
    /// must keep saying so.
    private func syncAutostart() {
        let entry = autostartDirectory.appendingPathComponent("now-linux.desktop")
        if prefs.settings.launchAtLogin {
            let text = """
            [Desktop Entry]
            Type=Application
            Name=now
            Exec=now-linux run --root \(root.path)
            X-GNOME-Autostart-enabled=true

            """
            LinuxFile.write(Data(text.utf8), to: entry)
        } else {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func log(_ line: String) { logging(line) }

    // MARK: Startup

    func startup() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let icons = root.appendingPathComponent("icons")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        LinuxFile.write(LinuxIcon.pngData(size: LinuxIcon.iconSize), to: icons.appendingPathComponent("now.png"))
        try registrar.registerObject()
        await loadState()
        syncAutostart()
        beginCatchUp()
        await refresh()
        try await registrar.connect(initialTimeout: 5)
        publishAgenda()
    }

    func run(refreshSeconds: TimeInterval, tickSeconds: TimeInterval, duration: TimeInterval) async throws {
        let start = clock()
        while true {
            try await Task.sleep(nanoseconds: UInt64(tickSeconds * 1_000_000_000))
            tick()
            publishAgenda()
            if refreshSeconds > 0, Int(clock().timeIntervalSince(start)) % Int(refreshSeconds) < Int(tickSeconds) {
                await refresh()
            }
            if duration > 0, clock().timeIntervalSince(start) >= duration { break }
        }
    }

    // MARK: State load/persist (mirrors HeadlessStore recovery rules)

    private func loadState() async {
        let audit = PreferenceDecoding()
        if let data = try? Data(contentsOf: root.appendingPathComponent("preferences.json")) {
            let decoder = ModelDecoding.decoder(calendarColor: { LinuxPalette.hex(for: $0) })
            decoder.userInfo[PreferenceDecoding.key] = audit
            if let loaded = try? decoder.decode(Persisted.self, from: data) { prefs = loaded }
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("ledger.json")), data.count <= 8_000_000 {
            if let loaded = try? JSONDecoder().decode(ReminderLedger.self, from: data) { ledger = loaded }
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
        commitEvents(restored, observedCalendarIDs: [])
        log("LOADED restored=\(restored.count)")
    }

    private func savePreferences() {
        if let data = try? JSONEncoder().encode(prefs) {
            LinuxFile.write(data, to: root.appendingPathComponent("preferences.json"))
        }
    }

    private func persistLedger() {
        if let data = try? JSONEncoder().encode(ledger) {
            LinuxFile.write(data, to: root.appendingPathComponent("ledger.json"))
        }
    }

    // MARK: Refresh (mirrors HeadlessStore.refresh/apply)

    func refresh() async {
        isRefreshing = true
        let enabled = prefs.subscriptions.filter(\.isEnabled)
        let requestID = fetchTracker.beginFull(subscriptionIDs: enabled.map(\.id))
        catchUpRefresh.started(requestID)
        var results: [FetchResult] = []
        for subscription in enabled {
            results.append(await Self.fetch(NowCore.FetchRequest(subscription: subscription, requestID: requestID), now: clock()))
        }
        let merged = CalendarSnapshotMerge.merge(current: events, results: results, live: prefs.subscriptions,
                                                 previousErrors: errors, previousWarnings: warnings,
                                                 latestRequestIDs: fetchTracker.latestPerSubscription,
                                                 colorHex: { $0.colorHex.isEmpty ? LinuxPalette.hex(for: $0.colorIndex) : $0.colorHex })
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
        isRefreshing = false
        if catchUpRefresh.finish(requestID) { catchUpBoundary = [:] }
        log("REFRESHED ok=\(results.filter { $0.error == nil }.count) failed=\(results.filter { $0.error != nil }.count) events=\(events.count)")
    }

    private static func fetch(_ request: NowCore.FetchRequest, now: Date) async -> FetchResult {
        guard let url = URL(string: request.subscription.url), let scheme = url.scheme?.lowercased() else {
            return FetchResult(subscription: request.subscription, events: [], error: "Invalid URL",
                               requestID: request.requestID)
        }
        var data: Data?
        if scheme == "file" {
            data = try? FileHandle(forReadingFrom: url).read(upToCount: maxFeedBytes)
        } else if scheme == "http" || scheme == "https" {
            if let (body, response) = try? await URLSession.shared.data(from: url),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                data = body.count <= maxFeedBytes ? body : nil
            }
        }
        guard let data, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return FetchResult(subscription: request.subscription, events: [], error: "Feed unavailable",
                               requestID: request.requestID)
        }
        let built = ICSBuilder.meetings(fromICS: text, subscription: request.subscription, now: now,
                                        colorHex: request.subscription.colorHex.isEmpty
                                            ? LinuxPalette.hex(for: request.subscription.colorIndex)
                                            : request.subscription.colorHex,
                                        detectLink: { LinkExtractor.link(from: $0, urlsInText: LinuxLinkDetector.urls(inText:)) })
        let warning = built.warnings.isEmpty ? nil : built.warnings.prefix(5).joined(separator: " · ")
        return FetchResult(subscription: request.subscription, events: built.events, error: built.error,
                           warning: warning, requestID: request.requestID, fetchedAt: now)
    }

    private func beginCatchUp() {
        let now = clock()
        for subscription in prefs.subscriptions where subscription.isEnabled {
            catchUpBoundary[subscription.id] = now
        }
    }

    // MARK: Commit and tick (mirrors HeadlessStore ordering)

    private func commitEvents(_ newEvents: [MeetingEvent], observedCalendarIDs: Set<UUID>) {
        let now = clock()
        let sorted = ReminderReconciliation.normalizedEvents(newEvents)
        let enabledIDs = Set(prefs.subscriptions.filter(\.isEnabled).map(\.id))
        let retainedIDs = reminderSnapshots.retainedIDs(current: sorted, observedCalendarIDs: observedCalendarIDs,
                                                        enabledCalendarIDs: enabledIDs)
        ledger.reconcile(events: sorted, enabled: enabledIDs, observed: observedCalendarIDs, now: now,
                         rearmOnReschedule: [], previousEvents: events,
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

    func tick() {
        let now = clock()
        if let until = prefs.pausedUntil, now >= until { prefs.pausedUntil = nil }
        if prefs.pausedUntil != nil { return }
        let due = events.filter { !ledger.due($0, leads: prefs.settings.reminderLeadSeconds, now: now).isEmpty }
        lastDue = due
        if !due.isEmpty { snoozePending = false }
        for event in due {
            deliver(event, now: now)
            acknowledge(event, now: now)
        }
        publishAgenda()
    }

    /// Snoozes the delivered reminders; mirrors HeadlessStore.snoozeDelivered
    /// through SnoozePolicy and the ledger schedule.
    func snooze(seconds: Int) {
        let now = clock()
        let targets = lastDue.filter { !$0.isMuted && $0.end > now }
        guard !targets.isEmpty else { return }
        let options = SnoozePolicy.options(events: targets, now: now, customSeconds: seconds)
        guard let plan = SnoozePolicy.selection(current: nil, options: options, defaultSeconds: seconds),
              let schedule = SnoozePolicy.schedule(plan: plan, events: targets, now: now) else { return }
        for (id, fireAt) in schedule {
            guard let event = events.first(where: { $0.id == id }), !event.isMuted, fireAt < event.end else { continue }
            ledger.schedule(event, until: fireAt, leads: prefs.settings.reminderLeadSeconds)
        }
        persistLedger()
        snoozePending = true
        publishAgenda()
    }

    private func deliver(_ event: MeetingEvent, now: Date) {
        let summary = event.title
        let body = event.start <= now
            ? "started · ends \(AgendaMenu.countdown(to: event.end, now: now))"
            : "starts in \(AgendaMenu.countdown(to: event.start, now: now))"
        _ = try? connection.call(
            destination: StatusNotifier.notificationsService, path: StatusNotifier.notificationsPath,
            interface: StatusNotifier.notificationsInterface, member: "Notify",
            arguments: [
                .string("now"),
                .uint32(0),
                .string("appointment-soon-symbolic"),
                .string(summary),
                .string(body),
                .stringArray([]),
                .dictEntries([]),
                .int32(Int32(Self.toastTimeoutMs)),
            ],
            timeoutMs: 2_000
        )
        log("REMINDER \(event.title)")
    }

    private func acknowledge(_ event: MeetingEvent, now: Date) {
        ledger.accept(ledger.due(event, leads: prefs.settings.reminderLeadSeconds, now: now), event: event)
        persistLedger()
    }

    // MARK: Tray actions and agenda publish

    private func handle(action: String) {
        if action == "pause:3600" {
            prefs.pausedUntil = clock().addingTimeInterval(3_600)
            savePreferences()
            publishAgenda()
            return
        }
        if action == "resume" {
            prefs.pausedUntil = nil
            savePreferences()
            publishAgenda()
            return
        }
        if action.hasPrefix("snooze:"), let seconds = Int(action.dropFirst("snooze:".count)) {
            snooze(seconds: seconds)
            return
        }
        if action.hasPrefix("join:"), let url = URL(string: String(action.dropFirst("join:".count))) {
            openJoin(url)
        }
    }

    /// Publishes the bar title and the agenda menu tree from the snapshot.
    func publishAgenda() {
        let now = clock()
        let title = AgendaMenu.barTitle(events: events, now: now)
        if title != publishedTitle {
            publishedTitle = title
            registrar.updateTitle(title)
        }
        var sections = AgendaMenu.sections(events: events, now: now)
        sections.append(pausedSection(now: now))
        menu.update(AgendaMenu.nodes(sections: sections))
    }

    private func pausedSection(now: Date) -> AgendaMenu.Section {
        if let until = prefs.pausedUntil, until > now {
            let row = AgendaMenu.Row(label: "Resume reminders", action: "resume")
            return AgendaMenu.Section(header: "PAUSED · \(AgendaMenu.countdown(to: until, now: now))", rows: [row])
        }
        var rows: [AgendaMenu.Row] = []
        if !snoozePending, lastDue.contains(where: { !$0.isMuted && $0.end > now }) {
            rows.append(AgendaMenu.Row(label: "Snooze 10 min", action: "snooze:600"))
            rows.append(AgendaMenu.Row(label: "Snooze 1 hour", action: "snooze:3600"))
        }
        rows.append(AgendaMenu.Row(label: "Pause for 1 hour", action: "pause:3600"))
        return AgendaMenu.Section(header: "REMINDERS", rows: rows)
    }
}

/// A six-color presentation palette for the Linux shell; decoder-local, like
/// the macOS shell's Palette and the headless probe's, never core policy.
enum LinuxPalette {
    static let hexes = ["#1f6feb", "#8250df", "#2da44e", "#bf3989", "#953800", "#0969da"]

    static func hex(for index: Int) -> String { hexes[max(0, min(hexes.count - 1, index))] }
}

/// Atomic file writes mirroring the core POSIX adapter: 0700 directories,
/// 0600 files, temporary write then rename.
enum LinuxFile {
    static func write(_ data: Data, to url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".write-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = rename(temporary.path, url.path)
        } catch {
            // Startup logs surface the failure; the store keeps running.
        }
    }
}

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
