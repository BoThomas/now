import Foundation

package struct CalendarSubscription: Codable, Identifiable, Equatable, Sendable {
    package var id = UUID()
    package var name: String
    package var url: String
    package var colorIndex: Int = 0
    package var colorHex: String = ""
    package var isEnabled = true
    /// Title filters: matching meetings get no reminder (stay visible, grayed).
    package var titleFilters: [TitleFilterRule] = []

    enum CodingKeys: String, CodingKey {
        case id, name, url, colorIndex, colorHex, isEnabled, titleFilters
    }

    package init(name: String, url: String, colorIndex: Int, colorHex: String) {
        self.name = name
        self.url = url
        self.colorIndex = colorIndex
        self.colorHex = colorHex
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? ModelDecoding.defaultCalendarColor(at: colorIndex, decoder: decoder)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        // Per-entry failable: one malformed rule must never fail the whole
        // subscription record (which would evict it from persisted state).
        titleFilters = TitleFilterRule.normalized(c.recover([FailableDecoded<TitleFilterRule>].self, forKey: .titleFilters, decoder: decoder)?.compactMap(\.value) ?? [])
    }
}

package enum ReminderDelivery: String, Codable, CaseIterable, Sendable { case fullscreen, notification }
package enum CatchUpDelivery: String, Codable, CaseIterable, Sendable { case normal, notification, skip }
package enum InMeetingDelivery: String, Codable, CaseIterable, Sendable { case normal, notification, suppress }

