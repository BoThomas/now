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

    static func sameStartGroups(_ events: [MeetingEvent]) -> [[MeetingEvent]] {
        Dictionary(grouping: events, by: \.start).sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.id < $1.id } }
    }

    static func content(events: [MeetingEvent], privateDetails: Bool, catchUp: Bool, now: Date) -> (title: String, body: String) {
        let startingNow = !events.isEmpty && events.allSatisfy {
            Fmt.isStartingNow(start: $0.start, end: $0.end, now: now)
        }
        if events.count > 1 && !catchUp {
            let started = events.allSatisfy { $0.start <= now }
            let title = "\(events.count) meetings " + (startingNow ? "are starting now" : (started ? "are in progress" : "are starting"))
            let names = events.prefix(3).map { String(($0.title.isEmpty ? "Untitled meeting" : $0.title).prefix(60)) }.joined(separator: " · ")
            let more = events.count > 3 ? " · +\(events.count - 3) more" : ""
            return (title, privateDetails ? "Choose a meeting in your agenda." : names + more + "\nChoose a meeting in your agenda.")
        }
        if events.count != 1 {
            return ("\(events.count) meetings " + (startingNow ? "are starting now" : "are in progress"), "Open now to view your agenda.")
        }
        guard let event = events.first else { return ("Meeting reminder", "Open now to view your agenda.") }
        let started = event.start <= now
        let title = privateDetails ? (startingNow ? "A meeting is starting now" : (started ? "A meeting is in progress" : "A meeting is starting"))
            : String((event.title.isEmpty ? "Untitled meeting" : event.title).prefix(180))
        let body = startingNow ? "Starts now · ends at \(Fmt.time.string(from: event.end))"
            : started ? "Started at \(Fmt.time.string(from: event.start)) · ends at \(Fmt.time.string(from: event.end))"
            : "Starts at \(Fmt.time.string(from: event.start)) · \(Fmt.leadTime(max(1, Int(event.start.timeIntervalSince(now))))) from now"
        return (title, body)
    }

    static func eventKey(_ event: MeetingEvent) -> String {
        guard let identity = event.notificationIdentity else { return key(event.id) }
        return key(event.calendarID.uuidString + ":" + identity)
    }

    static func legacyFingerprint(_ event: MeetingEvent) -> String {
        key([event.legacyID, event.title, String(event.end.timeIntervalSince1970), event.link?.absoluteString ?? "", String(event.isMuted)].joined(separator: "\n"))
    }

    static func priorAgendaFingerprint(_ event: MeetingEvent) -> String {
        key([event.legacyID, event.title, String(event.end.timeIntervalSince1970), event.link?.absoluteString ?? "", event.location ?? "", String(event.isMuted)].joined(separator: "\n"))
    }

    static func fingerprint(_ event: MeetingEvent) -> String {
        key([event.id, event.title, String(event.end.timeIntervalSince1970), event.link?.absoluteString ?? "", event.location ?? "", String(event.isMuted)].joined(separator: "\n"))
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
        /// Older ledgers did not retain the scheduled start.
        var start: Date?
    }
    var entries: [String: Entry] = [:]
    mutating func record(_ event: MeetingEvent, snooze: Date? = nil) {
        entries[NotificationLogic.eventKey(event)] = Entry(calendarID: event.calendarID, end: event.end, snooze: snooze, start: event.start)
    }
    @discardableResult
    mutating func reconcile(events: [MeetingEvent], enabled: Set<UUID>, observed: Set<UUID>, now: Date,
                            rearmOnReschedule: Set<String> = [], previousEvents: [MeetingEvent] = []) -> Set<String> {
        var rearmedIDs: Set<String> = []
        let previousByKey = Dictionary(previousEvents.map { (NotificationLogic.eventKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        // Upgrade old occurrence-ID entries only when that exact occurrence is present.
        let legacyCounts = Dictionary(grouping: events, by: \.legacyID).mapValues(\.count)
        // Once an old key matches multiple occurrences, it cannot safely be
        // assigned later merely because one sibling disappears.
        for (id, count) in legacyCounts where count > 1 { entries.removeValue(forKey: NotificationLogic.key(id)) }
        for event in events where legacyCounts[event.legacyID] == 1 {
            let old = NotificationLogic.key(event.legacyID), key = NotificationLogic.eventKey(event)
            if old != key, let entry = entries.removeValue(forKey: old), entries[key] == nil { entries[key] = entry }
        }
        let live = Dictionary(events.map { (NotificationLogic.eventKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        for (key, var entry) in entries {
            if let event = live[key] {
                // Notification receipts own their edit lifecycle; fullscreen reminders
                // can re-arm at a new start. Explicit snoozes retain their chosen deadline.
                let previousStart = entry.start ?? previousByKey[key]?.start
                if rearmOnReschedule.contains(key), entry.snooze == nil,
                   let previousStart, previousStart != event.start {
                    entries.removeValue(forKey: key)
                    rearmedIDs.insert(event.id)
                    // Forget the old in-memory ID too, even if the new reminder
                    // has not fired before another edit moves back to that start.
                    if let previous = previousByKey[key] { rearmedIDs.insert(previous.id) }
                    continue
                }
                entry.start = event.start
                entry.end = event.end
                entry.misses = 0
            }
            else if observed.contains(entry.calendarID) { entry.misses += 1 }
            guard enabled.contains(entry.calendarID), entry.end > now else { entries.removeValue(forKey: key); continue }
            if entry.misses >= 2 { entries.removeValue(forKey: key) }
            else { entries[key] = entry }
        }
        if entries.count > 20_000 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.end > $1.value.end }.prefix(20_000).map { ($0.key, $0.value) })
        }
        return rearmedIDs
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
        return Set(firstFailure.compactMap { id, start in
            !notified.contains(id) && now.timeIntervalSince(start) >= 300 ? id : nil
        })
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
    // Optional fields preserve decoding of receipts written by previous versions.
    var hidden: Bool? = nil
    var visibleKeys: [String]? = nil
    var replacementReason: String? = nil
    var fingerprintVersion: Int? = nil
    var accepted: Bool? = nil
}

enum NotificationReconciliation {
    case keep(ReminderNotification)
    case hide(ReminderNotification)
    case replace(ReminderNotification)
    case remove
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
        categories.insert(UNNotificationCategory(identifier: Self.chooseMeetingCategory,
            actions: [UNNotificationAction(identifier: "choose", title: "Choose Meeting…", options: [.foreground])],
            intentIdentifiers: [], options: [.customDismissAction]))
        center.setNotificationCategories(categories)
    }
    nonisolated static let chooseMeetingCategory = "now.meeting.choose"
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
    private var replacementOrigins: [String: ReminderNotification] = [:]
    private var startupReceipts: [String: ReminderNotification] = [:]
    private var startupActionsUntil: Date?
    private var responseAliases: [String: (item: ReminderNotification, expires: Date)] = [:]
    var deferRestoredReconciliation: (() -> Bool)?
    var reconcileDelivered: ((ReminderNotification) -> NotificationReconciliation)?
    private var retryAfter: [String: Date] = [:]
    var now: () -> Date = { Date() }
    private var refreshing = false
    private var lastPermissionCheck = Date.distantPast
    private var permissionRevision = 0
    var validate: ((ReminderNotification) -> Bool)?
    var onSubmitted: ((ReminderNotification) -> Void)?
    var onResponse: ((ReminderNotification, String) -> Void)?
    var onMeetingPreview: (() -> Void)?

    init(transport: NotificationTransport, defaults: UserDefaults = AppPreferences.standard) {
        self.transport = transport
        self.defaults = defaults
        if let saved = StoredPreferences.load([String: ReminderNotification].self, key: storageKey, label: "Delivered reminder history", defaults: defaults, maxBytes: 8_000_000) {
            receipts = saved.filter { id, item in
                id == item.id && id.hasPrefix("now.") && item.keys.count <= 20_000
                    && Set(item.keys).count == item.keys.count
                    && (item.sync || item.test || item.updateVersion != nil || item.fingerprints.count == item.keys.count)
            }
            startupReceipts = receipts
            // An interrupted add has no delivery acknowledgement. Retry from a
            // hidden receipt rather than reserving it forever after a crash.
            for (id, var item) in receipts where item.accepted == false {
                item.hidden = true
                receipts[id] = item
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
        submit(proposed, replacing: nil, now: now)
    }

    private func submit(_ proposed: ReminderNotification, replacing old: ReminderNotification?, now: Date) {
        let retryKey = proposed.id
        guard !receipts.values.contains(where: { $0.id != old?.id && !$0.keys.isEmpty && !Set($0.keys).isDisjoint(with: proposed.keys) }),
              !receipts.values.contains(where: { proposed.test && $0.test }), now >= retryAfter[retryKey, default: .distantPast] else { return }
        var item = proposed
        item.id += "." + UUID().uuidString
        item.hidden = false
        item.accepted = false
        item.visibleKeys = proposed.visibleKeys ?? item.keys
        if var old {
            old.hidden = true
            replacementOrigins[item.id] = old
            responseAliases[old.id] = (old, now.addingTimeInterval(120))
            discard(old.id)
        }
        receipts[item.id] = item
        pending.insert(item.id)
        let revision = permissionRevision
        Task {
            let status = await transport.permission()
            if revision == permissionRevision { permission = status }
            guard receipts[item.id] == item else { return }
            guard item.expires > self.now(), validate?(item) ?? true else {
                retrySubmission(item.id); return
            }
            guard status.canSubmit else {
                retryAfter[retryKey] = now.addingTimeInterval(30)
                retrySubmission(item.id); return
            }
            // Persist before add: responses can precede its completion.
            persist()
            do {
                try await transport.add(item)
                guard receipts[item.id] == item else { transport.remove([item.id]); return }
                guard item.expires > self.now(), validate?(item) ?? true else {
                    retrySubmission(item.id); return
                }
                pending.remove(item.id)
                replacementOrigins.removeValue(forKey: item.id)
                problem = nil
                retryAfter.removeValue(forKey: retryKey)
                var delivered = item
                delivered.accepted = true
                receipts[item.id] = delivered
                onSubmitted?(delivered)
                persist()
            } catch {
                guard receipts[item.id] == item else { transport.remove([item.id]); return }
                problem = "macOS could not accept a notification. Check Notification Settings or try the preview again."
                retryAfter[retryKey] = now.addingTimeInterval(60)
                retrySubmission(item.id)
            }
        }
    }

    /// A failed replacement retains its old, hidden receipt as retry intent.
    /// Explicit cancellation never goes through this path and cannot resurrect it.
    private func retrySubmission(_ id: String) {
        let old = replacementOrigins[id]
        discard(id)
        if let old { receipts[old.id] = old; persist() }
    }

    func removeMeetings(containing keys: Set<String>) {
        for (id, item) in startupReceipts where !item.sync && item.updateVersion == nil {
            let remaining = removing(keys, from: item)
            startupReceipts[id] = remaining.keys.isEmpty ? nil : remaining
        }
        for (id, alias) in responseAliases where !alias.item.sync && alias.item.updateVersion == nil {
            let remaining = removing(keys, from: alias.item)
            responseAliases[id] = remaining.keys.isEmpty ? nil : (remaining, alias.expires)
        }
        for item in Array(receipts.values) where !item.sync && !Set(item.keys).isDisjoint(with: keys) {
            if pending.contains(item.id) {
                // Remove acted-on members from retry intent before cancelling an add.
                if let origin = replacementOrigins[item.id] {
                    let remaining = removing(keys, from: origin)
                    replacementOrigins[item.id] = remaining.keys.isEmpty ? nil : remaining
                }
                retrySubmission(item.id)
                continue
            }
            let remaining = removing(keys, from: item)
            if remaining.keys.isEmpty { discard(item.id) }
            else { receipts[item.id] = remaining; persist() }
        }
    }

    private func removing(_ keys: Set<String>, from item: ReminderNotification) -> ReminderNotification {
        var result = item
        let pairs = zip(item.keys, item.fingerprints).filter { !keys.contains($0.0) }
        result.keys = pairs.map { $0.0 }
        result.fingerprints = pairs.map { $0.1 }
        result.visibleKeys = item.visibleKeys?.filter { !keys.contains($0) }
        return result
    }

    func discard(_ id: String) {
        receipts.removeValue(forKey: id)
        pending.remove(id)
        replacementOrigins.removeValue(forKey: id)
        transport.remove([id])
        persist()
    }

    func reconcile() {
        retryAfter = retryAfter.filter { $0.value > now() }
        responseAliases = responseAliases.filter { $0.value.expires > now() }
        if responseAliases.count > 512 || responseAliases.values.reduce(0, { $0 + $1.item.keys.count }) > 20_000 {
            var budget = 20_000
            responseAliases = Dictionary(uniqueKeysWithValues: responseAliases.sorted { $0.value.expires > $1.value.expires }.prefix(512).filter {
                guard $0.value.item.keys.count <= budget else { return false }
                budget -= $0.value.item.keys.count
                return true
            })
        }
        let protectStartup = deferRestoredReconciliation?() ?? false
        if !protectStartup && startupActionsUntil == nil { startupActionsUntil = now().addingTimeInterval(120) }
        if let until = startupActionsUntil, now() >= until { startupReceipts = [:] }
        for (id, item) in Array(receipts) {
            if protectStartup && startupReceipts[id] != nil && !item.sync && !item.test && item.updateVersion == nil { continue }
            if item.accepted == false && !pending.contains(id) && (item.sync || item.test || item.updateVersion != nil) {
                // Diagnostic/update producers retry from their own durable state;
                // an interrupted add must not reserve those notices indefinitely.
                discard(id)
                continue
            }
            if pending.contains(id) {
                if item.expires <= now() || !(validate?(item) ?? true) { retrySubmission(id) }
                continue
            }
            guard let reconcileDelivered else {
                if item.expires <= now() || !(validate?(item) ?? true) { discard(id) }
                continue
            }
            switch reconcileDelivered(item) {
            case .remove: discard(id)
            case .keep(let next), .hide(let next):
                if next.hidden == true && item.hidden != true { transport.remove([id]) }
                if next != item { receipts[id] = next; persist() }
            case .replace(let next):
                // Never leave stale content visible while permission/retry is pending.
                var hidden = item; hidden.hidden = true; hidden.replacementReason = next.replacementReason
                if item.hidden != true { transport.remove([id]); receipts[id] = hidden; persist() }
                submit(next, replacing: hidden, now: now())
            }
        }
    }

    func receive(id: String, action: String) {
        // A cold-start callback may arrive just after initial refresh cleanup.
        // Keep only the launch's bounded, opaque receipts briefly for that race.
        let cold = startupActionsUntil.map { now() < $0 } ?? true
        let alias = responseAliases[id].flatMap { $0.expires > now() ? $0.item : nil }
        guard let item = receipts[id] ?? alias ?? (cold ? startupReceipts[id] : nil) else { return }
        let actedKeys = Set(item.keys)
        startupReceipts = startupReceipts.filter { $0.key != id && Set($0.value.keys).isDisjoint(with: actedKeys) }
        responseAliases = responseAliases.filter { $0.key != id && Set($0.value.item.keys).isDisjoint(with: actedKeys) }
        if item.test { discard(id); return }
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
        StoredPreferences.save(sanitized, key: storageKey, label: "Delivered reminder history", defaults: defaults, maxBytes: 8_000_000)
    }
}
