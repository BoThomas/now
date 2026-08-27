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

    enum CodingKeys: String, CodingKey {
        case leadSeconds, refreshMinutes, soundEnabled, soundName, showMenuBarCountdown, launchAtLogin, lateMinutes, skipDeclined
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        leadSeconds = try c.decodeIfPresent(Int.self, forKey: .leadSeconds) ?? 300
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? 15
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        soundName = try c.decodeIfPresent(String.self, forKey: .soundName) ?? "Hero"
        showMenuBarCountdown = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarCountdown) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        lateMinutes = try c.decodeIfPresent(Int.self, forKey: .lateMinutes) ?? 0
        skipDeclined = try c.decodeIfPresent(Bool.self, forKey: .skipDeclined) ?? true
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

struct Persisted: Codable {
    var subscriptions: [CalendarSubscription]
    var settings: AppSettings
    var nativeCalendars: [NativeCalendar] = []

    init(subscriptions: [CalendarSubscription] = [], settings: AppSettings = AppSettings(), nativeCalendars: [NativeCalendar] = []) {
        self.subscriptions = subscriptions
        self.settings = settings
        self.nativeCalendars = nativeCalendars
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = try c.decodeIfPresent([CalendarSubscription].self, forKey: .subscriptions) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        nativeCalendars = try c.decodeIfPresent([NativeCalendar].self, forKey: .nativeCalendars) ?? []
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
