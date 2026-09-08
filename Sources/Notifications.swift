import Foundation
import AppKit
import UserNotifications
import CryptoKit

/// Pure routing; permission never changes a discreet request into fullscreen.
enum ReminderRoute: Equatable { case fullscreen, notification, catchUp, deferReminder, handled }
enum NotificationLogic {
    static func key(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func route(event: MeetingEvent, settings: AppSettings, activity: MeetingActivity,
                      catchUp: Bool, snoozed: Bool, now: Date) -> ReminderRoute {
        if case .meeting = activity {
            switch settings.inMeetingDelivery {
            case .suppress: return now >= event.start ? .handled : .deferReminder
            case .notification: return .notification
            case .normal: break
            }
        }
        if catchUp && !snoozed {
            switch settings.catchUpDelivery {
            case .normal: break
            case .notification: return .catchUp
            case .skip: return .handled
            }
        }
        return settings.reminderDelivery == .notification ? .notification : .fullscreen
    }

    static func content(events: [MeetingEvent], privateDetails: Bool, catchUp: Bool, now: Date) -> (title: String, body: String) {
        if events.count != 1 {
            return ("\(events.count) meetings are in progress", "Open now to view your agenda.")
        }
        guard let event = events.first else { return ("Meeting reminder", "Open now to view your agenda.") }
        let started = event.start <= now
        let title = privateDetails ? (started ? "A meeting is in progress" : "A meeting is starting")
            : String((event.title.isEmpty ? "Untitled meeting" : event.title).prefix(180))
        let body = started ? "Started at \(Fmt.time.string(from: event.start)) · ends at \(Fmt.time.string(from: event.end))"
            : "Starts at \(Fmt.time.string(from: event.start)) · \(Fmt.leadTime(max(1, Int(event.start.timeIntervalSince(now))))) from now"
        return (title, body)
    }

    static func fingerprint(_ event: MeetingEvent) -> String {
        key([event.id, event.title, String(event.end.timeIntervalSince1970), event.link?.absoluteString ?? "", String(event.isMuted)].joined(separator: "\n"))
    }
}

/// Only a full batch started for the current launch/wake can finish catch-up.
/// Targeted generations never participate; a repeated wake revokes the old owner.
struct CatchUpRefreshTracker {
    private(set) var pending = false
    private var owner: Int?
    mutating func begin() { pending = true; owner = nil }
    mutating func started(_ requestID: Int) { if pending { owner = requestID } }
    mutating func finish(_ requestID: Int) -> Bool {
        guard pending, owner == requestID else { return false }
        pending = false
        owner = nil
        return true
    }
}

/// No titles, feed URLs, notes, or join links are stored in acknowledgement data.
/// Keep absent records until expiry (or two successful source omissions), including
/// while asynchronously restoring another calendar on launch.
struct ReminderLedger: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var calendarID: UUID
        var end: Date
        var snooze: Date?
        var misses = 0
    }
    var entries: [String: Entry] = [:]
    mutating func record(_ event: MeetingEvent, snooze: Date? = nil) {
        entries[NotificationLogic.key(event.id)] = Entry(calendarID: event.calendarID, end: event.end, snooze: snooze)
    }
    mutating func reconcile(events: [MeetingEvent], enabled: Set<UUID>, observed: Set<UUID>, now: Date) {
        let live = Dictionary(uniqueKeysWithValues: events.map { (NotificationLogic.key($0.id), $0) })
        for (key, var entry) in entries {
            guard enabled.contains(entry.calendarID), entry.end > now else { entries.removeValue(forKey: key); continue }
            if let event = live[key] { entry.end = event.end; entry.misses = 0 }
            else if observed.contains(entry.calendarID) { entry.misses += 1 }
            if entry.misses >= 2 { entries.removeValue(forKey: key) }
            else { entries[key] = entry }
        }
        if entries.count > 20_000 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.end > $1.value.end }.prefix(20_000).map { ($0.key, $0.value) })
        }
    }
    mutating func invalidate(_ calendars: Set<UUID>) { entries = entries.filter { !calendars.contains($0.value.calendarID) } }
}