package struct AppSettings: Codable, Equatable, Sendable {
    /// Persisted macOS sound identifiers: a compatibility vocabulary, not playback APIs.
    package static let soundNames = ["Basso", "Blow", "Bottle", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    package var leadSeconds = 300 {
        didSet {
            if leadSeconds == 0 && snoozeSeconds == 0 { snoozeSeconds = 60 }
        }
    }
    package var refreshMinutes = 15
    package var soundEnabled = true
    package var soundName = "Hero"
    package var showMenuBarCountdown = true
    package var menuMeetingLimit = 5
    package var launchAtLogin = false
    /// Maximum time after a meeting starts during which its elapsed-start
    /// countdown may own the menu bar. `-1` disables it, `0` means until end.
    package var elapsedStartMinutes = 10
    package var skipDeclined = true
    /// Default snooze: 0 means just in time; positive values are seconds.
    /// What the alert's main snooze button and the
    /// "s" shortcut apply (the alert's snooze menu always offers all choices).
    package var snoozeSeconds = 0
    package var automaticUpdateChecks = true
    package var suppressRemindersDuringMeetings = false
    package var includeBrowserMeetings = false
    package var reminderDelivery: ReminderDelivery = .fullscreen
    package var notifyDuringMeetings = false
    package var notifyOnCatchUp = false
    package var skipMeetingsOnCatchUp = false

    package var catchUpDelivery: CatchUpDelivery {
        get { skipMeetingsOnCatchUp ? .skip : (notifyOnCatchUp ? .notification : .normal) }
        set {
            notifyOnCatchUp = newValue == .notification
            skipMeetingsOnCatchUp = newValue == .skip
        }
    }
    package var hideNotificationDetails = false
    package var notifySyncErrors = false
    package var notifyUpdates = false

    package var inMeetingDelivery: InMeetingDelivery {
        get { notifyDuringMeetings ? .notification : (suppressRemindersDuringMeetings ? .suppress : .normal) }
        set {
            notifyDuringMeetings = newValue == .notification
            suppressRemindersDuringMeetings = newValue == .suppress
        }
    }
    package var needsMeetingDetection: Bool { inMeetingDelivery != .normal }
    package var usesNotifications: Bool {
        reminderDelivery == .notification || notifyDuringMeetings || notifyOnCatchUp || notifySyncErrors || (notifyUpdates && automaticUpdateChecks)
    }
    /// Reserved for the v2 "Skip this version" UI — the updater already
    /// honors it in `decide`.
    package var skippedUpdateVersion: String?

    /// The values the UI offers — persisted junk is snapped back into range on
    /// decode instead of crashing pickers or producing absurd behavior.
    package static let allowedMenuMeetingLimits = [3, 5, 10, 15]

    package static func normalizedMenuMeetingLimit(_ value: Int) -> Int {
        allowedMenuMeetingLimits.contains(value) ? value : 5
    }

    package static let allowedRefreshMinutes = [5, 15, 30, 60]
    package static let leadPresets = [0, 10, 30, 60, 120, 300, 600, 900]
    package static func leadDurations(including seconds: Int) -> [Int] { Set(leadPresets + [seconds]).sorted() }
    package static let leadSecondsRange = 0...7200
    package static let allowedElapsedStartMinutes = [-1, 0, 5, 10, 15, 30, 60]
    package static let snoozePresets = [60, 180, 300, 600]
    package static let snoozeSecondsRange = 1...7200

    package static func snoozeDurations(including customSeconds: Int) -> [Int] {
        let custom = snoozeSecondsRange.contains(customSeconds) ? [customSeconds] : []
        return Set(snoozePresets + custom).sorted()
    }

    enum CodingKeys: String, CodingKey {
        case reminderDelivery, notifyDuringMeetings, notifyOnCatchUp, skipMeetingsOnCatchUp, hideNotificationDetails, notifySyncErrors, notifyUpdates
        case menuMeetingLimit, leadSeconds, refreshMinutes, soundEnabled, soundName, showMenuBarCountdown, launchAtLogin, elapsedStartMinutes, skipDeclined, snoozeSeconds, automaticUpdateChecks, suppressRemindersDuringMeetings, includeBrowserMeetings, skippedUpdateVersion
    }

    package init() {}

    private static func nearest(_ value: Int, in allowed: [Int], default fallback: Int) -> Int {
        guard let first = allowed.first, let last = allowed.last else { return fallback }
        if value <= first { return first }
        if value >= last { return last }
        return allowed.min(by: { abs($0 - value) < abs($1 - value) }) ?? fallback
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lead = c.recover(Int.self, forKey: .leadSeconds, decoder: decoder) ?? 300
        leadSeconds = min(max(lead, Self.leadSecondsRange.lowerBound), Self.leadSecondsRange.upperBound)
        let refresh = c.recover(Int.self, forKey: .refreshMinutes, decoder: decoder) ?? 15
        refreshMinutes = Self.nearest(refresh, in: Self.allowedRefreshMinutes, default: 15)
        soundEnabled = c.recover(Bool.self, forKey: .soundEnabled, decoder: decoder) ?? true
        let sound = c.recover(String.self, forKey: .soundName, decoder: decoder) ?? "Hero"
        soundName = Self.soundNames.contains(sound) ? sound : "Hero"
        showMenuBarCountdown = c.recover(Bool.self, forKey: .showMenuBarCountdown, decoder: decoder) ?? true
        menuMeetingLimit = Self.normalizedMenuMeetingLimit(c.recover(Int.self, forKey: .menuMeetingLimit, decoder: decoder) ?? 5)
        launchAtLogin = c.recover(Bool.self, forKey: .launchAtLogin, decoder: decoder) ?? false
        // `lateMinutes` belonged to the former "Show started meetings"
        // visibility setting. Its semantics changed enough that carrying the
        // old value forward would be misleading, so an absent new key always
        // starts at the intentional 10-minute default.
        let elapsed = c.recover(Int.self, forKey: .elapsedStartMinutes, decoder: decoder) ?? 10
        elapsedStartMinutes = Self.nearest(elapsed, in: Self.allowedElapsedStartMinutes, default: 10)
        skipDeclined = c.recover(Bool.self, forKey: .skipDeclined, decoder: decoder) ?? true
        // New and existing installs share the same default when no explicit
        // snooze choice is saved. At-start reminders cannot snooze to the past.
        let snooze = c.recover(Int.self, forKey: .snoozeSeconds, decoder: decoder) ?? (leadSeconds > 0 ? 0 : 60)
        if snooze == 0 && leadSeconds > 0 {
            snoozeSeconds = 0
        } else {
            snoozeSeconds = snooze > 0 ? min(snooze, Self.snoozeSecondsRange.upperBound) : 60
        }
        automaticUpdateChecks = c.recover(Bool.self, forKey: .automaticUpdateChecks, decoder: decoder) ?? true
        suppressRemindersDuringMeetings = c.recover(Bool.self, forKey: .suppressRemindersDuringMeetings, decoder: decoder) ?? false
        includeBrowserMeetings = c.recover(Bool.self, forKey: .includeBrowserMeetings, decoder: decoder) ?? false
        reminderDelivery = c.recover(ReminderDelivery.self, forKey: .reminderDelivery, decoder: decoder) ?? .fullscreen
        notifyDuringMeetings = c.recover(Bool.self, forKey: .notifyDuringMeetings, decoder: decoder) ?? false
        if notifyDuringMeetings { suppressRemindersDuringMeetings = false }
        notifyOnCatchUp = c.recover(Bool.self, forKey: .notifyOnCatchUp, decoder: decoder) ?? false
        skipMeetingsOnCatchUp = c.recover(Bool.self, forKey: .skipMeetingsOnCatchUp, decoder: decoder) ?? false
        if skipMeetingsOnCatchUp { notifyOnCatchUp = false }
        hideNotificationDetails = c.recover(Bool.self, forKey: .hideNotificationDetails, decoder: decoder) ?? false
        notifySyncErrors = c.recover(Bool.self, forKey: .notifySyncErrors, decoder: decoder) ?? false
        notifyUpdates = c.recover(Bool.self, forKey: .notifyUpdates, decoder: decoder) ?? false
        skippedUpdateVersion = c.recover(String.self, forKey: .skippedUpdateVersion, decoder: decoder, allowNull: true)
    }
}

/// A calendar from EventKit (Calendar.app) the user has enabled. `id` is OUR stable UUID —
/// `MeetingEvent.calendarID` and alert/snooze bookkeeping key off it, never off the
/// EventKit identifier (which can change when an account is re-added).
package struct NativeCalendar: Codable, Identifiable, Equatable, Sendable {
    package var id = UUID()
    package var ekIdentifier: String
    package var name: String
    package var colorHex: String = ""
    package var colorIndex: Int = 0
    package var isEnabled = true
    /// Title filters: matching meetings get no reminder (stay visible, grayed).
    package var titleFilters: [TitleFilterRule] = []

    enum CodingKeys: String, CodingKey {
        case id, ekIdentifier, name, colorHex, colorIndex, isEnabled, titleFilters
    }

    package init(ekIdentifier: String, name: String, colorHex: String = "", colorIndex: Int = 0, isEnabled: Bool = true) {
        self.ekIdentifier = ekIdentifier
        self.name = name
        self.colorHex = colorHex
        self.colorIndex = colorIndex
        self.isEnabled = isEnabled
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        ekIdentifier = try c.decode(String.self, forKey: .ekIdentifier)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? ""
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        titleFilters = TitleFilterRule.normalized(c.recover([FailableDecoded<TitleFilterRule>].self, forKey: .titleFilters, decoder: decoder)?.compactMap(\.value) ?? [])
    }
}

/// Decodes `T?` — a malformed element yields nil instead of failing the whole
/// array, so one bad subscription/calendar can't discard the entire state.
struct FailableDecoded<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        do { value = try T(from: decoder) }
        catch { PreferenceDecoding.note(decoder); value = nil }
    }
}

