import Foundation
import NowCore

extension SelfTest {
    static func modelBoundaryTests(_ c: inout Checker) {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in [Int.min, -11, -1, 0, 1, 9, 10, Int.max] {
            let expected = Palette.hex(for: index)
            let subscription = CalendarSubscription(name: "Palette", url: "https://example.invalid", colorIndex: index)
            c.expect(subscription.colorHex == expected, "model boundary: constructor retains native palette at \(index)")
            let json = "{\"name\":\"Legacy\",\"url\":\"https://example.invalid\",\"colorIndex\":\(index)}"
            let restored = try? AppModelCoding.decoder().decode(CalendarSubscription.self, from: Data(json.utf8))
            c.expect(restored?.colorHex == expected, "model boundary: legacy decode retains native palette at \(index)")
            let item = MeetingEvent(uid: "palette", title: "Palette", start: start, end: start.addingTimeInterval(60),
                                    location: nil, notes: nil, link: nil, calendarID: subscription.id,
                                    calendarName: subscription.name, colorIndex: index)
            c.expect(item.colorHex == expected, "model boundary: event constructor resolves native palette at \(index)")
            let optionalColor: String? = "#123456"
            let explicit = MeetingEvent(uid: item.uid, title: item.title, start: item.start, end: item.end,
                                        location: nil, notes: nil, link: nil, calendarID: item.calendarID,
                                        calendarName: item.calendarName, colorIndex: index, colorHex: optionalColor)
            c.expect(explicit.colorHex == "#123456" && explicit.id == item.id, "model boundary: optional explicit color and identity retained")
        }
        for color in ["null", "\"\"", "\"#abcdef\""] {
            let json = "{\"subscriptions\":[{\"name\":\"Legacy\",\"url\":\"https://example.invalid\",\"colorIndex\":2,\"colorHex\":\(color)}]}"
            let decoder = AppModelCoding.decoder()
            let audit = PreferenceDecoding()
            decoder.userInfo[PreferenceDecoding.key] = audit
            let profile = try? decoder.decode(Persisted.self, from: Data(json.utf8))
            let expected = color == "null" ? Palette.hex(for: 2) : color == "\"\"" ? "" : "#abcdef"
            c.expect(profile?.subscriptions.first?.colorHex == expected && !audit.recovered,
                     "model boundary: nested null/empty/explicit color preserves decoding semantics")
        }
        c.expect(AppStore.soundNames == AppSettings.soundNames, "model boundary: sound UI and saved-value validation share one vocabulary")
    }
}
