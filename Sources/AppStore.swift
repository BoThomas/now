import SwiftUI
import AppKit
import EventKit
import ServiceManagement

final class AppStore: ObservableObject {
    static let storageKey = "local.tboch.now.state.v1"
    static let legacyDomain = "local.tboch.now"
    static let soundNames = ["Basso", "Blow", "Bottle", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    @Published var subscriptions: [CalendarSubscription] {
        didSet {
            persist()
            reconcileEvents()
            let enabledIDs = Set(subscriptions.filter(\.isEnabled).map(\.id))
            let newlyEnabled = enabledIDs.subtracting(previousEnabledIDs)
            previousEnabledIDs = enabledIDs
            newlyEnabled.forEach { resync(subscriptionID: $0) }
        }
    }
    private var previousEnabledIDs: Set<UUID> = []
    @Published var settings: AppSettings { didSet { settingsChanged() } }
    @Published var nativeCalendars: [NativeCalendar] {
        didSet {
            persist()
            reconcileNativeEvents()
            let enabledIDs = Set(nativeCalendars.filter(\.isEnabled).map(\.id))
            let newlyEnabled = enabledIDs.subtracting(previousEnabledNativeIDs)
            previousEnabledNativeIDs = enabledIDs
            if !newlyEnabled.isEmpty { fetchNativeEvents() }
        }
    }
    @Published private(set) var nativeAuthorization: EKAuthorizationStatus = .notDetermined
    @Published private(set) var nativeCalendarInfos: [NativeCalendarInfo] = []
    @Published private(set) var events: [MeetingEvent] = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var pausedUntil: Date?

    var onAlert: (([MeetingEvent]) -> Void)?
    weak var alertController: AlertController?

    /// Owns the single long-lived EKEventStore (see NativeCalendarSource docs).
    let nativeSource = NativeCalendarSource()
    private var nativeEvents: [MeetingEvent] = []
    /// Every calendar that ever fed us native events this session — used to tell native
    /// events apart from ICS ones by `calendarID` even after the calendar is removed.
    private var knownNativeCalendarIDs: Set<UUID> = []
    private var previousEnabledNativeIDs: Set<UUID> = []
    private var previousSkipDeclined = true
    private var nativeChangeDebounce: Timer?
    private var activeObserver: NSObjectProtocol?

    private var alerted: Set<String> = []
    private var snoozed: [String: Date] = [:]
    /// IDs present in the most recent `commitEvents` — lets the prune there require
    /// two consecutive misses before dropping alert/snooze bookkeeping.
    private var previousCommitIDs: Set<String> = []
    private var pendingRefresh = false
    private var tickTimer: Timer?
    private var refreshTimer: Timer?

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    init() {
        let state = Self.loadState()
        subscriptions = state.subscriptions
        settings = state.settings
        nativeCalendars = state.nativeCalendars
        previousEnabledIDs = Set(subscriptions.filter(\.isEnabled).map(\.id))
        knownNativeCalendarIDs = Set(nativeCalendars.map(\.id))
        previousEnabledNativeIDs = Set(nativeCalendars.filter(\.isEnabled).map(\.id))
        previousSkipDeclined = settings.skipDeclined
    }

    func start() {
        refreshNativeAuthorization()
        nativeSource.onStoreChange = { [weak self] in self?.scheduleNativeStoreRefresh() }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appBecameActive()
        }
        scheduleRefreshTimer()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        syncLoginItem(settings.launchAtLogin)
        refresh()
    }

    var isPaused: Bool {
        if let until = pausedUntil { return Date() < until }
        return false
    }

    func isVisible(_ event: MeetingEvent, at now: Date) -> Bool {
        if now < event.start { return true }
        if settings.lateMinutes < 0 { return false }
        if settings.lateMinutes == 0 { return now < event.end }
        return now < event.start.addingTimeInterval(TimeInterval(settings.lateMinutes) * 60)
    }

    var upcoming: [MeetingEvent] {
        let now = Date()
        return events.filter { isVisible($0, at: now) }
    }

    var nextEvent: MeetingEvent? {
        let now = Date()
        let visible = events.filter { isVisible($0, at: now) }
        return visible.first { $0.start <= now } ?? visible.first
    }

