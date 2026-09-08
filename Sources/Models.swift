import SwiftUI
import AppKit

struct CalendarSubscription: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var colorIndex: Int = 0
    var colorHex: String = ""
    var isEnabled = true
    /// Title filters: matching meetings get no reminder (stay visible, grayed).
    var titleFilters: [TitleFilterRule] = []

    enum CodingKeys: String, CodingKey {
        case id, name, url, colorIndex, colorHex, isEnabled, titleFilters
    }

    init(name: String, url: String, colorIndex: Int) {
        self.name = name
        self.url = url
        self.colorIndex = colorIndex
        self.colorHex = Palette.hex(for: colorIndex)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? Palette.hex(for: colorIndex)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        // Per-entry failable: one malformed rule must never fail the whole
        // subscription record (which would evict it from persisted state).
        titleFilters = TitleFilterRule.normalized((try? c.decode([FailableDecoded<TitleFilterRule>].self, forKey: .titleFilters).compactMap(\.value)) ?? [])
    }
}

enum ReminderDelivery: String, Codable, CaseIterable { case fullscreen, notification }
enum CatchUpDelivery: String, Codable, CaseIterable { case normal, notification, skip }
enum InMeetingDelivery: String, Codable, CaseIterable { case normal, notification, suppress }

struct AppSettings: Codable, Equatable {
    var leadSeconds = 300 {
        didSet {
            if leadSeconds == 0 && snoozeSeconds == 0 { snoozeSeconds = 60 }
        }
    }
    var refreshMinutes = 15
    var soundEnabled = true
    var soundName = "Hero"
    var showMenuBarCountdown = true
    var menuMeetingLimit = 5
    var launchAtLogin = false
    /// Maximum time after a meeting starts during which its elapsed-start
    /// countdown may own the menu bar. `-1` disables it, `0` means until end.
    var elapsedStartMinutes = 10
    var skipDeclined = true
    /// Default snooze: 0 means just in time; positive values are seconds.
    /// What the alert's main snooze button and the
    /// "s" shortcut apply (the alert's snooze menu always offers all choices).
    var snoozeSeconds = 0
    var automaticUpdateChecks = true
    var suppressRemindersDuringMeetings = false
    var includeBrowserMeetings = false
    var reminderDelivery: ReminderDelivery = .fullscreen
    var notifyDuringMeetings = false
    var notifyOnCatchUp = false
    var skipMeetingsOnCatchUp = false

    var catchUpDelivery: CatchUpDelivery {
        get { skipMeetingsOnCatchUp ? .skip : (notifyOnCatchUp ? .notification : .normal) }
        set {
            notifyOnCatchUp = newValue == .notification
            skipMeetingsOnCatchUp = newValue == .skip
        }
    }
    var hideNotificationDetails = false
    var notifySyncErrors = false
    var notifyUpdates = false

    var inMeetingDelivery: InMeetingDelivery {
        get { notifyDuringMeetings ? .notification : (suppressRemindersDuringMeetings ? .suppress : .normal) }
        set {
            notifyDuringMeetings = newValue == .notification
            suppressRemindersDuringMeetings = newValue == .suppress
        }
    }
    var needsMeetingDetection: Bool { inMeetingDelivery != .normal }
    var usesNotifications: Bool {
        reminderDelivery == .notification || notifyDuringMeetings || notifyOnCatchUp || notifySyncErrors || (notifyUpdates && automaticUpdateChecks)
    }
    /// Reserved for the v2 "Skip this version" UI — the updater already
    /// honors it in `decide`.
    var skippedUpdateVersion: String?

    /// The values the UI offers — persisted junk is snapped back into range on
    /// decode instead of crashing pickers or producing absurd behavior.
    static let allowedMenuMeetingLimits = [3, 5, 10, 15]

    static func normalizedMenuMeetingLimit(_ value: Int) -> Int {
        allowedMenuMeetingLimits.contains(value) ? value : 5
    }

    static let allowedRefreshMinutes = [5, 15, 30, 60]
    static let leadSecondsRange = 0...7200
    static let allowedElapsedStartMinutes = [-1, 0, 5, 10, 15, 30, 60]
    static let snoozePresets = [60, 180, 300, 600]
    static let snoozeSecondsRange = 1...7200

    static func snoozeDurations(including customSeconds: Int) -> [Int] {
        let custom = snoozeSecondsRange.contains(customSeconds) ? [customSeconds] : []
        return Set(snoozePresets + custom).sorted()
    }

