import SwiftUI
import AppKit
import EventKit
import ServiceManagement
import UserNotifications

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
    let hadSavedProfile: Bool
    nonisolated static let legacyDomain = "local.tboch.now"
    nonisolated static let soundNames = ["Basso", "Blow", "Bottle", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    @Published var subscriptions: [CalendarSubscription] {
        didSet {
            persist()
            let changedURLs = Self.changedSubscriptionURLs(previous: oldValue, current: subscriptions)
            // Invalidate even A → B → A edits before the replacement fetch starts.
            for id in changedURLs { _ = fetchTracker.begin(subscriptionID: id) }
            let retired = Set(oldValue.filter { old in
                !subscriptions.contains { $0.id == old.id && $0.isEnabled && $0.url == old.url }
            }.map(\.id)).union(changedURLs)
            invalidateCache(retired)
            reconcileEvents(invalidatedCalendarIDs: changedURLs)
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
    /// Completion time of the last full refresh, including partial/total failure.
    /// Per-calendar errors report the outcome separately.
    @Published private(set) var lastChecked: Date?
    /// One common-run-loop clock for elapsed labels in Settings and the menu.
    @Published private(set) var displayTime = Date()
    @Published private(set) var meetingActivity: MeetingActivity = .unknown
    @Published private(set) var meetingDetectionChecking = false
    @Published private(set) var meetingDetectionAvailable: Bool? = MeetingActivityProbe.platformPotentiallySupported ? nil : false
    @Published private(set) var meetingDetectionError: String?
    @Published private(set) var pausedUntil: Date? {
        didSet { persist() }
    }

    var notifications: ReminderNotificationController?
    var featureGuides: FeatureGuideController?
    var validateUpdateNotification: ((ReminderNotification) -> Bool)?
    var updateNotificationSubmitted: ((ReminderNotification) -> Void)?
    var updateNotificationResponse: ((ReminderNotification, String) -> Void)?
    var updateNotificationTick: (() -> Void)?
    var openNotificationLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var openNotificationMeetings: (([MeetingEvent]) -> Void)?
    var openNotificationAgenda: (() -> Void)?
    var openNotificationSyncSettings: (() -> Void)?
    private var reminderLedger = ReminderLedger()
    private var notificationEventsByKey: [String: MeetingEvent] = [:]
    private var ambiguousLegacyNotificationIDs: Set<String> = []
    private var notificationFingerprints: [String: String] = [:]
    private let ledgerKey = "local.tboch.now.reminder-ledger.v1"
    private var catchUpRefresh = CatchUpRefreshTracker()
    private var catchUpBoundary: [UUID: Date] = [:]
    private var catchUpIDs: Set<String> = []
    private var syncNotificationTracker = SyncNotificationTracker()
    private let syncLedgerKey = "local.tboch.now.sync-notifications.v1"
    private var completedInitialRefresh = false
    private var pendingNotificationResponses: [(ReminderNotification, String)] = []
    private var previousNotificationSettings: AppSettings?

    var onAlert: (([MeetingEvent]) -> Void)?
    weak var alertController: AlertController?
    /// Injectable clock — reminder scheduling reads time only through this, so
    /// late-delivery semantics (wake, delayed launch, delayed refresh) are
    /// testable without waiting.
    var now: () -> Date = { Date() }

    /// Owns the single long-lived EKEventStore (see NativeCalendarSource docs).
    let nativeSource = NativeCalendarSource()
    private let meetingActivitySource: MeetingActivitySource
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
    private var meetingRetryAt: Date?
    private var meetingRetryAttempts = 0

    private var alerted: Set<String> = []
    private var snoozed: [String: Date] = [:]
    /// Missing observations are counted per calendar, not per merged commit.
    private var reminderSnapshots = ReminderSnapshotTracker()
    /// Muted state follows the same source-scoped retention as alert/snooze state.
    private var recentMutedByID: [String: Bool] = [:]
    private var pendingRefresh = false
    private var fetchTracker = FetchTracker()
    private var tickTimer: Timer?
    private var refreshTimer: Timer?
    private var started = false
    private let eventCache: CalendarEventCache
    private var cacheLoadTask: Task<CalendarCacheLoad, Never>?
    private var cacheLoaded = false
    private var shuttingDown = false
    private var invalidatedRestoreIDs: Set<UUID> = []
    private var cacheWriteVersions: [UUID: Int] = [:]
    @Published private(set) var cacheInfo: [UUID: CalendarCacheInfo] = [:]
    @Published private(set) var cacheIssues: [UUID: String] = [:]
    @Published private(set) var offlineCalendarIDs: Set<UUID> = []

    nonisolated static let transportDelegate = CalendarTransportDelegate()
    nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: transportDelegate, delegateQueue: nil)
    }()

    init(eventCache: CalendarEventCache = CalendarEventCache(), initialState: Persisted? = nil, meetingActivitySource: MeetingActivitySource? = nil) {
        hadSavedProfile = initialState != nil || UserDefaults.standard.data(forKey: Self.storageKey) != nil
            || UserDefaults(suiteName: Self.legacyDomain)?.data(forKey: Self.storageKey) != nil
        let state = initialState ?? Self.loadState()
        self.eventCache = eventCache
        self.meetingActivitySource = meetingActivitySource ?? MeetingActivitySource()
        cacheLoadTask = Task { await eventCache.load(subscriptions: state.subscriptions) }
        eventCache.retain(Set(state.subscriptions.filter(\.isEnabled).map(\.id)))
        subscriptions = state.subscriptions
        settings = state.settings
        nativeCalendars = state.nativeCalendars
        pausedUntil = state.pausedUntil
        if initialState == nil, let data = UserDefaults.standard.data(forKey: ledgerKey), data.count <= 8_000_000,
           let saved = try? JSONDecoder().decode(ReminderLedger.self, from: data) { reminderLedger = saved }
        if initialState == nil, let data = UserDefaults.standard.data(forKey: syncLedgerKey), data.count <= 1_000_000,
           let saved = try? JSONDecoder().decode(SyncNotificationTracker.self, from: data) { syncNotificationTracker = saved }
        previousNotificationSettings = settings
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
        beginNotificationCatchUp()
        notifications?.refreshPermission(force: true)
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
        scheduleTickTimer()
        syncLoginItem(settings.launchAtLogin)
        if settings.needsMeetingDetection { setInMeetingDelivery(settings.inMeetingDelivery) }
        refresh()
    }

    private func scheduleTickTimer() {
        tickTimer?.invalidate()
        tickTimer = Self.commonTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop — hop into our MainActor context.
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The updater may time out while a disk barrier delays terminateLater.
    func cancelTermination() {
        guard shuttingDown else { return }
        shuttingDown = false
        if started {
            scheduleTickTimer()
            scheduleRefreshTimer()
            refresh()
        }
    }

    /// Restoration is shared by full/targeted refreshes and completes before tick.
    /// Awaiters re-check the flag after suspension so a snapshot is applied once.
    func restoreCachedEvents() async {
        guard !cacheLoaded, let task = cacheLoadTask else { return }
        let loaded = await task.value
        guard !cacheLoaded else { return }
        var restored: [MeetingEvent] = []
        let date = now()
        displayTime = date
        for sub in subscriptions where sub.isEnabled && !invalidatedRestoreIDs.contains(sub.id) {
            if let snapshot = loaded.snapshots[sub.id], snapshot.matches(sub) {
                restored += snapshot.events(subscription: sub, now: date)
                cacheInfo[sub.id] = CalendarCacheInfo(snapshot: snapshot, usingSavedData: true)
                warnings[sub.id] = snapshot.warning
            }
            cacheIssues[sub.id] = loaded.issues[sub.id]
        }
        let merged = Self.mergeICS(current: restored, results: [], live: subscriptions,
                                   previousErrors: errors, previousWarnings: warnings)
        // Disk restore is not a source observation, nor a successful refresh.
        commitEvents(merged.events + coloredNativeSnapshot())
        cacheLoaded = true
        cacheLoadTask = nil
        invalidatedRestoreIDs.removeAll()
    }

    /// Ordinary quit waits for already accepted snapshots, not network requests.
    func prepareForTermination(_ completion: @escaping @Sendable () -> Void) {
        shuttingDown = true
        tickTimer?.invalidate()
        refreshTimer?.invalidate()
        eventCache.whenIdle(completion)
    }

    private func invalidateCache(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        invalidatedRestoreIDs.formUnion(ids)
        for id in ids {
            cacheWriteVersions[id, default: 0] += 1
            cacheInfo.removeValue(forKey: id)
            cacheIssues.removeValue(forKey: id)
            offlineCalendarIDs.remove(id)
        }
        eventCache.remove(ids)
    }

    var calendarSyncProblemTitle: String? {
        let enabled = Set(subscriptions.filter(\.isEnabled).map(\.id))
        let offline = offlineCalendarIDs.intersection(enabled)
        let saved = cacheInfo.contains { enabled.contains($0.key) && $0.value.usingSavedData && $0.value.covers(displayTime) }
        let expired = cacheInfo.contains { enabled.contains($0.key) && !$0.value.covers(displayTime) }
        if !offline.isEmpty {
            let detail = expired ? "Saved calendar coverage expired" : (saved ? "Using saved calendars" : "Calendar sync unavailable")
            let label = offline == enabled ? "Offline" : "\(offline.count) calendar\(offline.count == 1 ? "" : "s") offline"
            return "\(label) · \(detail) · Details…"
        }
        if !errors.isEmpty {
            let count = errors.count
            return "\(count) calendar\(count == 1 ? "" : "s") failed to sync · Details…"
        }
        if expired { return "Saved calendar coverage expired · Refresh needed · Details…" }
        if !cacheIssues.isEmpty { return "Offline calendar storage needs attention · Details…" }
        return nil
    }

    func calendarCacheStatus(_ id: UUID) -> String? {
        guard let info = cacheInfo[id] else { return cacheIssues[id] }
        // Healthy calendars use the shared “Last synced” beside Refresh.
        // Per-source age only adds useful context while something needs attention.
        guard errors[id] != nil || offlineCalendarIDs.contains(id)
                || cacheIssues[id] != nil || !info.covers(displayTime) else { return nil }
        let stamp = info.fetchedAt.formatted(date: .abbreviated, time: .shortened)
        let prefix = info.usingSavedData ? "Using saved data. " : ""
        let coverage = info.covers(displayTime) ? "" : " Saved coverage expired; refresh needed."
        let issue = cacheIssues[id].map { " " + $0 } ?? ""
        return "\(prefix)Last successful sync: \(stamp).\(coverage)\(issue)"
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
        if let until = pausedUntil { return now() < until }
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

    var emptyAgendaText: String {
        return Self.emptyAgendaText(
            configuredCount: subscriptions.count + nativeCalendars.count,
            enabledCount: subscriptions.filter(\.isEnabled).count + nativeCalendars.filter(\.isEnabled).count,
            isRefreshing: isRefreshing,
            hasErrors: !errors.isEmpty,
            nativeAccessMissing: nativeCalendars.contains(where: \.isEnabled) && !nativeSource.isAuthorized,
            expiredCache: cacheInfo.values.contains { !$0.covers(displayTime) })
    }

    nonisolated static func emptyAgendaText(configuredCount: Int, enabledCount: Int, isRefreshing: Bool, hasErrors: Bool, nativeAccessMissing: Bool, expiredCache: Bool = false) -> String {
        if configuredCount == 0 { return "No calendars added" }
        if enabledCount == 0 { return "No calendars enabled" }
        if isRefreshing { return "Checking calendars…" }
        if hasErrors { return "No upcoming meetings. Some calendars failed to sync." }
        if nativeAccessMissing { return "No upcoming meetings. Calendar access needed." }
        if expiredCache { return "No upcoming meetings. Some saved calendars need refreshing." }
        return "No upcoming meetings"
    }

    var upcoming: [MeetingEvent] {
        let now = self.now()
        return events.filter { isVisible($0, at: now) }
    }

    var menuBarFocus: MenuBarFocus? {
        Self.menuBarFocus(events: events, elapsedStartMinutes: settings.elapsedStartMinutes, now: now())
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
        // This addition belongs to the full refresh below, not a second resync.
        previousEnabledIDs.insert(subscription.id)
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
        rebuildEvents(observedCalendarIDs: Set(enabled.map(\.id)))
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
        retryMeetingDetection(force: true)
        notifications?.refreshPermission(force: true)
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
    private func rebuildEvents(observedCalendarIDs: Set<UUID> = []) {
        commitEvents(currentICSEvents + coloredNativeSnapshot(), observedCalendarIDs: observedCalendarIDs)
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
        guard !shuttingDown else { return }
        guard let subscription = subscriptions.first(where: { $0.id == subscriptionID }) else { return }
        let requestID = fetchTracker.begin(subscriptionID: subscriptionID)
        Task { [weak self] in
            await self?.restoreCachedEvents()
            let results = await Self.performFetch(requests: [FetchRequest(subscription: subscription, requestID: requestID)])
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.merge(results: results)
            }
        }
    }

    private func merge(results: [FetchResult]) {
        guard !shuttingDown else { return }
        let merged = Self.mergeICS(current: currentICSEvents, results: results, live: subscriptions, previousErrors: errors, previousWarnings: warnings, latestRequestIDs: fetchTracker.latestPerSubscription)
        errors = merged.errors
        warnings = merged.warnings
        for result in results {
            guard let live = subscriptions.first(where: { $0.id == result.subscription.id }),
                  live.isEnabled, live.url == result.subscription.url,
                  fetchTracker.latestPerSubscription[live.id, default: result.requestID] == result.requestID else { continue }
            if result.isOffline { offlineCalendarIDs.insert(live.id) }
            else { offlineCalendarIDs.remove(live.id) }
            if result.error != nil {
                if var info = cacheInfo[live.id] { info.usingSavedData = true; cacheInfo[live.id] = info }
                continue
            }
            let snapshot = CalendarCacheSnapshot(subscription: live, events: result.events,
                                                 fetchedAt: result.fetchedAt ?? now(), warning: result.warning)
            cacheInfo[live.id] = CalendarCacheInfo(snapshot: snapshot, usingSavedData: false)
            cacheIssues.removeValue(forKey: live.id)
            let version = cacheWriteVersions[live.id, default: 0] + 1
            cacheWriteVersions[live.id] = version
            eventCache.save(snapshot) { [weak self] issue in
                Task { @MainActor [weak self] in
                    guard let self, self.cacheWriteVersions[live.id] == version else { return }
                    self.cacheIssues[live.id] = issue
                }
            }
        }
        commitEvents(merged.events + coloredNativeSnapshot(), observedCalendarIDs: merged.observedCalendarIDs)
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
    nonisolated static func mergeICS(current: [MeetingEvent], results: [FetchResult], live: [CalendarSubscription], previousErrors: [UUID: String], previousWarnings: [UUID: String] = [:], latestRequestIDs: [UUID: Int] = [:], invalidatedCalendarIDs: Set<UUID> = []) -> (events: [MeetingEvent], errors: [UUID: String], warnings: [UUID: String], allSucceeded: Bool, observedCalendarIDs: Set<UUID>) {
        let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        let colorByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0.colorHex.isEmpty ? Palette.hex(for: $0.colorIndex) : $0.colorHex) })
        // Muted flags come from the LIVE rules — a fetch that started before a
        // rule edit must land with the new flags applied, exactly like colors.
        let matchers = TitleFilterMatcher.byCalendar(subscriptions: live)
        var events = current.compactMap { event -> MeetingEvent? in
            guard !invalidatedCalendarIDs.contains(event.calendarID),
                  let subscription = liveByID[event.calendarID], subscription.isEnabled else { return nil }
            var copy = event
            if let hex = colorByID[event.calendarID] { copy.colorHex = hex }
            copy.isMuted = matchers[event.calendarID]?.matches(title: event.title) ?? false
            return copy
        }
        let enabledIDs = Set(live.filter(\.isEnabled).map(\.id))
        var errors = previousErrors.filter { enabledIDs.contains($0.key) && !invalidatedCalendarIDs.contains($0.key) }
        var warnings = previousWarnings.filter { enabledIDs.contains($0.key) && !invalidatedCalendarIDs.contains($0.key) }
        var allSucceeded = true
        var observedCalendarIDs: Set<UUID> = []
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
            observedCalendarIDs.insert(subscription.id)
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
        return (events, errors, warnings, allSucceeded, observedCalendarIDs)
    }


    /// Snoozes each id to its own re-alert time. Duration snoozes share one
    /// fire date; a "just in time" snooze maps each event to its own start.
    func snooze(_ plan: [String: Date]) {
        for (id, fireAt) in plan {
            guard let event = events.first(where: { $0.id == id }), !event.isMuted, fireAt < event.end else { continue }
            alerted.insert(id)
            snoozed[id] = fireAt
            reminderLedger.record(event, snooze: fireAt)
        }
        persistReminderLedger()
        let keys = Set(events.filter { plan[$0.id] != nil && snoozed[$0.id] != nil }.map(NotificationLogic.eventKey))
        notifications?.removeMeetings(containing: keys)
        notifications?.reconcile()
    }

    func pause(for seconds: TimeInterval) {
        pausedUntil = now().addingTimeInterval(seconds)
    }

    func pauseUntilMorning() {
        pausedUntil = Self.nextMorning(after: now())
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
        setInMeetingDelivery(enabled ? .suppress : .normal)
    }

    func setInMeetingDelivery(_ mode: InMeetingDelivery) {
        let enabled = mode != .normal
        meetingEnableGeneration += 1
        let requestGeneration = meetingEnableGeneration
        meetingDetectionError = nil
        meetingRetryAt = nil

        guard enabled else {
            meetingDetectionChecking = false
            meetingRetryAttempts = 0
            settings.inMeetingDelivery = .normal
            meetingActivitySource.stop()
            return
        }
        guard MeetingActivityProbe.platformPotentiallySupported else {
            meetingDetectionAvailable = false
            meetingDetectionChecking = false
            meetingDetectionError = "Meeting detection requires macOS 14 or later."
            return
        }

        meetingDetectionChecking = true
        meetingActivity = .unknown
        meetingActivitySource.checkCapability { [weak self] result in
            guard let self, !self.shuttingDown, requestGeneration == self.meetingEnableGeneration else { return }
            self.meetingDetectionChecking = false
            switch result {
            case .success(let owners):
                self.meetingDetectionAvailable = true
                self.meetingRetryAttempts = 0
                self.settings.inMeetingDelivery = mode
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
                // A failed opt-in leaves the old choice intact. Restore/retry of
                // an existing choice must never erase persisted user intent.
                if self.settings.needsMeetingDetection, error != .processListUnavailable {
                    self.meetingRetryAttempts = min(self.meetingRetryAttempts + 1, 7)
                    let delay = min(300.0, 5.0 * pow(2.0, Double(self.meetingRetryAttempts - 1)))
                    self.meetingRetryAt = self.now().addingTimeInterval(delay)
                }
                self.meetingDetectionError = error.message + (self.meetingRetryAt == nil ? "" : " Retrying automatically.")
                self.meetingActivitySource.stop()
            }
        }
    }

    private func retryMeetingDetection(force: Bool = false) {
        guard !shuttingDown, !meetingDetectionChecking, settings.needsMeetingDetection,
              let retryAt = meetingRetryAt, force || now() >= retryAt else { return }
        setInMeetingDelivery(settings.inMeetingDelivery)
    }

    func applyNotificationSetup(_ choices: NotificationSetupChoices, owners: [MeetingAudioOwner]?) {
        var updated = settings
        updated.inMeetingDelivery = choices.duringMeetings ? .notification : (settings.inMeetingDelivery == .notification ? .normal : settings.inMeetingDelivery)
        updated.catchUpDelivery = choices.catchUp ? .notification : (settings.catchUpDelivery == .skip ? .skip : .normal)
        updated.notifyUpdates = choices.updates
        applyInitialSetup(updated, owners: owners)
    }

    func applyInitialSetup(_ draft: AppSettings, owners: [MeetingAudioOwner]?) {
        let previousMode = settings.inMeetingDelivery
        settings = SetupAssistantState.applying(draft, to: settings)
        // Unrelated guide choices must not revoke a pending capability check/retry.
        guard settings.inMeetingDelivery != previousMode else { return }
        if settings.needsMeetingDetection, owners == nil {
            setInMeetingDelivery(settings.inMeetingDelivery)
            return
        }
        meetingEnableGeneration += 1
        meetingRetryAt = nil
        meetingRetryAttempts = 0
        meetingDetectionChecking = false
        if settings.needsMeetingDetection, let owners {
            meetingDetectionAvailable = true
            meetingDetectionError = nil
            meetingActivitySource.start(includeBrowsers: settings.includeBrowserMeetings, initialOwners: owners)
        } else if !settings.needsMeetingDetection {
            meetingActivitySource.stop()
        }
    }

    func refreshMeetingActivityAfterWake() {
        retryMeetingDetection(force: true)
        beginNotificationCatchUp()
        notifications?.refreshPermission(force: true)
        meetingActivitySource.refreshAfterWake()
    }

    func refresh() {
        guard !shuttingDown else { return }
        fetchNativeEvents()
        let enabled = subscriptions.filter(\.isEnabled)
        guard !isRefreshing else {
            pendingRefresh = true
            return
        }
        let requestID = beginFullRefresh(subscriptionIDs: enabled.map(\.id))
        Task { [weak self] in
            await self?.restoreCachedEvents()
            _ = await Self.performFetch(requests: enabled.map { FetchRequest(subscription: $0, requestID: requestID) }) { [weak self] result in
                await self?.merge(results: [result])
            }
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.finishRefresh(fetched: enabled, requestID: requestID)
            }
        }
    }

    private func beginFullRefresh(subscriptionIDs: [UUID]) -> Int {
        isRefreshing = true
        let requestID = fetchTracker.beginFull(subscriptionIDs: subscriptionIDs)
        catchUpRefresh.started(requestID)
        return requestID
    }

    /// A rolling group bounds parsing work; the shared download gate also
    /// bounds overlap between full refreshes and targeted resyncs.
    nonisolated static func performFetch(requests: [FetchRequest], onResult: @escaping @Sendable (FetchResult) async -> Void = { _ in }) async -> [FetchResult] {
        await withTaskGroup(of: FetchResult.self) { group in
            var remaining = requests.makeIterator()
            for _ in 0..<maxConcurrentFeeds {
                if let request = remaining.next() {
                    group.addTask { await fetch(request) }
                }
            }
            var results: [FetchResult] = []
            for await result in group {
                results.append(result)
                await onResult(result)
                if let request = remaining.next() {
                    group.addTask { await fetch(request) }
                }
            }
            return results
        }
    }

    nonisolated private static func fetch(_ request: FetchRequest) async -> FetchResult {
        let transport = await fetchTransport(request.subscription.url)
        let (data, error) = (transport.data, transport.error)
        if let error { return FetchResult(subscription: request.subscription, events: [], error: error, requestID: request.requestID, isOffline: transport.isOffline) }
        guard let data else { return FetchResult(subscription: request.subscription, events: [], error: "Empty response", requestID: request.requestID) }
        return decodeFeed(data, request: request, now: Date())
    }

    /// Shared by network ingestion and the pure fetch-to-merge regression tests.
    nonisolated static func decodeFeed(_ data: Data, request: FetchRequest, now: Date) -> FetchResult {
        let sub = request.subscription
        guard data.count <= maxFeedBytes else {
            return FetchResult(subscription: sub, events: [], error: "Feed larger than \(maxFeedBytes / 1_000_000) MB", requestID: request.requestID)
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let parsed = ICSBuilder.meetings(fromICS: text, subscription: sub, now: now)
        let warning = parsed.warnings.isEmpty ? nil : parsed.warnings.prefix(5).joined(separator: " · ")
        return FetchResult(subscription: sub, events: parsed.events, error: parsed.error, warning: warning, requestID: request.requestID, fetchedAt: now)
    }

    /// Count decoded bytes while streaming; never retain an oversized body.
    nonisolated static let maxFeedBytes = 5 * 1_000_000
    nonisolated static let maxConcurrentFeeds = 4
    nonisolated private static let downloadSlots = CalendarDownloadSlots(limit: maxConcurrentFeeds)

    nonisolated static func fetchData(_ urlString: String) async -> (Data?, String?) {
        let result = await fetchTransport(urlString)
        return (result.data, result.error)
    }

    nonisolated private static func fetchTransport(_ urlString: String) async -> CalendarTransportResult {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return CalendarTransportResult(error: "Invalid URL")
        }
        await downloadSlots.acquire()
        let result: CalendarTransportResult
        if Task.isCancelled { result = CalendarTransportResult(error: "Calendar fetch cancelled") }
        else { result = await transportDelegate.download(from: url, session: session) }
        await downloadSlots.release()
        return result
    }

    private func finishRefresh(fetched: [CalendarSubscription], requestID: Int) {
        // Results are applied independently on arrival. Completion means checked,
        // not necessarily successful; failures remain visible in per-source errors.
        let completedAt = now()
        lastChecked = completedAt
        displayTime = completedAt
        isRefreshing = false
        completedInitialRefresh = true
        // Only the batch owned by the latest launch/wake releases catch-up.
        // An older completion may still need to start a queued replacement.
        let completesCatchUp = catchUpRefresh.finish(requestID)
        drainNotificationResponses()
        tick()
        if completesCatchUp { catchUpBoundary = [:] }
        if pendingRefresh || fetched.map(\.id) != subscriptions.filter(\.isEnabled).map(\.id) || fetched.map(\.url) != subscriptions.filter(\.isEnabled).map(\.url) {
            pendingRefresh = false
            refresh()
        }
    }

    /// Publish/reconcile every edit, but advance absence only for calendars
    /// with newly accepted source snapshots. Two independent misses retire an
    /// id; unrelated merges, re-tints and title-filter edits do not count.
    private func commitEvents(_ newEvents: [MeetingEvent], observedCalendarIDs: Set<UUID> = []) {
        let sorted = Self.normalizedEvents(newEvents)
        let enabledIDs = Set(subscriptions.filter(\.isEnabled).map(\.id) + nativeCalendars.filter(\.isEnabled).map(\.id))
        let retainedIDs = reminderSnapshots.retainedIDs(current: sorted, observedCalendarIDs: observedCalendarIDs, enabledCalendarIDs: enabledIDs)
        reminderLedger.reconcile(events: sorted, enabled: enabledIDs, observed: observedCalendarIDs, now: now())
        let persistedIDs = Set(sorted.filter { reminderLedger.entries[NotificationLogic.eventKey($0)] != nil }.map(\.id))
        let pruned = Self.prunedBookkeeping(alerted: alerted, snoozed: snoozed, retainedIDs: retainedIDs)
        // Single funnel for EVERY event-list change — rule edits, ICS refreshes
        // (a title edit keeps the same id and can flip muted→unmuted mid-window),
        // and native rebuilds all pass through here, so the unmute ratchet lives
        // here and nowhere else.
        let ratcheted = Self.ratchetSilence(previous: events, fallbackMutedByID: recentMutedByID, current: sorted, alerted: pruned.alerted, snoozed: pruned.snoozed, leadSeconds: settings.leadSeconds, now: now())
        alerted = ratcheted.alerted.union(persistedIDs)
        snoozed = ratcheted.snoozed
        for event in sorted {
            if let entry = reminderLedger.entries[NotificationLogic.eventKey(event)], !ratcheted.alerted.contains(event.id) {
                snoozed[event.id] = entry.snooze
            }
            if alerted.contains(event.id) { reminderLedger.record(event, snooze: snoozed[event.id]) }
            if let boundary = catchUpBoundary[event.calendarID], event.start <= boundary, event.end > now() { catchUpIDs.insert(event.id) }
        }
        catchUpIDs.formIntersection(retainedIDs)
        persistReminderLedger()
        recentMutedByID = Self.retainedMutedStates(previous: recentMutedByID, current: sorted, retainedIDs: retainedIDs)
        events = sorted
        notificationEventsByKey = [:]
        notificationFingerprints = [:]
        let legacyCounts = Dictionary(grouping: sorted, by: \.legacyID).mapValues(\.count)
        ambiguousLegacyNotificationIDs.formUnion(legacyCounts.filter { $0.value > 1 }.keys)
        for event in sorted {
            let key = NotificationLogic.eventKey(event)
            notificationEventsByKey[key] = event
            notificationEventsByKey[NotificationLogic.key(event.id)] = event
            if legacyCounts[event.legacyID] == 1 && !ambiguousLegacyNotificationIDs.contains(event.legacyID) {
                notificationEventsByKey[NotificationLogic.key(event.legacyID)] = event
            }
            notificationFingerprints[key] = NotificationLogic.fingerprint(event)
        }
        // Keep an open alert in sync: cancelled/removed/disabled events drop
        // off the cards, changed events update in place.
        alertController?.reconcile(withCurrent: sorted)
        if cacheLoaded { notifications?.reconcile() }
        if completedInitialRefresh {
            let failed = syncFailureIDs
            syncNotificationTracker.firstFailure = syncNotificationTracker.firstFailure.filter { failed.contains($0.key) }
            syncNotificationTracker.notified.formIntersection(failed)
            persistSyncNotificationTracker()
        }
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

    /// Keep muted state for the same source-scoped lifetime as alert/snooze state.
    nonisolated static func retainedMutedStates(previous: [String: Bool], current: [MeetingEvent], retainedIDs: Set<String>) -> [String: Bool] {
        var retained = previous.filter { retainedIDs.contains($0.key) }
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

    nonisolated static func prunedBookkeeping(alerted: Set<String>, snoozed: [String: Date], retainedIDs: Set<String>) -> (alerted: Set<String>, snoozed: [String: Date]) {
        (alerted.intersection(retainedIDs), snoozed.filter { retainedIDs.contains($0.key) })
    }

    nonisolated static func changedSubscriptionURLs(previous: [CalendarSubscription], current: [CalendarSubscription]) -> Set<UUID> {
        let oldURLs = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0.url) })
        return Set(current.filter { subscription in
            guard let oldURL = oldURLs[subscription.id] else { return false }
            return oldURL != subscription.url
        }.map(\.id))
    }

    private func reconcileEvents(invalidatedCalendarIDs: Set<UUID> = []) {
        let native = events.filter { knownNativeCalendarIDs.contains($0.calendarID) }
        let reconciled = Self.mergeICS(
            current: currentICSEvents, results: [], live: subscriptions,
            previousErrors: errors, previousWarnings: warnings,
            invalidatedCalendarIDs: invalidatedCalendarIDs)
        errors = reconciled.errors
        warnings = reconciled.warnings
        // A replacement source must not inherit snoozes or suppression history,
        // including bookkeeping for meetings absent from the last snapshot.
        reminderSnapshots.invalidate(calendarIDs: invalidatedCalendarIDs)
        reminderLedger.invalidate(invalidatedCalendarIDs)
        commitEvents(reconciled.events + native)
    }

    private func tick() {
        guard cacheLoaded, !shuttingDown else { return }
        retryMeetingDetection()
        let now = self.now()
        displayTime = now
        if let until = pausedUntil, now >= until { pausedUntil = nil }
        if let alerts = alertController, alerts.isOpen {
            if alerts.shownEvents.allSatisfy({ now.timeIntervalSince($0.end) > 120 }) {
                alerts.close()
            }
        }
        notifications?.refreshPermission(now: now)
        notifications?.reconcile()
        notifySyncProblems(at: now)
        updateNotificationTick?()
        if isPaused { return }
        let due = Self.dueForAlert(events: events, alerted: alerted, snoozed: snoozed, leadSeconds: settings.leadSeconds, now: now)
        var fullscreen: [MeetingEvent] = []
        var ordinary: [MeetingEvent] = []
        var catchUp: [MeetingEvent] = []
        for event in due {
            switch notificationRoute(event, at: now) {
            case .handled: acknowledge([event])
            case .deferReminder: break
            case .fullscreen: fullscreen.append(event)
            case .notification: ordinary.append(event)
            case .catchUp:
                if !isRefreshing && !catchUpRefresh.pending { catchUp.append(event) }
            }
        }
        for group in NotificationLogic.sameStartGroups(ordinary) {
            offerNotification(group, catchUp: false, at: now)
        }
        if !catchUp.isEmpty { offerNotification(catchUp, catchUp: true, at: now) }
        if !fullscreen.isEmpty {
            acknowledge(fullscreen)
            onAlert?(fullscreen)
        }
    }

    func beginNotificationCatchUp() {
        catchUpRefresh.begin()
        let boundary = now()
        catchUpBoundary = Dictionary(uniqueKeysWithValues:
            (subscriptions.filter(\.isEnabled).map(\.id) + nativeCalendars.filter(\.isEnabled).map(\.id)).map { ($0, boundary) })
        for event in events where event.start <= boundary && event.end > boundary { catchUpIDs.insert(event.id) }
    }

    private func notificationRoute(_ event: MeetingEvent, at date: Date) -> ReminderRoute {
        NotificationLogic.route(event: event, settings: settings, activity: meetingActivity,
                                catchUp: catchUpIDs.contains(event.id), snoozed: snoozed[event.id] != nil, now: date)
    }

    func connectNotifications(_ controller: ReminderNotificationController) {
        notifications = controller
        controller.onMeetingPreview = { [weak self] in self?.alertController?.cancelPreview() }
        controller.validate = { [weak self] item in self?.validNotification(item) ?? false }
        controller.reconcileDelivered = { [weak self] item in self?.reconcileDeliveredNotification(item) ?? .remove }
        controller.deferRestoredReconciliation = { [weak self] in self.map { !$0.completedInitialRefresh } ?? false }
        controller.onSubmitted = { [weak self] item in
            guard let self else { return }
            if item.updateVersion != nil { self.updateNotificationSubmitted?(item); return }
            if item.sync {
                self.syncNotificationTracker.notified.formUnion(item.keys.compactMap(UUID.init(uuidString:)))
                self.persistSyncNotificationTracker()
            }
            else if !item.test { self.acknowledge(self.eventsForNotification(item)) }
        }
        controller.onResponse = { [weak self] item, action in
            guard let self else { return }
            if item.updateVersion != nil { self.updateNotificationResponse?(item, action); return }
            if !self.cacheLoaded || (!self.completedInitialRefresh && (self.started || self.isRefreshing)) {
                self.pendingNotificationResponses.append((item, action))
            } else { self.handleNotificationResponse(item, action: action) }
        }
    }

    private func eventsForNotification(_ item: ReminderNotification) -> [MeetingEvent] {
        var seen = Set<String>()
        return item.keys.compactMap { notificationEventsByKey[$0] }.filter {
            seen.insert($0.id).inserted && !$0.isMuted && $0.end > now()
        }
    }

    /// Validate an in-flight submission against live content, never against the
    /// bookkeeping mutation that accepting that submission will perform.
    private func validNotification(_ item: ReminderNotification) -> Bool {
        if item.updateVersion != nil { return validateUpdateNotification?(item) ?? false }
        if item.test { return true }
        if item.sync { return validSyncKeys(item).count == item.keys.count && settings.notifySyncErrors }
        guard !isPaused else { return false }
        let current = eventsForNotification(item)
        let expected = Set(item.visibleKeys ?? item.keys)
        guard Set(current.map(NotificationLogic.eventKey)) == expected else { return false }
        let fingerprints = Dictionary(uniqueKeysWithValues: zip(item.keys, item.fingerprints))
        return current.allSatisfy { event in
            let route = notificationRoute(event, at: now())
            return fingerprints[NotificationLogic.eventKey(event)] == NotificationLogic.fingerprint(event)
                && (item.replacementReason != nil || route == .notification || route == .catchUp)
                && (snoozed[event.id] == nil || snoozed[event.id]! <= now())
        }
    }

    private func validSyncKeys(_ item: ReminderNotification) -> Set<String> {
        guard completedInitialRefresh else { return Set(item.keys) }
        return Set(zip(item.keys, item.fingerprints).compactMap { key, fingerprint in
            guard let id = UUID(uuidString: key), syncFailureIDs.contains(id),
                  let first = syncNotificationTracker.firstFailure[id],
                  String(first.timeIntervalSince1970) == fingerprint else { return nil }
            return key
        })
    }

    /// Accepted notifications have their own lifecycle. Merely acknowledging a
    /// snooze or changing detected activity must not retract what we just sent.
    private func reconcileDeliveredNotification(_ original: ReminderNotification) -> NotificationReconciliation {
        if original.updateVersion != nil || original.test {
            return original.expires > now() && (original.test || (validateUpdateNotification?(original) ?? false)) ? .keep(original) : .remove
        }
        if original.sync {
            return settings.notifySyncErrors && !validSyncKeys(original).isEmpty ? .keep(original) : .remove
        }
        guard !isPaused else { return .remove }
        let enabled = Set(subscriptions.filter(\.isEnabled).map(\.id) + nativeCalendars.filter(\.isEnabled).map(\.id))
        var item = original
        var keys: [String] = [], fingerprints: [String] = [], current: [MeetingEvent] = []
        var seenKeys = Set<String>()
        var priorVisible = Set(original.visibleKeys ?? original.keys)
        var expiration = Date.distantPast
        var changed = false
        for (oldKey, fingerprint) in zip(original.keys, original.fingerprints) {
            if let event = notificationEventsByKey[oldKey] {
                guard enabled.contains(event.calendarID), !event.isMuted, event.end > now(), snoozed[event.id] == nil else { continue }
                let key = NotificationLogic.eventKey(event)
                guard seenKeys.insert(key).inserted else { continue }
                if priorVisible.remove(oldKey) != nil { priorVisible.insert(key) }
                keys.append(key)
                // Migrate fingerprint format without claiming a meeting changed.
                let same = fingerprint == notificationFingerprints[key]
                    || fingerprint == NotificationLogic.priorAgendaFingerprint(event)
                    || (original.fingerprintVersion == nil && fingerprint == NotificationLogic.legacyFingerprint(event))
                fingerprints.append(same ? notificationFingerprints[key]! : fingerprint)
                changed = changed || !same
                current.append(event)
                expiration = max(expiration, event.end)
            } else if let entry = reminderLedger.entries[oldKey], enabled.contains(entry.calendarID), entry.end > now() {
                // One source omission hides the notice but preserves restoration
                // intent. Two successful omissions retire the ledger entry.
                keys.append(oldKey); fingerprints.append(fingerprint)
                expiration = max(expiration, entry.end)
            }
        }
        guard !keys.isEmpty else { return .remove }
        item.keys = keys; item.fingerprints = fingerprints; item.expires = expiration
        item.fingerprintVersion = 2
        let visible = current.map(NotificationLogic.eventKey)
        item.visibleKeys = visible
        guard !current.isEmpty else {
            item.hidden = true
            item.replacementReason = "Meeting reminder restored"
            return .hide(item)
        }
        let restored = !Set(visible).isSubset(of: priorVisible)
        if changed || restored || original.hidden == true {
            let reason = restored ? "Meeting reminder restored" : (changed ? "Meeting updated" : (original.replacementReason ?? "Meeting reminder restored"))
            // Coalesce the full batch into one visible replacement.
            if isRefreshing {
                item.hidden = true; item.replacementReason = reason
                return .hide(item)
            }
            var replacement = meetingNotification(current, catchUp: item.catchUp, at: now(), reason: reason)
            // Preserve missing members so their later return can restore them too.
            let latest = Dictionary(uniqueKeysWithValues: zip(replacement.keys, replacement.fingerprints))
            replacement.keys = keys
            replacement.fingerprints = zip(keys, fingerprints).map { latest[$0.0] ?? $0.1 }
            replacement.visibleKeys = visible
            replacement.expires = expiration
            return .replace(replacement)
        }
        // Membership-only changes use the approved fallback: keep the existing
        // banner without another interruption; actions always resolve live data.
        return .keep(item)
    }

    private func meetingNotification(_ incoming: [MeetingEvent], catchUp: Bool, at date: Date, reason: String? = nil) -> ReminderNotification {
        let sorted = incoming.sorted { $0.id < $1.id }
        let keys = sorted.map(NotificationLogic.eventKey)
        let text = NotificationLogic.content(events: sorted, privateDetails: settings.hideNotificationDetails, catchUp: catchUp, now: date)
        let options = AlertController.snoozeOptions(events: sorted, now: date, customSeconds: settings.snoozeSeconds)
        let canSnooze = AlertController.primarySnoozePlan(options: options, defaultSeconds: settings.snoozeSeconds) != nil
        return ReminderNotification(id: "now.meeting." + NotificationLogic.key(keys.joined()), keys: keys,
            fingerprints: sorted.map(NotificationLogic.fingerprint), expires: sorted.map(\.end).max()!, catchUp: catchUp,
            title: reason ?? text.title, body: reason == nil ? text.body : text.title + "\n" + text.body,
            category: !catchUp && sorted.count > 1 ? SystemNotificationTransport.chooseMeetingCategory
                : SystemNotificationTransport.category(join: sorted.count == 1 && sorted[0].link != nil, snooze: canSnooze),
            sound: reason == nil && settings.soundEnabled && !(settings.notifyDuringMeetings && meetingActivity.isDetectedMeeting),
            visibleKeys: keys, replacementReason: reason, fingerprintVersion: 2)
    }

    private func offerNotification(_ incoming: [MeetingEvent], catchUp: Bool, at date: Date) {
        notifications?.offer(meetingNotification(incoming, catchUp: catchUp, at: date), now: date)
    }

    /// Persist an explicit acknowledgement or accepted reminder delivery.
    func acknowledge(_ handled: [MeetingEvent]) {
        for event in handled {
            alerted.insert(event.id)
            snoozed.removeValue(forKey: event.id)
            reminderLedger.record(event)
        }
        persistReminderLedger()
    }

    func joinedMeeting(_ event: MeetingEvent) {
        guard let current = events.first(where: { $0.id == event.id }),
              Self.joinHandlesReminder(current, leadSeconds: settings.leadSeconds, now: now()) else { return }
        acknowledge([current])
        notifications?.removeMeetings(containing: [NotificationLogic.eventKey(current), NotificationLogic.key(current.id), NotificationLogic.key(current.legacyID)])
    }

    nonisolated static func joinHandlesReminder(_ event: MeetingEvent, leadSeconds: Int, now: Date) -> Bool {
        now >= event.start.addingTimeInterval(-TimeInterval(leadSeconds)) && now < event.end
    }

    private func persistReminderLedger() {
        if let data = try? JSONEncoder().encode(reminderLedger), data != UserDefaults.standard.data(forKey: ledgerKey) {
            UserDefaults.standard.set(data, forKey: ledgerKey)
        }
    }

    private func drainNotificationResponses() {
        let pending = pendingNotificationResponses
        pendingNotificationResponses = []
        for (item, action) in pending { handleNotificationResponse(item, action: action) }
    }

    private func handleNotificationResponse(_ item: ReminderNotification, action: String) {
        guard !item.test else { return }
        if item.sync { if action != UNNotificationDismissActionIdentifier { openNotificationSyncSettings?() }; return }
        let current = eventsForNotification(item)
        guard !current.isEmpty else {
            if action != UNNotificationDismissActionIdentifier { openNotificationAgenda?() }
            return
        }
        if action == "snooze" {
            let options = AlertController.snoozeOptions(events: current, now: now(), customSeconds: settings.snoozeSeconds)
            if let plan = AlertController.primarySnoozePlan(options: options, defaultSeconds: settings.snoozeSeconds),
               let schedule = AlertController.snoozeSchedule(plan: plan, events: current, now: now()) {
                snooze(schedule)
            } else { acknowledge(current); openNotificationMeetings?(current) }
        } else {
            acknowledge(current)
            notifications?.removeMeetings(containing: Set(current.map(NotificationLogic.eventKey)))
            if action == "choose" || (!item.catchUp && item.keys.count > 1 && action != UNNotificationDismissActionIdentifier) { openNotificationAgenda?() }
            else if action == "join", current.count == 1, let url = current[0].link { openNotificationLink(url) }
            else if action != UNNotificationDismissActionIdentifier { openNotificationMeetings?(current) }
        }
    }

    private var syncFailureIDs: Set<UUID> {
        var ids = Set(errors.keys)
        if !nativeSource.isAuthorized { ids.formUnion(nativeCalendars.filter(\.isEnabled).map(\.id)) }
        return ids
    }

    private func notifySyncProblems(at date: Date) {
        guard settings.notifySyncErrors else {
            syncNotificationTracker = SyncNotificationTracker(); persistSyncNotificationTracker(); return
        }
        guard completedInitialRefresh else { return }
        let candidates = syncNotificationTracker.candidates(failed: syncFailureIDs, now: date)
        persistSyncNotificationTracker()
        guard !candidates.isEmpty else { return }
        let failures = candidates.sorted { $0.uuidString < $1.uuidString }.compactMap { id -> (String, String)? in
            guard let first = syncNotificationTracker.firstFailure[id] else { return nil }
            return (id.uuidString, String(first.timeIntervalSince1970))
        }
        let keys = failures.map { $0.0 }
        guard !keys.isEmpty else { return }
        notifications?.offer(ReminderNotification(id: "now.sync." + NotificationLogic.key(keys.joined()), keys: keys, fingerprints: failures.map { $0.1 },
            expires: date.addingTimeInterval(86400), catchUp: false, sync: true,
            title: "Calendar sync needs attention", body: "\(keys.count) calendar\(keys.count == 1 ? " has" : "s have") been unavailable for at least 5 minutes. Open now for details.",
            category: SystemNotificationTransport.category(join: false, snooze: false), sound: false), now: date)
    }

    private func persistSyncNotificationTracker() {
        if let data = try? JSONEncoder().encode(syncNotificationTracker), data != UserDefaults.standard.data(forKey: syncLedgerKey) {
            UserDefaults.standard.set(data, forKey: syncLedgerKey)
        }
    }

    var notificationProblemTitle: String? {
        guard settings.usesNotifications, let notifications else { return nil }
        if let problem = notifications.problem { return problem }
        if notifications.permission.authorization == .denied { return "Notifications disabled in macOS · Settings…" }
        if notifications.permission.authorization == .notRequested { return "Notification permission needed · Settings…" }
        if notifications.permission.authorization == .allowed && !notifications.permission.alerts { return "Notification banners disabled · Settings…" }
        return nil
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
        if let previous = previousNotificationSettings, previous != settings {
            previousNotificationSettings = settings
            if previous.hideNotificationDetails != settings.hideNotificationDetails
                || previous.reminderDelivery != settings.reminderDelivery
                || previous.inMeetingDelivery != settings.inMeetingDelivery
                || previous.catchUpDelivery != settings.catchUpDelivery {
                // Remove already delivered content immediately when privacy changes.
                for item in notifications?.receipts.values.map({ $0 }) ?? [] where !item.test && !item.sync && item.updateVersion == nil { notifications?.discard(item.id) }
            }
            notifications?.reconcile()
        }
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
            if settings.needsMeetingDetection {
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
final class CalendarTransportDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var downloads: [Int: CalendarDownload] = [:]

    func download(from url: URL, session: URLSession) async -> CalendarTransportResult {
        let download = CalendarDownload()
        let task = session.dataTask(with: url)
        register(download, for: task)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                download.install(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func register(_ download: CalendarDownload, for task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        downloads[task.taskIdentifier] = download
    }

    private func download(for task: URLSessionTask, removing: Bool = false) -> CalendarDownload? {
        lock.lock(); defer { lock.unlock() }
        return removing ? downloads.removeValue(forKey: task.taskIdentifier) : downloads[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let download = download(for: dataTask) else { completionHandler(.allow); return }
        let error: String?
        if let http = response as? HTTPURLResponse {
            if !(200...299).contains(http.statusCode) { error = "Server returned \(http.statusCode)" }
            else if response.expectedContentLength > AppStore.maxFeedBytes { error = CalendarDownload.sizeError }
            else { error = nil }
        } else { error = "Non-HTTP response" }
        if let error {
            download.complete(error: error)
            completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let download = download(for: dataTask) else { return }
        if !download.append(data) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        download(for: task, removing: true)?.complete(error: error?.localizedDescription, isOffline: CalendarTransportResult.isOffline(error))
    }

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

/// A single bounded response. URLSession delivers decoded chunks; no completion-
/// handler data task buffers the whole body first. The lock covers cancellation
/// completing before the async continuation has been installed.
private final class CalendarDownload: @unchecked Sendable {
    static let sizeError = "Feed larger than \(AppStore.maxFeedBytes / 1_000_000) MB"
    private let lock = NSLock()
    private var data = Data()
    private var outcome: CalendarTransportResult?
    private var continuation: CheckedContinuation<CalendarTransportResult, Never>?

    func install(_ continuation: CheckedContinuation<CalendarTransportResult, Never>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(returning: outcome)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func append(_ chunk: Data) -> Bool {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return false }
        guard chunk.count <= AppStore.maxFeedBytes - data.count else {
            lock.unlock()
            complete(error: Self.sizeError)
            return false
        }
        data.append(chunk)
        lock.unlock()
        return true
    }

    func complete(error: String?, isOffline: Bool = false) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        let result = CalendarTransportResult(data: error == nil ? data : nil, error: error, isOffline: isOffline)
        outcome = result
        data = Data()
        let callback = continuation
        continuation = nil
        lock.unlock()
        callback?.resume(returning: result)
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
    var fetchedAt: Date?
    var isOffline = false

    init(subscription: CalendarSubscription, events: [MeetingEvent], error: String?, warning: String? = nil, requestID: Int = 0, fetchedAt: Date? = nil, isOffline: Bool = false) {
        self.subscription = subscription
        self.events = events
        self.error = error
        self.warning = warning
        self.requestID = requestID
        self.fetchedAt = fetchedAt
        self.isOffline = isOffline
    }
}

/// Global across full and targeted refreshes, even when their hosts differ.
/// Waiters do not start URLSession tasks or retain response bodies.
private actor CalendarDownloadSlots {
    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().resume() }
    }
}

/// Pure source-snapshot bookkeeping, shared by real commits and orchestration
/// tests. Owners remain known while absent so another source cannot age them.
struct ReminderSnapshotTracker {
    private var calendarByID: [String: UUID] = [:]
    private var missingOnce: Set<String> = []

    mutating func invalidate(calendarIDs: Set<UUID>) {
        calendarByID = calendarByID.filter { !calendarIDs.contains($0.value) }
        missingOnce.formIntersection(Set(calendarByID.keys))
    }

    mutating func retainedIDs(current: [MeetingEvent], observedCalendarIDs: Set<UUID>, enabledCalendarIDs: Set<UUID>) -> Set<String> {
        let active = Set(current.map(\.id))
        calendarByID = calendarByID.filter { enabledCalendarIDs.contains($0.value) }
        for (id, calendarID) in calendarByID where observedCalendarIDs.contains(calendarID) && !active.contains(id) {
            if missingOnce.contains(id) { calendarByID.removeValue(forKey: id) }
            else { missingOnce.insert(id) }
        }
        for event in current where enabledCalendarIDs.contains(event.calendarID) {
            calendarByID[event.id] = event.calendarID
            missingOnce.remove(event.id)
        }
        let retained = Set(calendarByID.keys)
        missingOnce.formIntersection(retained)
        return retained
    }
}
