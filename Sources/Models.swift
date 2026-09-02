import SwiftUI
import AppKit

struct CalendarSubscription: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var colorIndex: Int = 0
    var colorHex: String = ""
    var isEnabled = true

    enum CodingKeys: String, CodingKey {
        case id, name, url, colorIndex, colorHex, isEnabled
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
    }
}

struct AppSettings: Codable, Equatable {
    var leadSeconds = 300
    var refreshMinutes = 15
    var soundEnabled = true
    var soundName = "Hero"
    var showMenuBarCountdown = true
    var launchAtLogin = false
    var lateMinutes = 0
    var skipDeclined = true
    var automaticUpdateChecks = true
    var suppressRemindersDuringMeetings = false
    var includeBrowserMeetings = false
    /// Reserved for the v2 "Skip this version" UI — the updater already
    /// honors it in `decide`.
    var skippedUpdateVersion: String?

    /// The values the UI offers — persisted junk is snapped back into range on
    /// decode instead of crashing pickers or producing absurd behavior.
    static let allowedRefreshMinutes = [5, 15, 30, 60]
    static let leadSecondsRange = 0...7200
    static let allowedLateMinutes = [-1, 0, 5, 15, 30, 60]

    enum CodingKeys: String, CodingKey {
        case leadSeconds, refreshMinutes, soundEnabled, soundName, showMenuBarCountdown, launchAtLogin, lateMinutes, skipDeclined, automaticUpdateChecks, suppressRemindersDuringMeetings, includeBrowserMeetings, skippedUpdateVersion
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
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        let late = try c.decodeIfPresent(Int.self, forKey: .lateMinutes) ?? 0
        lateMinutes = Self.nearest(late, in: Self.allowedLateMinutes, default: 0)
        skipDeclined = try c.decodeIfPresent(Bool.self, forKey: .skipDeclined) ?? true
        automaticUpdateChecks = try c.decodeIfPresent(Bool.self, forKey: .automaticUpdateChecks) ?? true
        suppressRemindersDuringMeetings = try c.decodeIfPresent(Bool.self, forKey: .suppressRemindersDuringMeetings) ?? false
        includeBrowserMeetings = try c.decodeIfPresent(Bool.self, forKey: .includeBrowserMeetings) ?? false
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

    enum CodingKeys: String, CodingKey {
        case id, ekIdentifier, name, colorHex, colorIndex, isEnabled
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
    /// Pause survives relaunch (incl. indefinite); snoozes/alerted memory do
    /// not — a delayed launch should still alert for a due meeting.
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

    var nsColor: NSColor { Palette.nsColor(hex: colorHex) }
    var color: Color { Color(nsColor: nsColor) }
    /// Contrast-safe variant for the fullscreen alert's black background —
    /// user-picked near-black colors must not vanish.
    var readableColorOnBlack: Color { Color(nsColor: Palette.readable(nsColor, on: .onBlack)) }
    var readableNsColorOnBlack: NSColor { Palette.readable(nsColor, on: .onBlack) }
    var alertButtonColor: Color { Color(nsColor: Palette.alertButtonColor(nsColor)) }

    init(uid: String, title: String, start: Date, end: Date, location: String?, notes: String?, link: URL?, calendarID: UUID, calendarName: String, colorIndex: Int, colorHex: String? = nil) {
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
        self.id = "\(calendarID.uuidString)-\(uid)-\(Int(start.timeIntervalSince1970))"
    }
}