/// One notification per continuous failure episode, after five minutes. Successful
/// sources reset independently; unrelated successes cannot re-arm failing sources.
struct SyncNotificationTracker: Codable {
    var firstFailure: [UUID: Date] = [:]
    var notified: Set<UUID> = []
    mutating func candidates(failed: Set<UUID>, now: Date) -> Set<UUID> {
        firstFailure = firstFailure.filter { failed.contains($0.key) }
        notified.formIntersection(failed)
        for id in failed where firstFailure[id] == nil { firstFailure[id] = now }
        return Set(failed.filter { !notified.contains($0) && now.timeIntervalSince(firstFailure[$0]!) >= 300 })
    }
}

struct NotificationPermission: Equatable {
    enum Authorization { case unknown, notRequested, allowed, denied }
    var authorization: Authorization = .unknown
    var alerts = false
    var sound = false
    var canSubmit: Bool { authorization == .allowed }
    var message: String {
        switch authorization {
        case .unknown: return "Checking notification permission…"
        case .notRequested: return "Notification permission has not been requested."
        case .denied: return "Notifications are disabled in macOS. Reminders using notifications cannot be delivered."
        case .allowed: return alerts ? "Notifications are allowed. Focus and macOS settings can still silence them."
            : "Onscreen alerts are disabled. Reminders may appear only in Notification Center."
        }
    }
}

struct ReminderNotification: Codable, Equatable {
    var id: String
    var keys: [String]
    var fingerprints: [String]
    var expires: Date
    var catchUp: Bool
    var sync: Bool = false
    var test: Bool = false
    var updateVersion: String? = nil
    var title: String
    var body: String
    var category: String
    var sound: Bool
}

@MainActor
protocol NotificationTransport: AnyObject {
    func permission() async -> NotificationPermission
    func requestPermission() async throws
    func add(_ notification: ReminderNotification) async throws
    func remove(_ ids: [String])
}

@MainActor
final class SystemNotificationTransport: NSObject, NotificationTransport, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var response: ((String, String) -> Void)?
    override init() {
        super.init()
        center.delegate = self
        var categories: Set<UNNotificationCategory> = []
        for join in [false, true] {
            for snooze in [false, true] {
                var actions: [UNNotificationAction] = []
                if join { actions.append(UNNotificationAction(identifier: "join", title: "Join", options: [.foreground])) }
                if snooze { actions.append(UNNotificationAction(identifier: "snooze", title: "Snooze", options: [])) }
                categories.insert(UNNotificationCategory(identifier: Self.category(join: join, snooze: snooze), actions: actions, intentIdentifiers: [], options: [.customDismissAction]))
            }
        }
        center.setNotificationCategories(categories)
    }
    nonisolated static func category(join: Bool, snooze: Bool) -> String { "now.meeting.\(join).\(snooze)" }
    func permission() async -> NotificationPermission {
        let value = await center.notificationSettings()
        let authorization: NotificationPermission.Authorization
        switch value.authorizationStatus {
        case .notDetermined: authorization = .notRequested
        case .denied: authorization = .denied
        case .authorized, .provisional, .ephemeral: authorization = .allowed
        @unknown default: authorization = .unknown
        }
        return NotificationPermission(authorization: authorization, alerts: value.alertSetting == .enabled && value.alertStyle != .none, sound: value.soundSetting == .enabled)
    }
    func requestPermission() async throws { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
    func add(_ notification: ReminderNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.categoryIdentifier = notification.category
        content.threadIdentifier = notification.updateVersion != nil ? "now.updates" : (notification.sync ? "now.sync" : "now.meetings")
        // Payloads contain only an opaque request token; actions resolve live data.
        content.userInfo = ["nowRequest": notification.id]
        if notification.sound { content.sound = .default }
        try await center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }
    func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                             withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                             withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            self?.response?(id, action)
            completionHandler()
        }
    }
}

