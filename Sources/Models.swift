import SwiftUI
import AppKit
import NowCore

/// Platform defaults are scoped to each decoder, never installed as mutable core globals.
enum AppModelCoding {
    static func decoder() -> JSONDecoder {
        ModelDecoding.decoder(calendarColor: { Palette.hex(for: $0) })
    }
}

extension CalendarSubscription {
    init(name: String, url: String, colorIndex: Int) {
        self.init(name: name, url: url, colorIndex: colorIndex, colorHex: Palette.hex(for: colorIndex))
    }
}

extension MeetingEvent {
    var nsColor: NSColor { Palette.nsColor(hex: colorHex) }
    var color: Color { Color(nsColor: nsColor) }
    /// Contrast-safe variant for the fullscreen alert's black background —
    /// user-picked near-black colors must not vanish.
    var readableColorOnBlack: Color { Color(nsColor: Palette.readable(nsColor, on: .onBlack)) }
    var readableNsColorOnBlack: NSColor { Palette.readable(nsColor, on: .onBlack) }
    var alertButtonColor: Color { Color(nsColor: Palette.alertButtonColor(nsColor)) }

    init(uid: String, title: String, start: Date, end: Date, location: String?, notes: String?, link: URL?, calendarID: UUID, calendarName: String, colorIndex: Int, colorHex: String? = nil, isMuted: Bool = false, notificationIdentity: String? = nil) {
        self.init(uid: uid, title: title, start: start, end: end, location: location, notes: notes,
                  link: link, calendarID: calendarID, calendarName: calendarName, colorIndex: colorIndex,
                  colorHex: colorHex ?? Palette.hex(for: colorIndex), isMuted: isMuted,
                  notificationIdentity: notificationIdentity)
    }
}
