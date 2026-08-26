import SwiftUI
import AppKit
import ServiceManagement

final class AppStore: ObservableObject {
    static let storageKey = "local.tboch.now.state.v1"
    static let legacyDomain = "local.tboch.now"
    static let soundNames = ["Basso", "Blow", "Bottle", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    @Published var subscriptions: [CalendarSubscription] { didSet { persist(); reconcileEvents() } }
    @Published var settings: AppSettings { didSet { settingsChanged() } }
    @Published private(set) var events: [MeetingEvent] = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var pausedUntil: Date?

    var onAlert: (([MeetingEvent]) -> Void)?
    weak var alertController: AlertController?

    private var alerted: Set<String> = []
    private var snoozed: [String: Date] = [:]
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
    }

    func start() {
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
        let active = Set(updated.map(\.id))
        alerted.subtract(Set(alerted).subtracting(active))
        snoozed = snoozed.filter { active.contains($0.key) }
        events = updated.sorted { $0.start < $1.start }
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
        if allEvents.map(\.id).sorted() != events.map(\.id).sorted() {
            let active = Set(allEvents.map(\.id))
            alerted.subtract(Set(alerted).subtracting(active))
            snoozed = snoozed.filter { active.contains($0.key) }
        }
        self.events = allEvents.sorted { $0.start < $1.start }
        self.errors = newErrors
        self.lastRefresh = Date()
        self.isRefreshing = false
        if pendingRefresh || fetched.map(\.id) != subscriptions.filter(\.isEnabled).map(\.id) || fetched.map(\.url) != subscriptions.filter(\.isEnabled).map(\.url) {
            pendingRefresh = false
            refresh()
        }
    }

    private func reconcileEvents() {
        let byID = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0.colorHex.isEmpty ? Palette.hex(for: $0.colorIndex) : $0.colorHex) })
        let enabled = Set(subscriptions.filter(\.isEnabled).map(\.id))
        let next = events.compactMap { event -> MeetingEvent? in
            guard enabled.contains(event.calendarID) else { return nil }
            var copy = event
            if let hex = byID[event.calendarID] { copy.colorHex = hex }
            return copy
        }
        if next.map(\.id) != events.map(\.id) {
            let active = Set(next.map(\.id))
            alerted.subtract(Set(alerted).subtracting(active))
            snoozed = snoozed.filter { active.contains($0.key) }
        }
        events = next
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
        if let data = try? JSONEncoder().encode(Persisted(subscriptions: subscriptions, settings: settings)) {
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
