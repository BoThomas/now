import SwiftUI
import AppKit
import EventKit
import ServiceManagement

struct MeetingReminderDecision {
    let present: [MeetingEvent]
    let dismiss: [MeetingEvent]
}

enum MenuBarCountdownKind: Equatable {
    /// Count toward (or briefly back from) one or more meetings' shared start.
    case start
    /// No future meeting exists; show when the selected running meeting ends.
    case end
}

struct MenuBarFocus {
    let kind: MenuBarCountdownKind
    let date: Date
    /// More than one event when multiple unmuted meetings share the selected
    /// start/end instant. The menu bar renders their colors as a dot cluster.
    let events: [MeetingEvent]
}

/// All app state is main-actor (AppKit/MainActor by design — see AGENTS.md).
/// Pure, unit-tested decision logic is `nonisolated` so the selftest can drive
/// it without constructing an `AppStore` (and its `EKEventStore`).
@MainActor
final class AppStore: ObservableObject {
    nonisolated static let storageKey = "local.tboch.now.state.v1"
    nonisolated static let legacyDomain = "local.tboch.now"
    nonisolated static let soundNames = ["Basso", "Blow", "Bottle", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

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
    /// Per-calendar feed warnings (events skipped or degraded — e.g. unknown
    /// time zone, unsupported RRULE). Shown in orange in the settings rows.
    @Published private(set) var warnings: [UUID: String] = [:]
    @Published private(set) var isRefreshing = false
    /// Time of the last refresh where every fetched subscription succeeded — a
    /// failed or partial attempt never updates this (it is what "Last synced"
    /// in the UI means).
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var meetingActivity: MeetingActivity = .unknown
    @Published private(set) var meetingDetectionChecking = false
    @Published private(set) var meetingDetectionAvailable: Bool? = MeetingActivityProbe.platformPotentiallySupported ? nil : false
    @Published private(set) var meetingDetectionError: String?
    @Published private(set) var pausedUntil: Date? {
        didSet { persist() }
    }

    var onAlert: (([MeetingEvent]) -> Void)?
    weak var alertController: AlertController?
    /// Injectable clock — reminder scheduling reads time only through this, so
    /// late-delivery semantics (wake, delayed launch, delayed refresh) are
    /// testable without waiting.
    var now: () -> Date = { Date() }

    /// Owns the single long-lived EKEventStore (see NativeCalendarSource docs).
    let nativeSource = NativeCalendarSource()
    private let meetingActivitySource = MeetingActivitySource()
    private var nativeEvents: [MeetingEvent] = []
    /// Every calendar that ever fed us native events this session — used to tell native
    /// events apart from ICS ones by `calendarID` even after the calendar is removed.
    private var knownNativeCalendarIDs: Set<UUID> = []
    private var previousEnabledNativeIDs: Set<UUID> = []
    private var previousSkipDeclined = true
    private var previousRefreshMinutes = AppSettings().refreshMinutes
    private var previousIncludeBrowserMeetings = false
    private var nativeChangeDebounce: Timer?
    private var activeObserver: NSObjectProtocol?
    private var meetingEnableGeneration = 0

    private var alerted: Set<String> = []
    private var snoozed: [String: Date] = [:]
    /// IDs present in the most recent `commitEvents` — lets the prune there require
    /// two consecutive misses before dropping alert/snooze bookkeeping.
    private var previousCommitIDs: Set<String> = []
    /// Last observed muted state, retained across one missing commit just like
    /// alert/snooze bookkeeping. A transient omission must not hide an unmute
    /// transition when the event returns inside its lead window.
    private var recentMutedByID: [String: Bool] = [:]
    private var pendingRefresh = false
    private var fetchTracker = FetchTracker()
    private var tickTimer: Timer?
    private var refreshTimer: Timer?
    private var started = false

    nonisolated static let transportDelegate = CalendarTransportDelegate()
    nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: transportDelegate, delegateQueue: nil)
    }()

    init() {
        let state = Self.loadState()
        subscriptions = state.subscriptions
        settings = state.settings
        nativeCalendars = state.nativeCalendars
        pausedUntil = state.pausedUntil
        previousEnabledIDs = Set(subscriptions.filter(\.isEnabled).map(\.id))
        knownNativeCalendarIDs = Set(nativeCalendars.map(\.id))
        previousEnabledNativeIDs = Set(nativeCalendars.filter(\.isEnabled).map(\.id))
        previousSkipDeclined = settings.skipDeclined
        previousRefreshMinutes = settings.refreshMinutes
        previousIncludeBrowserMeetings = settings.includeBrowserMeetings
        // Re-encode once at launch so schema migrations are materialized
        // immediately. In particular, the obsolete `lateMinutes` key is
        // removed and `elapsedStartMinutes: 10` is stored for existing users.
        persist()
    }

    deinit {
        tickTimer?.invalidate()
        refreshTimer?.invalidate()
        nativeChangeDebounce?.invalidate()
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    func start() {
        guard !started else { return }
        started = true
        refreshNativeAuthorization()
        nativeSource.onStoreChange = { [weak self] in self?.scheduleNativeStoreRefresh() }
        meetingActivitySource.onActivityChange = { [weak self] activity in
            self?.meetingActivity = activity
            if activity != .unknown { self?.meetingDetectionError = nil }
        }
        meetingActivitySource.onProbeFailure = { [weak self] message in
            self?.meetingDetectionError = message
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue — hop into our MainActor context.
            MainActor.assumeIsolated {
                self?.appBecameActive()
            }
        }
        scheduleRefreshTimer()
        tickTimer = Self.commonTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop — hop into our MainActor context.
            MainActor.assumeIsolated { self?.tick() }
        }
        syncLoginItem(settings.launchAtLogin)
        if settings.suppressRemindersDuringMeetings {
            setMeetingSuppressionEnabled(true)
        }
        refresh()
    }

    /// Timers must fire in `.common` mode: `.default`-mode timers stall while a
    /// menu is tracking (status menu open) or a modal loop runs — exactly when a
    /// reminder deadline is most likely to pass unnoticed.
    static func commonTimer(withTimeInterval interval: TimeInterval, repeats: Bool, block: @escaping @Sendable (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    var isPaused: Bool {
        if let until = pausedUntil { return Date() < until }
        return false
    }

    func isVisible(_ event: MeetingEvent, at now: Date) -> Bool {
        Self.isVisible(event, at: now)
    }

    /// Menu/list visibility is deliberately independent from the menu bar's
    /// recent-start window: future events and meetings that are still running
    /// remain available in the dropdown until their scheduled end.
    nonisolated static func isVisible(_ event: MeetingEvent, at now: Date) -> Bool {
        now < event.start || now < event.end
    }

    var upcoming: [MeetingEvent] {
        let now = Date()
        return events.filter { isVisible($0, at: now) }
    }

    var menuBarFocus: MenuBarFocus? {
        Self.menuBarFocus(events: events, elapsedStartMinutes: settings.elapsedStartMinutes, now: Date())
    }

    /// Whether a running event may still show its elapsed-start countdown.
    /// Finite windows are capped at the event end: an ended five-minute event
    /// must not remain the focus merely because the user selected 60 minutes.
    nonisolated static func isWithinStartedCountdownWindow(_ event: MeetingEvent, elapsedStartMinutes: Int, now: Date) -> Bool {
        guard event.start <= now, now < event.end, elapsedStartMinutes >= 0 else { return false }
        if elapsedStartMinutes == 0 { return true }
        return now < event.start.addingTimeInterval(TimeInterval(elapsedStartMinutes) * 60)
    }

    /// Pure status-item selection. Among the next future start and still-
    /// eligible recent starts, the closest start wins; a future start wins an
    /// exact midpoint tie. Thus the setting is a maximum negative-countdown
    /// window, while closely spaced meetings switch naturally at their midpoint.
    /// If no start candidate remains and no future meeting exists, the soonest
    /// ending running meeting supplies an explicit `ends …` fallback.
    nonisolated static func menuBarFocus(events: [MeetingEvent], elapsedStartMinutes: Int, now: Date) -> MenuBarFocus? {
        let eligible = events.filter { !$0.isMuted }
        let startCandidates = eligible.filter { event in
            event.start > now || isWithinStartedCountdownWindow(event, elapsedStartMinutes: elapsedStartMinutes, now: now)
        }

        if let selected = startCandidates.min(by: { lhs, rhs in
            let lhsDistance = abs(lhs.start.timeIntervalSince(now))
            let rhsDistance = abs(rhs.start.timeIntervalSince(now))
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            let lhsIsFuture = lhs.start > now
            let rhsIsFuture = rhs.start > now
            if lhsIsFuture != rhsIsFuture { return lhsIsFuture }
            return (lhs.start, lhs.calendarName, lhs.title, lhs.id) < (rhs.start, rhs.calendarName, rhs.title, rhs.id)
        }) {
            let group = startCandidates
                .filter { $0.start == selected.start }
                .sorted { ($0.calendarName, $0.title, $0.id) < ($1.calendarName, $1.title, $1.id) }
            return MenuBarFocus(kind: .start, date: selected.start, events: group)
        }

        let running = eligible.filter { $0.start <= now && now < $0.end }
        guard let soonestEnd = running.map(\.end).min() else { return nil }
        let group = running
            .filter { $0.end == soonestEnd }
            .sorted { ($0.calendarName, $0.title, $0.id) < ($1.calendarName, $1.title, $1.id) }
        return MenuBarFocus(kind: .end, date: soonestEnd, events: group)
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

    // MARK: - Title filters (muted meetings)

    /// Row-toggle add path: adds an exact-title rule for `event`'s calendar.
    /// The owning calendar is resolved by `calendarID` (subscriptions first,
    /// native second); unknown calendar or empty title → no-op (the UI disables
    /// the button for empty titles anyway).
    func toggleMute(for event: MeetingEvent) {
        guard !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let index = subscriptions.firstIndex(where: { $0.id == event.calendarID }) {
            setTitleFilters(calendarID: event.calendarID, rules: TitleFilterRule.addingExact(title: event.title, rules: subscriptions[index].titleFilters))
        } else if let index = nativeCalendars.firstIndex(where: { $0.id == event.calendarID }) {
            setTitleFilters(calendarID: event.calendarID, rules: TitleFilterRule.addingExact(title: event.title, rules: nativeCalendars[index].titleFilters))
        }
    }

    /// Commits a full rule list for one calendar (editor Save, popover Remove).
    /// Normalizes (trim, dedupe, cap); the didSet persist + reconcile recomputes
    /// every affected event's muted flag in place.
    func setTitleFilters(calendarID: UUID, rules: [TitleFilterRule]) {
        let normalized = TitleFilterRule.normalized(rules)
        if let index = subscriptions.firstIndex(where: { $0.id == calendarID }) {
            subscriptions[index].titleFilters = normalized
        } else if let index = nativeCalendars.firstIndex(where: { $0.id == calendarID }) {
            nativeCalendars[index].titleFilters = normalized
        }
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
    /// Reentrant clicks while a request is in flight are ignored (one prompt, one fetch).
    private var accessGate = AccessRequestGate()

    func requestNativeAccess() {
        guard accessGate.shouldStart() else { return }
        let source = nativeSource
        Task { [weak self] in
            let granted = await source.requestAccess()
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.accessGate.finish()
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
        guard nativeSource.isAuthorized else { return }
        nativeChangeDebounce?.invalidate()
        // Always refresh the available-calendar list on store changes (color/
        // title/visibility edits matter even with nothing enabled); events are
        // only re-fetched when a native calendar is enabled.
        nativeChangeDebounce = Self.commonTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetchNativeEvents() }
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
        // The user may have toggled us in System Settings → Login Items.
        if loginItem.currentStatus == .enabled, !settings.launchAtLogin {
            settings.launchAtLogin = true // adopt external enablement (didSet re-syncs state)
        } else {
            loginItemState = Self.resolvedLoginItemState(desired: settings.launchAtLogin, failed: false, status: loginItem.currentStatus)
        }
    }

    /// Native events for currently-enabled native calendars, tinted per current
    /// settings and re-flagged against current title-filter rules.
    private func coloredNativeSnapshot() -> [MeetingEvent] {
        let byID = Dictionary(uniqueKeysWithValues: nativeCalendars.map { ($0.id, $0.colorHex.isEmpty ? Palette.hex(for: $0.colorIndex) : $0.colorHex) })
        let enabled = Set(nativeCalendars.filter(\.isEnabled).map(\.id))
        let tinted = nativeEvents.filter { enabled.contains($0.calendarID) }.map { event in
            var copy = event
            if let hex = byID[event.calendarID] { copy.colorHex = hex }
            return copy
        }
        return TitleFilterMatcher.applying(to: tinted, nativeCalendars: nativeCalendars)
    }

    /// Recombine the ICS half of `events` (untouched) with the current native snapshot.
    private func rebuildEvents() {
        commitEvents(currentICSEvents + coloredNativeSnapshot())
    }

    /// The ICS-fed half of the published event list (native events are tracked
    /// by `knownNativeCalendarIDs` and merged in separately).
    private var currentICSEvents: [MeetingEvent] {
        events.filter { !knownNativeCalendarIDs.contains($0.calendarID) }
    }

    private func reconcileNativeEvents() {
        let enabled = Set(nativeCalendars.filter(\.isEnabled).map(\.id))
        knownNativeCalendarIDs.formUnion(nativeCalendars.map(\.id))
        nativeEvents = nativeEvents.filter { enabled.contains($0.calendarID) }
        rebuildEvents()
    }

    func resync(subscriptionID: UUID) {
        guard let subscription = subscriptions.first(where: { $0.id == subscriptionID }) else { return }
        let requestID = fetchTracker.begin(subscriptionID: subscriptionID)
        Task { [weak self] in
            let results = await Self.performFetch(requests: [FetchRequest(subscription: subscription, requestID: requestID)])
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.merge(results: results)
            }
        }
    }

    private func merge(results: [FetchResult]) {
        let merged = Self.mergeICS(current: currentICSEvents, results: results, live: subscriptions, previousErrors: errors, previousWarnings: warnings, latestRequestIDs: fetchTracker.latestPerSubscription)
        errors = merged.errors
        warnings = merged.warnings
        commitEvents(merged.events + coloredNativeSnapshot())
    }

    /// Pure decision core for applying fetch results to the ICS half of the
    /// event list — extracted so refresh semantics are unit-testable without an
    /// `AppStore` (or EventKit). Rules:
    /// - A failed subscription keeps its cached events and records the error:
    ///   one bad/empty response must not delete that calendar's meetings.
    /// - A result whose subscription was removed or disabled after the request
    ///   started is dropped entirely (a late response must not resurrect a
    ///   removed calendar), and the subscription's cached events are dropped too.
    /// - A result whose subscription URL changed after the request started is
    ///   stale and dropped, keeping the cached events.
    /// - A result superseded by a newer request for the same subscription
    ///   (`latestRequestIDs`) is stale and dropped, keeping the cached events —
    ///   out-of-order completion must never overwrite newer data.
    /// - Cached events of subscriptions that no longer exist or are disabled
    ///   are dropped.
    /// - Successful results carry feed warnings (degraded events) alongside
    ///   events; failures keep the previous warning untouched.
    nonisolated static func mergeICS(current: [MeetingEvent], results: [FetchResult], live: [CalendarSubscription], previousErrors: [UUID: String], previousWarnings: [UUID: String] = [:], latestRequestIDs: [UUID: Int] = [:]) -> (events: [MeetingEvent], errors: [UUID: String], warnings: [UUID: String], allSucceeded: Bool) {
        let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        let colorByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0.colorHex.isEmpty ? Palette.hex(for: $0.colorIndex) : $0.colorHex) })
        // Muted flags come from the LIVE rules — a fetch that started before a
        // rule edit must land with the new flags applied, exactly like colors.
        let matchers = TitleFilterMatcher.byCalendar(subscriptions: live)
        var events = current.compactMap { event -> MeetingEvent? in
            guard let subscription = liveByID[event.calendarID], subscription.isEnabled else { return nil }
            var copy = event
            if let hex = colorByID[event.calendarID] { copy.colorHex = hex }
            copy.isMuted = matchers[event.calendarID]?.matches(title: event.title) ?? false
            return copy
        }
        let enabledIDs = Set(live.filter(\.isEnabled).map(\.id))
        var errors = previousErrors.filter { enabledIDs.contains($0.key) }
        var warnings = previousWarnings.filter { enabledIDs.contains($0.key) }
        var allSucceeded = true
        for result in results {
            guard let subscription = liveByID[result.subscription.id],
                  subscription.isEnabled,
                  subscription.url == result.subscription.url,
                  latestRequestIDs[result.subscription.id, default: result.requestID] == result.requestID else {
                allSucceeded = false
                continue
            }
            if let error = result.error {
                errors[subscription.id] = error
                allSucceeded = false
                continue // failed fetch: keep the cached events
            }
            errors.removeValue(forKey: subscription.id)
            if let warning = result.warning {
                warnings[subscription.id] = warning
            } else {
                warnings.removeValue(forKey: subscription.id)
            }
            events.removeAll { $0.calendarID == subscription.id }
            events.append(contentsOf: result.events.map { event in
                var copy = event
                if let hex = colorByID[event.calendarID] { copy.colorHex = hex }
                copy.isMuted = matchers[event.calendarID]?.matches(title: event.title) ?? false
                return copy
            })
        }
        return (events, errors, warnings, allSucceeded)
    }


    func snooze(_ ids: [String]) {
        let fireAt = Date().addingTimeInterval(60)
        for id in ids { snoozed[id] = fireAt }
    }

    func pause(for seconds: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(seconds)
    }

    func pauseUntilMorning() {
        pausedUntil = Self.nextMorning(after: Date())
    }

    /// Tomorrow at 09:00 via calendar arithmetic (start-of-day + set hour) — a
    /// fixed +86,400 s lands an hour off across DST transitions.
    nonisolated static func nextMorning(after date: Date, calendar: Calendar = .current) -> Date? {
        let cal = calendar
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: date) else { return nil }
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.startOfDay(for: tomorrow))
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

    func setMeetingSuppressionEnabled(_ enabled: Bool) {
        meetingEnableGeneration += 1
        let requestGeneration = meetingEnableGeneration
        meetingDetectionError = nil

        guard enabled else {
            meetingDetectionChecking = false
            settings.suppressRemindersDuringMeetings = false
            meetingActivitySource.stop()
            return
        }
        guard MeetingActivityProbe.platformPotentiallySupported else {
            meetingDetectionAvailable = false
            settings.suppressRemindersDuringMeetings = false
            meetingDetectionError = "Meeting detection requires macOS 14 or later."
            return
        }

        meetingDetectionChecking = true
        meetingActivity = .unknown
        meetingActivitySource.checkCapability { [weak self] result in
            guard let self, requestGeneration == self.meetingEnableGeneration else { return }
            self.meetingDetectionChecking = false
            switch result {
            case .success(let owners):
                self.meetingDetectionAvailable = true
                self.settings.suppressRemindersDuringMeetings = true
                self.meetingActivitySource.start(
                    includeBrowsers: self.settings.includeBrowserMeetings,
                    initialOwners: owners)
            case .failure(let error):
                if case .processListUnavailable = error {
                    self.meetingDetectionAvailable = false
                } else {
                    // Enumeration can fail while CoreAudio's process list is
                    // changing. Keep the toggle retryable for transient errors.
                    self.meetingDetectionAvailable = nil
                }
                self.settings.suppressRemindersDuringMeetings = false
                self.meetingDetectionError = error.message
                self.meetingActivitySource.stop()
            }
        }
    }

    func refreshMeetingActivityAfterWake() {
        meetingActivitySource.refreshAfterWake()
    }

    func refresh() {
        fetchNativeEvents()
        let enabled = subscriptions.filter(\.isEnabled)
        guard !isRefreshing else {
            pendingRefresh = true
            return
        }
        isRefreshing = true
        let requestID = fetchTracker.beginFull(subscriptionIDs: enabled.map(\.id))
        Task { [weak self] in
            let results = await Self.performFetch(requests: enabled.map { FetchRequest(subscription: $0, requestID: requestID) })
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.apply(results: results, fetched: enabled)
            }
        }
    }

    nonisolated static func performFetch(requests: [FetchRequest]) async -> [FetchResult] {
        await withTaskGroup(of: FetchResult.self) { group in
            for request in requests {
                group.addTask {
                    let sub = request.subscription
                    let (data, fetchError) = await fetchData(sub.url)
                    if let fetchError { return FetchResult(subscription: sub, events: [], error: fetchError, requestID: request.requestID) }
                    guard let data else { return FetchResult(subscription: sub, events: [], error: "Empty response", requestID: request.requestID) }
                    if data.count > Self.maxFeedBytes {
                        return FetchResult(subscription: sub, events: [], error: "Feed larger than \(Self.maxFeedBytes / 1_000_000) MB", requestID: request.requestID)
                    }
                    let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                    if !text.uppercased().contains("BEGIN:VCALENDAR") { return FetchResult(subscription: sub, events: [], error: "Not an iCal feed", requestID: request.requestID) }
                    let (events, warnings) = ICSBuilder.meetings(fromICS: text, subscription: sub, now: Date())
                    let warning = warnings.isEmpty ? nil : warnings.prefix(5).joined(separator: " · ")
                    return FetchResult(subscription: sub, events: events, error: nil, warning: warning, requestID: request.requestID)
                }
            }
            var results: [FetchResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }


    /// Hard cap on downloaded feed size — a hostile feed must not be able to
    /// balloon memory or parser workload. (The body is still downloaded before
    /// the check; the 25 s request timeout bounds the transient spike.)
    nonisolated static let maxFeedBytes = 5 * 1_000_000

    nonisolated static func fetchData(_ urlString: String) async -> (Data?, String?) {
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
        let merged = Self.mergeICS(current: currentICSEvents, results: results, live: subscriptions, previousErrors: errors, previousWarnings: warnings, latestRequestIDs: fetchTracker.latestPerSubscription)
        commitEvents(merged.events + coloredNativeSnapshot())
        errors = merged.errors
        warnings = merged.warnings
        if merged.allSucceeded { lastRefresh = Date() }
        isRefreshing = false
        if pendingRefresh || fetched.map(\.id) != subscriptions.filter(\.isEnabled).map(\.id) || fetched.map(\.url) != subscriptions.filter(\.isEnabled).map(\.url) {
            pendingRefresh = false
            refresh()
        }
    }

    /// Single funnel for publishing the merged (ICS + native) event list: sorts
    /// with stable tie-breakers, dedupes by event id, and prunes alert/snooze
    /// bookkeeping for events that disappeared. An id is only pruned once it's
    /// missing from **two consecutive commits**: a single miss is treated as
    /// transient (a fetch racing a CalDAV sync, one bad/empty ICS response) so a
    /// reappearing event neither re-alerts nor loses its snooze. Bookkeeping for
    /// ids absent from `events` is inert — `tick()` only looks at `events` — so
    /// the extra commit of lag is harmless.
    private func commitEvents(_ newEvents: [MeetingEvent]) {
        let sorted = Self.normalizedEvents(newEvents)
        let active = Set(sorted.map(\.id))
        let pruned = Self.prunedBookkeeping(alerted: alerted, snoozed: snoozed, activeIDs: active, previousIDs: previousCommitIDs)
        // Single funnel for EVERY event-list change — rule edits, ICS refreshes
        // (a title edit keeps the same id and can flip muted→unmuted mid-window),
        // and native rebuilds all pass through here, so the unmute ratchet lives
        // here and nowhere else.
        let ratcheted = Self.ratchetSilence(previous: events, fallbackMutedByID: recentMutedByID, current: sorted, alerted: pruned.alerted, snoozed: pruned.snoozed, leadSeconds: settings.leadSeconds, now: now())
        alerted = ratcheted.alerted
        snoozed = ratcheted.snoozed
        recentMutedByID = Self.retainedMutedStates(previous: recentMutedByID, current: sorted, previousIDs: previousCommitIDs)
        previousCommitIDs = active
        events = sorted
        // Keep an open alert in sync: cancelled/removed/disabled events drop
        // off the cards, changed events update in place.
        alertController?.reconcile(withCurrent: sorted)
    }

    /// Pure unmute ratchet: an event that transitions muted→unmuted while its
    /// lead window already started must never pop a surprise fullscreen alert
    /// (the user deleted/edited a rule, or a title stopped matching on refresh).
    /// Silencing means alerted[id] = true AND snoozed[id] removed — a snoozed +
    /// alerted event re-fires once its snooze expires, so both are required.
    /// Events unmuted before their window are untouched; brand-new events (no
    /// previous id) are untouched — that is intended late-delivery behavior.
    nonisolated static func ratchetSilence(previous: [MeetingEvent], fallbackMutedByID: [String: Bool] = [:], current: [MeetingEvent], alerted: Set<String>, snoozed: [String: Date], leadSeconds: Int, now: Date) -> (alerted: Set<String>, snoozed: [String: Date]) {
        var wasMuted = fallbackMutedByID
        for event in previous { wasMuted[event.id] = event.isMuted }
        var alerted = alerted
        var snoozed = snoozed
        let lead = TimeInterval(leadSeconds)
        for event in current {
            guard wasMuted[event.id] == true, !event.isMuted else { continue }
            guard now >= event.start.addingTimeInterval(-lead), now < event.end else { continue }
            alerted.insert(event.id)
            snoozed.removeValue(forKey: event.id)
        }
        return (alerted, snoozed)
    }

    /// Keeps current states plus states missing from exactly one commit. On the
    /// second consecutive miss `previousIDs` no longer contains the id, so it drops.
    nonisolated static func retainedMutedStates(previous: [String: Bool], current: [MeetingEvent], previousIDs: Set<String>) -> [String: Bool] {
        var retained = previous.filter { previousIDs.contains($0.key) }
        for event in current { retained[event.id] = event.isMuted }
        return retained
    }

    /// Deterministic ordering + dedup for the published event list: stable
    /// tie-breakers after `start` (calendar, title, id) so equal start times
    /// don't shuffle between commits, and one entry per id so duplicate
    /// reminder cards / ForEach ids can't appear.
    nonisolated static func normalizedEvents(_ events: [MeetingEvent]) -> [MeetingEvent] {
        var seen = Set<String>()
        var unique: [MeetingEvent] = []
        for event in events.sorted(by: { ($0.start, $0.calendarName, $0.title, $0.id) < ($1.start, $1.calendarName, $1.title, $1.id) }) {
            if seen.insert(event.id).inserted { unique.append(event) }
        }
        return unique
    }

    /// Pure pruning decision for alert/snooze bookkeeping: an id is dropped
    /// only when missing from both the new snapshot and the previous one (two
    /// consecutive misses). Runs on every commit — the second identical missing
    /// snapshot does prune, matching the documented behavior.
    nonisolated static func prunedBookkeeping(alerted: Set<String>, snoozed: [String: Date], activeIDs: Set<String>, previousIDs: Set<String>) -> (alerted: Set<String>, snoozed: [String: Date]) {
        let prunable = alerted.union(snoozed.keys).filter { !activeIDs.contains($0) && !previousIDs.contains($0) }
        return (alerted.subtracting(prunable), snoozed.filter { !prunable.contains($0.key) })
    }

    private func reconcileEvents() {
        let byID = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0.colorHex.isEmpty ? Palette.hex(for: $0.colorIndex) : $0.colorHex) })
        let enabled = Set(subscriptions.filter(\.isEnabled).map(\.id))
        let native = events.filter { knownNativeCalendarIDs.contains($0.calendarID) }
        let tintedICS = events.compactMap { event -> MeetingEvent? in
            if knownNativeCalendarIDs.contains(event.calendarID) { return nil }
            guard enabled.contains(event.calendarID) else { return nil }
            var copy = event
            if let hex = byID[event.calendarID] { copy.colorHex = hex }
            return copy
        }
        let next = TitleFilterMatcher.applying(to: tintedICS, subscriptions: subscriptions) + native
        commitEvents(next)
    }

    private func tick() {
        let now = self.now()
        if let until = pausedUntil, now >= until { pausedUntil = nil }
        if let alerts = alertController, alerts.isOpen {
            if alerts.shownEvents.allSatisfy({ now.timeIntervalSince($0.end) > 120 }) {
                alerts.close()
            }
        }
        if isPaused { return }
        let due = Self.dueForAlert(events: events, alerted: alerted, snoozed: snoozed, leadSeconds: settings.leadSeconds, now: now)
        guard !due.isEmpty else { return }
        let decision = Self.meetingReminderDecision(
            due: due,
            suppressionEnabled: settings.suppressRemindersDuringMeetings,
            activity: meetingActivity,
            now: now)
        decision.dismiss.forEach {
            alerted.insert($0.id)
            snoozed.removeValue(forKey: $0.id)
        }
        guard !decision.present.isEmpty else { return }
        decision.present.forEach {
            alerted.insert($0.id)
            snoozed.removeValue(forKey: $0.id)
        }
        onAlert?(decision.present)
    }

    nonisolated static func meetingReminderDecision(due: [MeetingEvent], suppressionEnabled: Bool, activity: MeetingActivity, now: Date) -> MeetingReminderDecision {
        guard suppressionEnabled, case .meeting = activity else {
            return MeetingReminderDecision(present: due, dismiss: [])
        }
        return MeetingReminderDecision(
            present: [],
            dismiss: due.filter { now >= $0.start })
    }

    /// Pure, clock-driven reminder-scheduling decision: which events fire a
    /// reminder at `now`? A reminder fires from the start of the lead window
    /// until the meeting **ends** — late delivery (wake from sleep, delayed
    /// launch, delayed refresh, blocked UI) still alerts instead of being
    /// silently dropped by the old 45-second deadline. A snoozed reminder
    /// re-fires when its snooze expires, again only while `now < event.end`.
    /// Title-muted events never fire — the pure seam `tick()` shares with tests.
    nonisolated static func dueForAlert(events: [MeetingEvent], alerted: Set<String>, snoozed: [String: Date], leadSeconds: Int, now: Date) -> [MeetingEvent] {
        let lead = TimeInterval(leadSeconds)
        return events.filter { event in
            if event.isMuted { return false }
            if alerted.contains(event.id) {
                if let fireAt = snoozed[event.id], now >= fireAt, now < event.end { return true }
                return false
            }
            return now >= event.start.addingTimeInterval(-lead) && now < event.end
        }
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(5, settings.refreshMinutes)) * 60
        refreshTimer = Self.commonTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func settingsChanged() {
        persist()
        if Self.refreshIntervalChanged(from: previousRefreshMinutes, to: settings.refreshMinutes) {
            previousRefreshMinutes = settings.refreshMinutes
            scheduleRefreshTimer()
        }
        if !syncingLoginItem {
            syncLoginItem(settings.launchAtLogin)
        }
        if settings.skipDeclined != previousSkipDeclined {
            previousSkipDeclined = settings.skipDeclined
            fetchNativeEvents()
        }
        if settings.includeBrowserMeetings != previousIncludeBrowserMeetings {
            previousIncludeBrowserMeetings = settings.includeBrowserMeetings
            if settings.suppressRemindersDuringMeetings {
                meetingActivitySource.setIncludeBrowsers(settings.includeBrowserMeetings)
            }
        }
    }

    nonisolated static func refreshIntervalChanged(from previous: Int, to current: Int) -> Bool {
        previous != current
    }

    // MARK: - Login item (Launch at Login)

    /// What the UI shows for Launch at Login — actual state, distinct from the
    /// persisted user intent (`settings.launchAtLogin`).
    enum LoginItemState: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case failed
    }

    /// Observable status mirror of `SMAppService.Status` (kept free of
    /// ServiceManagement so the mapping logic is unit-testable).
    enum LoginItemStatus: Equatable {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
    }

    /// Injectable seam over `SMAppService` — tests script this; the app uses
    /// `SystemLoginItem`.
    protocol LoginItemControlling: AnyObject {
        var currentStatus: LoginItemStatus { get }
        func register() throws
        func unregister() throws
    }

    final class SystemLoginItem: LoginItemControlling {
        var currentStatus: LoginItemStatus {
            switch SMAppService.mainApp.status {
            case .enabled: return .enabled
            case .requiresApproval: return .requiresApproval
            case .notRegistered: return .notRegistered
            case .notFound: return .notFound
            @unknown default: return .notRegistered
            }
        }

        func register() throws {
            try SMAppService.mainApp.register()
        }

        func unregister() throws {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Injectable seam so the selftest can drive a scripted login item.
    var loginItem: LoginItemControlling = SystemLoginItem()
    @Published private(set) var loginItemState: LoginItemState = .disabled
    /// Reentrancy guard: reverting `settings.launchAtLogin` on failure fires
    /// `didSet` → `settingsChanged` → `syncLoginItem` again — that second run
    /// would clobber the `.failed` state.
    private var syncingLoginItem = false

    /// Pure resolution of the observed login-item state.
    /// - System enabled → `.enabled` (even if intent is off — external wins).
    /// - Intent on + requiresApproval → `.requiresApproval`.
    /// - Intent on but not registered (register failed or externally disabled)
    ///   → `.failed`.
    /// - Otherwise → `.disabled`.
    nonisolated static func resolvedLoginItemState(desired: Bool, failed: Bool, status: LoginItemStatus) -> LoginItemState {
        if failed { return .failed }
        if status == .enabled { return .enabled }
        if desired {
            return status == .requiresApproval ? .requiresApproval : .failed
        }
        return .disabled
    }

    /// Restores intent to the unchanged system state after an operation fails.
    nonisolated static func resolvedLoginItemOutcome(desired: Bool, operationFailed: Bool, status: LoginItemStatus) -> (desired: Bool, state: LoginItemState) {
        let effectiveDesired = operationFailed ? !desired : desired
        let registrationFailed = operationFailed && desired
        return (effectiveDesired, resolvedLoginItemState(desired: effectiveDesired, failed: registrationFailed, status: status))
    }

    private func syncLoginItem(_ desired: Bool) {
        var failed = false
        if desired {
            switch loginItem.currentStatus {
            case .enabled, .requiresApproval:
                break
            case .notRegistered, .notFound:
                do { try loginItem.register() } catch { failed = true }
            }
        } else {
            switch loginItem.currentStatus {
            case .enabled:
                do { try loginItem.unregister() } catch { failed = true }
            case .requiresApproval, .notRegistered, .notFound:
                break
            }
        }
        let outcome = Self.resolvedLoginItemOutcome(desired: desired, operationFailed: failed, status: loginItem.currentStatus)
        if outcome.desired != desired {
            syncingLoginItem = true
            settings.launchAtLogin = outcome.desired
            syncingLoginItem = false
        }
        loginItemState = outcome.state
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Persisted(subscriptions: subscriptions, settings: settings, nativeCalendars: nativeCalendars, pausedUntil: pausedUntil)) {
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

/// Calendar subscriptions may start on HTTP only after explicit user consent.
/// Once a request starts securely, redirects must not silently downgrade it to
/// cleartext and expose the private token commonly embedded in an ICS URL.
final class CalendarTransportDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated static func allowsRedirect(from source: URL?, to destination: URL?) -> Bool {
        guard let destination,
              let destinationScheme = destination.scheme?.lowercased(),
              destinationScheme == "http" || destinationScheme == "https" else { return false }
        guard source?.scheme?.lowercased() == "https" else { return true }
        return destinationScheme == "https"
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let source = response.url ?? task.currentRequest?.url
        completionHandler(Self.allowsRedirect(from: source, to: request.url) ? request : nil)
    }
}

/// Pure single-flight gate for the EventKit permission request: repeated
/// clicks must not stack prompts/fetches. Unit-testable without TCC.
struct AccessRequestGate {
    private var inFlight = false

    mutating func shouldStart() -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        return true
    }

    mutating func finish() {
        inFlight = false
    }
}

/// Tracks the newest fetch request per subscription so late asynchronous
/// results never overwrite newer data (pure — unit-testable without an
/// AppStore). A full refresh supersedes every in-flight targeted resync for
/// the subscriptions it fetches; a targeted resync supersedes the full
/// refresh (and any older resync) for its one subscription.
struct FetchTracker {
    private var nextID = 1
    private(set) var latestPerSubscription: [UUID: Int] = [:]

    mutating func begin(subscriptionID: UUID) -> Int {
        let id = nextID
        nextID += 1
        latestPerSubscription[subscriptionID] = id
        return id
    }

    mutating func beginFull(subscriptionIDs: [UUID]) -> Int {
        let id = nextID
        nextID += 1
        for subscriptionID in subscriptionIDs { latestPerSubscription[subscriptionID] = id }
        return id
    }
}

/// One in-flight fetch: the subscription snapshot the request was made against
/// plus the generation token that decides whether the result is still current
/// when it lands. (Top level — free of AppStore's MainActor isolation so the
/// selftest can construct these directly.)
struct FetchRequest {
    let subscription: CalendarSubscription
    let requestID: Int
}

/// A completed fetch for one subscription: parsed events, an error, an
/// optional feed warning, and the request generation it belongs to.
struct FetchResult {
    let subscription: CalendarSubscription
    let events: [MeetingEvent]
    let error: String?
    var warning: String?
    var requestID = 0

    init(subscription: CalendarSubscription, events: [MeetingEvent], error: String?, warning: String? = nil, requestID: Int = 0) {
        self.subscription = subscription
        self.events = events
        self.error = error
        self.warning = warning
        self.requestID = requestID
    }
}