    enum CodingKeys: String, CodingKey {
        case reminderDelivery, notifyDuringMeetings, notifyOnCatchUp, skipMeetingsOnCatchUp, hideNotificationDetails, notifySyncErrors, notifyUpdates
        case menuMeetingLimit, leadSeconds, refreshMinutes, soundEnabled, soundName, showMenuBarCountdown, launchAtLogin, elapsedStartMinutes, skipDeclined, snoozeSeconds, automaticUpdateChecks, suppressRemindersDuringMeetings, includeBrowserMeetings, skippedUpdateVersion
    }

    init() {}

    private static func nearest(_ value: Int, in allowed: [Int], default fallback: Int) -> Int {
        guard let first = allowed.first, let last = allowed.last else { return fallback }
        if value <= first { return first }
        if value >= last { return last }
        return allowed.min(by: { abs($0 - value) < abs($1 - value) }) ?? fallback
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lead = try c.decodeIfPresent(Int.self, forKey: .leadSeconds) ?? 300
        leadSeconds = min(max(lead, Self.leadSecondsRange.lowerBound), Self.leadSecondsRange.upperBound)
        let refresh = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? 15
        refreshMinutes = Self.nearest(refresh, in: Self.allowedRefreshMinutes, default: 15)
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        let sound = try c.decodeIfPresent(String.self, forKey: .soundName) ?? "Hero"
        soundName = AppStore.soundNames.contains(sound) ? sound : "Hero"
        showMenuBarCountdown = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarCountdown) ?? true
        menuMeetingLimit = Self.normalizedMenuMeetingLimit(try c.decodeIfPresent(Int.self, forKey: .menuMeetingLimit) ?? 5)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        // `lateMinutes` belonged to the former "Show started meetings"
        // visibility setting. Its semantics changed enough that carrying the
        // old value forward would be misleading, so an absent new key always
        // starts at the intentional 10-minute default.
        let elapsed = try c.decodeIfPresent(Int.self, forKey: .elapsedStartMinutes) ?? 10
        elapsedStartMinutes = Self.nearest(elapsed, in: Self.allowedElapsedStartMinutes, default: 10)
        skipDeclined = try c.decodeIfPresent(Bool.self, forKey: .skipDeclined) ?? true
        // New and existing installs share the same default when no explicit
        // snooze choice is saved. At-start reminders cannot snooze to the past.
        let snooze = try c.decodeIfPresent(Int.self, forKey: .snoozeSeconds) ?? (leadSeconds > 0 ? 0 : 60)
        if snooze == 0 && leadSeconds > 0 {
            snoozeSeconds = 0
        } else {
            snoozeSeconds = snooze > 0 ? min(snooze, Self.snoozeSecondsRange.upperBound) : 60
        }
        automaticUpdateChecks = try c.decodeIfPresent(Bool.self, forKey: .automaticUpdateChecks) ?? true
        suppressRemindersDuringMeetings = try c.decodeIfPresent(Bool.self, forKey: .suppressRemindersDuringMeetings) ?? false
        includeBrowserMeetings = try c.decodeIfPresent(Bool.self, forKey: .includeBrowserMeetings) ?? false
        reminderDelivery = (try? c.decode(ReminderDelivery.self, forKey: .reminderDelivery)) ?? .fullscreen
        notifyDuringMeetings = (try? c.decode(Bool.self, forKey: .notifyDuringMeetings)) ?? false
        if notifyDuringMeetings { suppressRemindersDuringMeetings = false }
        notifyOnCatchUp = (try? c.decode(Bool.self, forKey: .notifyOnCatchUp)) ?? false
        skipMeetingsOnCatchUp = (try? c.decode(Bool.self, forKey: .skipMeetingsOnCatchUp)) ?? false
        if skipMeetingsOnCatchUp { notifyOnCatchUp = false }
        hideNotificationDetails = (try? c.decode(Bool.self, forKey: .hideNotificationDetails)) ?? false
        notifySyncErrors = (try? c.decode(Bool.self, forKey: .notifySyncErrors)) ?? false
        notifyUpdates = (try? c.decode(Bool.self, forKey: .notifyUpdates)) ?? false
        skippedUpdateVersion = try c.decodeIfPresent(String.self, forKey: .skippedUpdateVersion)
    }
}