/// Main-actor owner of reservations, async submission, stale-result cleanup, and
/// permission status. Transport injection keeps tests out of Notification Center.
@MainActor
final class ReminderNotificationController: ObservableObject {
    @Published private(set) var permission = NotificationPermission()
    @Published private(set) var requesting = false
    @Published private(set) var problem: String?
    private let transport: NotificationTransport
    private let defaults: UserDefaults
    private let storageKey = "local.tboch.now.notification-receipts.v1"
    private(set) var receipts: [String: ReminderNotification] = [:]
    private var pending: Set<String> = []
    private var retryAfter: [String: Date] = [:]
    var now: () -> Date = { Date() }
    private var refreshing = false
    private var lastPermissionCheck = Date.distantPast
    private var permissionRevision = 0
    var validate: ((ReminderNotification) -> Bool)?
    var onSubmitted: ((ReminderNotification) -> Void)?
    var onResponse: ((ReminderNotification, String) -> Void)?
    var onMeetingPreview: (() -> Void)?

    init(transport: NotificationTransport, defaults: UserDefaults = .standard) {
        self.transport = transport
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey), data.count <= 8_000_000,
           let saved = try? JSONDecoder().decode([String: ReminderNotification].self, from: data) {
            receipts = saved.filter { id, item in
                id == item.id && id.hasPrefix("now.") && item.keys.count <= 20_000
                    && Set(item.keys).count == item.keys.count
                    && (item.sync || item.test || item.updateVersion != nil || item.fingerprints.count == item.keys.count)
            }
        }
    }
    func refreshPermission(force: Bool = false, now: Date = Date()) {
        guard !refreshing, force || now.timeIntervalSince(lastPermissionCheck) >= 30 else { return }
        refreshing = true
        let revision = permissionRevision
        Task {
            let next = await transport.permission()
            refreshing = false
            lastPermissionCheck = now
            guard revision == permissionRevision else { return }
            if next != permission { permission = next; retryAfter = [:] }
        }
    }
    func checkPermission() async -> NotificationPermission {
        permissionRevision += 1
        let revision = permissionRevision
        let value = await transport.permission()
        if revision == permissionRevision {
            permission = value
            retryAfter = [:]
        }
        return value
    }

    func requestPermission() {
        Task { _ = await authorizeForSetup() }
    }

    /// Only a user action calls this. A denied grant must be changed in macOS.
    func authorizeForSetup() async -> Bool {
        guard !requesting else { return false }
        requesting = true
        permissionRevision += 1
        defer { requesting = false }
        let current = await transport.permission()
        if current.authorization == .notRequested {
            do { try await transport.requestPermission(); problem = nil }
            catch { problem = "Could not request notification permission. Open Notification Settings to check access." }
        }
        permission = await transport.permission()
        retryAfter = [:]
        return permission.canSubmit
    }
    func offer(_ proposed: ReminderNotification, now: Date) {
        let retryKey = proposed.id
        guard !receipts.values.contains(where: { !$0.keys.isEmpty && !Set($0.keys).isDisjoint(with: proposed.keys) }),
              !receipts.values.contains(where: { proposed.test && $0.test }), now >= retryAfter[retryKey, default: .distantPast] else { return }
        var item = proposed
        // Every attempt owns a unique token. A cancelled add completing later
        // must never remove a replacement request for the same occurrence.
        item.id += "." + UUID().uuidString
        receipts[item.id] = item
        pending.insert(item.id)
        let revision = permissionRevision
        Task {
            let status = await transport.permission()
            if revision == permissionRevision { permission = status }
            guard receipts[item.id] == item, item.expires > self.now(), validate?(item) ?? true else {
                discard(item.id); return
            }
            guard status.canSubmit else {
                retryAfter[retryKey] = now.addingTimeInterval(30)
                discard(item.id); return
            }
            // Save the opaque action receipt before submission: actions can arrive
            // immediately, or after a crash/relaunch. Text is stripped on disk.
            persist()
            do {
                try await transport.add(item)
                guard receipts[item.id] == item, item.expires > self.now(), validate?(item) ?? true else {
                    discard(item.id); return
                }
                pending.remove(item.id)
                problem = nil
                retryAfter.removeValue(forKey: retryKey)
                onSubmitted?(item)
                persist()
            } catch {
                guard receipts[item.id] == item else { transport.remove([item.id]); return }
                problem = "macOS could not accept a notification. Check Notification Settings or try the test again."
                retryAfter[retryKey] = now.addingTimeInterval(60)
                discard(item.id)
            }
        }
    }
    func removeMeetings(containing keys: Set<String>) {
        for item in Array(receipts.values) where !item.sync && !Set(item.keys).isDisjoint(with: keys) { discard(item.id) }
    }
    func discard(_ id: String) {
        receipts.removeValue(forKey: id)
        pending.remove(id)
        transport.remove([id])
        persist()
    }
    func reconcile() {
        retryAfter = retryAfter.filter { $0.value > now() }
        for (id, item) in receipts where item.expires <= now() || !(validate?(item) ?? true) { discard(id) }
    }
    func receive(id: String, action: String) {
        guard let item = receipts[id] else { return }
        if item.test {
            discard(id)
            return
        }
        // Resolution and stale-action handling belong to the store, including
        // deferred cold-launch responses before calendar restoration completes.
        onResponse?(item, action)
        discard(id)
    }
    func test(sound: Bool) {
        cancelMeetingPreview()
        sendTest(ReminderNotification(id: "now.test", keys: [], fingerprints: [], expires: now().addingTimeInterval(60), catchUp: false, test: true,
                                     title: "now · Test notification", body: "Meeting notifications will appear here. Focus and macOS control their presentation.",
                                     category: SystemNotificationTransport.category(join: false, snooze: false), sound: sound))
    }

    func previewMeeting(settings: AppSettings) {
        onMeetingPreview?()
        cancelMeetingPreview()
        let event = AlertController.previewEvent(at: now(), settings: settings)
        sendMeetingPreview(event, settings: settings)
    }

    func cancelMeetingPreview() {
        for item in Array(receipts.values) where item.test && item.id.hasPrefix("now.test.meeting.") { discard(item.id) }
    }

    private func sendMeetingPreview(_ event: MeetingEvent, settings: AppSettings) {
        let date = now()
        let text = NotificationLogic.content(events: [event], privateDetails: settings.hideNotificationDetails, catchUp: false, now: date)
        let options = AlertController.snoozeOptions(events: [event], now: date, customSeconds: settings.snoozeSeconds)
        let canSnooze = AlertController.primarySnoozePlan(options: options, defaultSeconds: settings.snoozeSeconds) != nil
        sendTest(ReminderNotification(id: "now.test.meeting", keys: [], fingerprints: [], expires: event.end, catchUp: false, test: true,
                                     title: text.title, body: text.body,
                                     category: SystemNotificationTransport.category(join: false, snooze: canSnooze), sound: settings.soundEnabled))
    }

    private func sendTest(_ item: ReminderNotification) {
        // Explicit tests replace the previous sample, even if its temporary
        // banner has disappeared but its Notification Center receipt remains.
        // Each attempt already gets a unique request ID; visible timestamps
        // are unnecessary. Real reminder deduplication stays unchanged.
        for receipt in Array(receipts.values) where receipt.test { discard(receipt.id) }
        retryAfter.removeValue(forKey: item.id)
        offer(item, now: now())
    }
    func openSettings() {
        // macOS has no public per-app settings URL API. Use the Notifications
        // pane link with an app hint; always show the manual path in the UI.
        let identifier = Bundle.main.bundleIdentifier ?? "com.thomasboch.now"
        let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? identifier
        let target = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(encoded)")!
        if !NSWorkspace.shared.open(target) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
    private func persist() {
        // Retain hashes and timing for cold-launch validation, never meeting text.
        let sanitized = receipts.mapValues { item -> ReminderNotification in
            var copy = item; copy.title = ""; copy.body = ""; return copy
        }
        if let data = try? JSONEncoder().encode(sanitized) { defaults.set(data, forKey: storageKey) }
    }
}