    func addSubscription(name: String, urlString: String) {
        let subscription = CalendarSubscription(name: name, url: urlString, colorIndex: subscriptions.count)
        subscriptions.append(subscription)
        refresh()
    }

    func removeSubscription(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        refresh()
    }

    // MARK: - Native calendars (EventKit)

    /// Toggling a calendar on in settings. First enable persists it with the calendar's
    /// own EventKit color as the default tint.
    func setNativeCalendarEnabled(_ info: NativeCalendarInfo, enabled: Bool) {
        if let index = nativeCalendars.firstIndex(where: { $0.ekIdentifier == info.ekIdentifier }) {
            nativeCalendars[index].isEnabled = enabled
            if enabled { nativeCalendars[index].name = info.title }
        } else if enabled {
            let hex = info.colorHex.isEmpty ? Palette.hex(for: nativeCalendars.count) : info.colorHex
            nativeCalendars.append(NativeCalendar(ekIdentifier: info.ekIdentifier, name: info.title, colorHex: hex, colorIndex: nativeCalendars.count))
        }
    }

    func setNativeCalendarColor(_ info: NativeCalendarInfo, hex: String) {
        guard let index = nativeCalendars.firstIndex(where: { $0.ekIdentifier == info.ekIdentifier }) else { return }
        nativeCalendars[index].colorHex = hex
    }

    func forgetNativeCalendar(_ id: UUID) {
        nativeCalendars.removeAll { $0.id == id }
    }