/// A calendar from EventKit (Calendar.app) the user has enabled. `id` is OUR stable UUID —
/// `MeetingEvent.calendarID` and alert/snooze bookkeeping key off it, never off the
/// EventKit identifier (which can change when an account is re-added).
struct NativeCalendar: Codable, Identifiable, Equatable {
    var id = UUID()
    var ekIdentifier: String
    var name: String
    var colorHex: String = ""
    var colorIndex: Int = 0
    var isEnabled = true
    /// Title filters: matching meetings get no reminder (stay visible, grayed).
    var titleFilters: [TitleFilterRule] = []

    enum CodingKeys: String, CodingKey {
        case id, ekIdentifier, name, colorHex, colorIndex, isEnabled, titleFilters
    }

    init(ekIdentifier: String, name: String, colorHex: String = "", colorIndex: Int = 0, isEnabled: Bool = true) {
        self.ekIdentifier = ekIdentifier
        self.name = name
        self.colorHex = colorHex
        self.colorIndex = colorIndex
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        ekIdentifier = try c.decode(String.self, forKey: .ekIdentifier)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? ""
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        titleFilters = TitleFilterRule.normalized((try? c.decode([FailableDecoded<TitleFilterRule>].self, forKey: .titleFilters).compactMap(\.value)) ?? [])
    }
}

/// Decodes `T?` — a malformed element yields nil instead of failing the whole
/// array, so one bad subscription/calendar can't discard the entire state.
struct FailableDecoded<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

struct Persisted: Codable {
    var subscriptions: [CalendarSubscription]
    var settings: AppSettings
    var nativeCalendars: [NativeCalendar] = []
    /// Pause survives relaunch (incl. indefinite). Reminder acknowledgements
    /// and snoozes persist separately in ReminderLedger.
    var pausedUntil: Date?

    init(subscriptions: [CalendarSubscription] = [], settings: AppSettings = AppSettings(), nativeCalendars: [NativeCalendar] = [], pausedUntil: Date? = nil) {
        self.subscriptions = subscriptions
        self.settings = settings
        self.nativeCalendars = nativeCalendars
        self.pausedUntil = pausedUntil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = (try? c.decode([FailableDecoded<CalendarSubscription>].self, forKey: .subscriptions).compactMap(\.value)) ?? []
        settings = (try? c.decode(AppSettings.self, forKey: .settings)) ?? AppSettings()
        nativeCalendars = (try? c.decode([FailableDecoded<NativeCalendar>].self, forKey: .nativeCalendars).compactMap(\.value)) ?? []
        pausedUntil = try? c.decodeIfPresent(Date.self, forKey: .pausedUntil)
    }
}

struct MeetingEvent: Identifiable {
    let id: String
    let uid: String
    let title: String
    let start: Date
    let end: Date
    let location: String?
    let notes: String?
    let link: URL?
    let calendarID: UUID
    let calendarName: String
    let colorIndex: Int
    var colorHex: String
    /// Derived state (like `colorHex`): a title filter of this event's calendar
    /// matches. Recomputed at the same re-tint points — never persisted, never
    /// set by hand outside those sites. Muted events stay visible (grayed) and
    /// never alert (`dueForAlert` skips them).
    var isMuted: Bool = false

    var nsColor: NSColor { Palette.nsColor(hex: colorHex) }
    var color: Color { Color(nsColor: nsColor) }
    /// Contrast-safe variant for the fullscreen alert's black background —
    /// user-picked near-black colors must not vanish.
    var readableColorOnBlack: Color { Color(nsColor: Palette.readable(nsColor, on: .onBlack)) }
    var readableNsColorOnBlack: NSColor { Palette.readable(nsColor, on: .onBlack) }
    var alertButtonColor: Color { Color(nsColor: Palette.alertButtonColor(nsColor)) }

    init(uid: String, title: String, start: Date, end: Date, location: String?, notes: String?, link: URL?, calendarID: UUID, calendarName: String, colorIndex: Int, colorHex: String? = nil, isMuted: Bool = false) {
        self.uid = uid
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.link = link
        self.calendarID = calendarID
        self.calendarName = calendarName
        self.colorIndex = colorIndex
        self.colorHex = colorHex ?? Palette.hex(for: colorIndex)
        self.isMuted = isMuted
        self.id = "\(calendarID.uuidString)-\(uid)-\(Int(start.timeIntervalSince1970))"
    }
}