package struct Persisted: Codable, Sendable {
    package var subscriptions: [CalendarSubscription]
    package var settings: AppSettings
    package var nativeCalendars: [NativeCalendar] = []
    /// Pause survives relaunch (incl. indefinite). Reminder acknowledgements
    /// and snoozes persist separately in ReminderLedger.
    package var pausedUntil: Date?

    package init(subscriptions: [CalendarSubscription] = [], settings: AppSettings = AppSettings(), nativeCalendars: [NativeCalendar] = [], pausedUntil: Date? = nil) {
        self.subscriptions = subscriptions
        self.settings = settings
        self.nativeCalendars = nativeCalendars
        self.pausedUntil = pausedUntil
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = c.recover([FailableDecoded<CalendarSubscription>].self, forKey: .subscriptions, decoder: decoder)?.compactMap(\.value) ?? []
        settings = c.recover(AppSettings.self, forKey: .settings, decoder: decoder) ?? AppSettings()
        nativeCalendars = c.recover([FailableDecoded<NativeCalendar>].self, forKey: .nativeCalendars, decoder: decoder)?.compactMap(\.value) ?? []
        pausedUntil = c.recover(Date.self, forKey: .pausedUntil, decoder: decoder, allowNull: true)
        let originalCount = subscriptions.count + nativeCalendars.count
        var ids = Set<UUID>()
        subscriptions = subscriptions.filter { ids.insert($0.id).inserted }
        nativeCalendars = nativeCalendars.filter { ids.insert($0.id).inserted }
        if subscriptions.count + nativeCalendars.count != originalCount { PreferenceDecoding.note(decoder) }
    }
}

package struct MeetingEvent: Identifiable, Sendable {
    package let id: String
    package let uid: String
    /// Pre-v2 agenda identity, retained only for unambiguous saved-state migration.
    package var legacyID: String { "\(calendarID.uuidString)-\(uid)-\(Int(start.timeIntervalSince1970))" }
    /// Stable source occurrence identity for notification edits and recurring agenda disambiguation.
    package let notificationIdentity: String?
    package let title: String
    package let start: Date
    package let end: Date
    package let location: String?
    package let notes: String?
    package let link: URL?
    package let calendarID: UUID
    package let calendarName: String
    package let colorIndex: Int
    package var colorHex: String
    /// Derived state (like `colorHex`): a title filter of this event's calendar
    /// matches. Recomputed at the same re-tint points — never persisted, never
    /// set by hand outside those sites. Muted events stay visible (grayed) and
    /// never alert (`dueForAlert` skips them).
    package var isMuted: Bool = false

    package init(uid: String, title: String, start: Date, end: Date, location: String?, notes: String?, link: URL?, calendarID: UUID, calendarName: String, colorIndex: Int, colorHex: String, isMuted: Bool = false, notificationIdentity: String? = nil) {
        self.uid = uid
        self.notificationIdentity = notificationIdentity
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.link = link
        self.calendarID = calendarID
        self.calendarName = calendarName
        self.colorIndex = colorIndex
        self.colorHex = colorHex
        self.isMuted = isMuted
        let oldID = "\(calendarID.uuidString)-\(uid)-\(Int(start.timeIntervalSince1970))"
        // Recurring siblings can move onto the same start. Include the original
        // source occurrence, while preserving the existing reschedule semantics.
        if let identity = notificationIdentity,
           (identity.hasPrefix("ics:") || identity.hasPrefix("native:")), !identity.hasSuffix(":single") {
            self.id = oldID + "-occurrence:" + identity
        } else { self.id = oldID }
    }
}