    /// Fires the TCC prompt. Only ever called from the settings UI — never at launch.
    func requestNativeAccess() {
        let source = nativeSource
        Task { [weak self] in
            let granted = await source.requestAccess()
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.refreshNativeAuthorization()
                if granted { self.fetchNativeEvents() }
            }
        }
    }

    func refreshNativeAuthorization() {
        nativeAuthorization = nativeSource.authorizationStatus()
    }

    /// EventKit is a fast local query — fetch synchronously on the main actor (same
    /// replace-on-apply semantics as the ICS refresh) and rebuild the merged event list.
    func fetchNativeEvents() {
        refreshNativeAuthorization()
        nativeCalendarInfos = nativeSource.availableCalendarInfos()
        let enabled = nativeCalendars.filter(\.isEnabled)
        guard nativeSource.isAuthorized, !enabled.isEmpty else {
            if !nativeEvents.isEmpty {
                nativeEvents = []
                rebuildEvents()
            }
            return
        }
        nativeEvents = nativeSource.fetchEvents(calendars: enabled, skipDeclined: settings.skipDeclined, now: Date())
        rebuildEvents()
    }

    private func scheduleNativeStoreRefresh() {
        guard nativeSource.isAuthorized, nativeCalendars.contains(where: \.isEnabled) else { return }
        nativeChangeDebounce?.invalidate()
        nativeChangeDebounce = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.fetchNativeEvents()
        }
    }

    /// Re-fetch on ANY authorization-status change, not just grants: revoking
    /// Calendar while the app runs must clear native events immediately instead of
    /// showing them until the next periodic refresh.
    private func appBecameActive() {
        let before = nativeAuthorization
        refreshNativeAuthorization()
        if nativeAuthorization != before {
            fetchNativeEvents()
        }
    }

    /// Native events for currently-enabled native calendars, tinted per current settings.
    private func coloredNativeSnapshot() -> [MeetingEvent] {
        let byID = Dictionary(uniqueKeysWithValues: nativeCalendars.map { ($0.id, $0.colorHex.isEmpty ? Palette.hex(for: $0.colorIndex) : $0.colorHex) })
        let enabled = Set(nativeCalendars.filter(\.isEnabled).map(\.id))
        return nativeEvents.filter { enabled.contains($0.calendarID) }.map { event in
            var copy = event
            if let hex = byID[event.calendarID] { copy.colorHex = hex }
            return copy
        }
    }

    /// Recombine the ICS half of `events` (untouched) with the current native snapshot.
    private func rebuildEvents() {
        let icsEvents = events.filter { !knownNativeCalendarIDs.contains($0.calendarID) }
        commitEvents(icsEvents + coloredNativeSnapshot())
    }

    private func reconcileNativeEvents() {
        let enabled = Set(nativeCalendars.filter(\.isEnabled).map(\.id))
        knownNativeCalendarIDs.formUnion(nativeCalendars.map(\.id))
        nativeEvents = nativeEvents.filter { enabled.contains($0.calendarID) }
        rebuildEvents()
    }

    func resync(subscriptionID: UUID) {
        guard let subscription = subscriptions.first(where: { $0.id == subscriptionID }) else { return }
        Task { [weak self] in
            let results = await Self.performFetch(subscriptions: [subscription])
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.merge(results: results)
            }
        }
    }

    private func merge(results: [FetchResult]) {
        var updated = events.filter { event in
            !results.contains { $0.subscription.id == event.calendarID }
        }
        let byID = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0.colorHex.isEmpty ? Palette.hex(for: $0.colorIndex) : $0.colorHex) })
        for result in results {
            if let error = result.error {
                errors[result.subscription.id] = error
                continue
            }
            errors.removeValue(forKey: result.subscription.id)
            updated.append(contentsOf: result.events.map { event in
                var copy = event
                if let hex = byID[event.calendarID] { copy.colorHex = hex }
                return copy
            })
        }
        commitEvents(updated)
    }

    func snooze(_ ids: [String]) {
        let fireAt = Date().addingTimeInterval(60)
        for id in ids { snoozed[id] = fireAt }
    }

    func pause(for seconds: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(seconds)
    }

    func pauseUntilMorning() {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 9
        components.minute = 0
        guard let target = calendar.date(from: components) else { return }
        pausedUntil = target > now ? target : target.addingTimeInterval(86400)
    }

    func pauseIndefinitely() {
        pausedUntil = .distantFuture
    }

    func resume() {
        pausedUntil = nil
    }

    func playSound() {
        guard settings.soundEnabled else { return }
        NSSound(named: NSSound.Name(settings.soundName))?.play()
    }

    func refresh() {
        fetchNativeEvents()
        let enabled = subscriptions.filter(\.isEnabled)
        guard !isRefreshing else {
            pendingRefresh = true
            return
        }
        isRefreshing = true
        Task { [weak self] in
            let results = await Self.performFetch(subscriptions: enabled)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.apply(results: results, fetched: enabled)
            }
        }
    }

    static func performFetch(subscriptions: [CalendarSubscription]) async -> [FetchResult] {
        await withTaskGroup(of: FetchResult.self) { group in
            for sub in subscriptions {
                group.addTask {
                    let (data, fetchError) = await fetchData(sub.url)
                    if let fetchError { return FetchResult(subscription: sub, events: [], error: fetchError) }
                    guard let data else { return FetchResult(subscription: sub, events: [], error: "Empty response") }
                    let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                    if !text.uppercased().contains("BEGIN:VCALENDAR") { return FetchResult(subscription: sub, events: [], error: "Not an iCal feed") }
                    let events = ICSBuilder.meetings(fromICS: text, subscription: sub, now: Date())
                    return FetchResult(subscription: sub, events: events, error: nil)
                }
            }
            var results: [FetchResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    struct FetchResult {
        let subscription: CalendarSubscription
        let events: [MeetingEvent]
        let error: String?
    }

    static func fetchData(_ urlString: String) async -> (Data?, String?) {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return (nil, "Invalid URL")
        }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return (nil, "Server returned \(http.statusCode)")
            }
            return (data, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func apply(results: [FetchResult], fetched: [CalendarSubscription]) {
        var allEvents: [MeetingEvent] = []
        var newErrors: [UUID: String] = [:]
        for result in results {
            allEvents.append(contentsOf: result.events)
            if let error = result.error { newErrors[result.subscription.id] = error }
        }
        let byID = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0.colorHex.isEmpty ? Palette.hex(for: $0.colorIndex) : $0.colorHex) })
        allEvents = allEvents.map { event in
            var copy = event
            if let hex = byID[event.calendarID] { copy.colorHex = hex }
            return copy
        }
        let nowEnabled = Set(subscriptions.filter(\.isEnabled).map(\.id))
        allEvents = allEvents.filter { nowEnabled.contains($0.calendarID) }
        commitEvents(allEvents + coloredNativeSnapshot())
        self.errors = newErrors
        self.lastRefresh = Date()
        self.isRefreshing = false
        if pendingRefresh || fetched.map(\.id) != subscriptions.filter(\.isEnabled).map(\.id) || fetched.map(\.url) != subscriptions.filter(\.isEnabled).map(\.url) {
            pendingRefresh = false
            refresh()
        }
    }

    /// Single funnel for publishing the merged (ICS + native) event list: sorts, and
    /// prunes alert/snooze bookkeeping for events that disappeared. An id is only
    /// pruned once it's missing from **two consecutive commits**: a single miss is
    /// treated as transient (a fetch racing a CalDAV sync, one bad/empty ICS
    /// response) so a reappearing event neither re-alerts nor loses its snooze.
    /// Bookkeeping for ids absent from `events` is inert — `tick()` only looks at
    /// `events` — so the extra commit of lag is harmless.
    private func commitEvents(_ newEvents: [MeetingEvent]) {
        let sorted = newEvents.sorted { $0.start < $1.start }
        let active = Set(sorted.map(\.id))
        if active != previousCommitIDs {
            let prunable = alerted.union(snoozed.keys).filter { !active.contains($0) && !previousCommitIDs.contains($0) }
            alerted.subtract(prunable)
            snoozed = snoozed.filter { !prunable.contains($0.key) }
            previousCommitIDs = active
        }
        events = sorted
    }

    private func reconcileEvents() {
        let byID = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0.colorHex.isEmpty ? Palette.hex(for: $0.colorIndex) : $0.colorHex) })
        let enabled = Set(subscriptions.filter(\.isEnabled).map(\.id))
        let next = events.compactMap { event -> MeetingEvent? in
            if knownNativeCalendarIDs.contains(event.calendarID) { return event }
            guard enabled.contains(event.calendarID) else { return nil }
            var copy = event
            if let hex = byID[event.calendarID] { copy.colorHex = hex }
            return copy
        }
        commitEvents(next)
    }

    private func tick() {
        let now = Date()
        if let until = pausedUntil, now >= until { pausedUntil = nil }
        if let alerts = alertController, alerts.isOpen {
            if alerts.shownEvents.allSatisfy({ now.timeIntervalSince($0.end) > 120 }) {
                alerts.close()
            }
        }
        if isPaused { return }
        let lead = TimeInterval(settings.leadSeconds)
        var due: [MeetingEvent] = []
        for event in events {
            if alerted.contains(event.id) {
                if let fireAt = snoozed[event.id], now >= fireAt, now <= event.end {
                    due.append(event)
                }
            } else if now >= event.start.addingTimeInterval(-lead), now <= event.start.addingTimeInterval(45) {
                due.append(event)
            }
        }
        guard !due.isEmpty else { return }
        due.forEach {
            alerted.insert($0.id)
            snoozed.removeValue(forKey: $0.id)
        }
        onAlert?(due)
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(5, settings.refreshMinutes)) * 60
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func settingsChanged() {
        persist()
        scheduleRefreshTimer()
        syncLoginItem(settings.launchAtLogin)
        if settings.skipDeclined != previousSkipDeclined {
            previousSkipDeclined = settings.skipDeclined
            fetchNativeEvents()
        }
    }

    private func syncLoginItem(_ desired: Bool) {
        let service = SMAppService.mainApp
        let registered = service.status == .enabled
        guard desired != registered else { return }
        do {
            if desired {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            settings.launchAtLogin = registered
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Persisted(subscriptions: subscriptions, settings: settings, nativeCalendars: nativeCalendars)) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    static func loadState() -> Persisted {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let state = try? JSONDecoder().decode(Persisted.self, from: data) {
            return state
        }
        if let legacy = UserDefaults(suiteName: legacyDomain),
           let data = legacy.data(forKey: storageKey),
           let state = try? JSONDecoder().decode(Persisted.self, from: data) {
            UserDefaults.standard.set(data, forKey: storageKey)
            return state
        }
        return Persisted(subscriptions: [], settings: AppSettings())
    }
}
