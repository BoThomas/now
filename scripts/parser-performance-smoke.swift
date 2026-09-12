import Foundation
import NowCore
import CryptoKit

// Both current and historical comparisons build their complete SwiftPM targets.
// Neither runner constructs AppStore/EventKit.

@main enum ParserPerformanceSmoke {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_788_998_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        func stamp(_ seconds: Int) -> String { formatter.string(from: now.addingTimeInterval(Double(seconds))) }
        func calendar(_ body: String) -> String { "BEGIN:VCALENDAR\nVERSION:2.0\n" + body + "END:VCALENDAR\n" }
        var subscription = CalendarSubscription(name: "Benchmark", url: "https://example.invalid", colorIndex: 0)
        subscription.id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let description = String(repeating: "x", count: 8900) + " https://zoom.us/j/123456789"
        let recurring = (0..<500).map { i in
            "BEGIN:VEVENT\nUID:master-\(i)\nDTSTART:\(stamp(60))\nDURATION:PT30M\nRRULE:FREQ=DAILY;COUNT=14\nSUMMARY:Recurring\nLOCATION:Room \(i)\nDESCRIPTION:\(description)\nEND:VEVENT\n"
        }.joined()
        var dates = "BEGIN:VEVENT\nUID:overridden\nDTSTART:\(stamp(60))\nDURATION:PT30M\nSUMMARY:Master\nLOCATION:Master room\nDESCRIPTION:https://zoom.us/j/123456789\n"
        for batch in 0..<10 {
            dates += "RDATE:" + (1...500).map { stamp((batch * 500 + $0) * 60) }.joined(separator: ",") + "\n"
        }
        dates += "END:VEVENT\n"
        for i in 1...2500 {
            let link = i.isMultiple(of: 2) ? "https://meet.google.com/abc-defg-hij" : ""
            let location = i.isMultiple(of: 2) ? "Override room" : ""
            dates += "BEGIN:VEVENT\nUID:overridden\nRECURRENCE-ID:\(stamp(i * 60))\nDTSTART:\(stamp(600))\nSUMMARY:Override \(i)\nLOCATION:\(location)\nDESCRIPTION:\(link)\nEND:VEVENT\n"
        }
        for (name, body, expected) in [("long recurring descriptions", recurring, 7000), ("coincident overrides", dates, 5000)] {
            let began = ProcessInfo.processInfo.systemUptime
            let result = ICSBuilder.meetings(fromICS: calendar(body), subscription: subscription, now: now)
            guard result.error == nil, result.events.count == expected else {
                print("FAIL: \(name): \(result.error ?? "count \(result.events.count)")"); exit(1)
            }
            if name == "coincident overrides" {
                guard result.events.filter({ $0.title.hasPrefix("Override") && $0.link == nil }).count == 1250,
                      result.events.filter({ $0.link?.host == "meet.google.com" }).count == 1250 else {
                    print("FAIL: override links leaked from master"); exit(1)
                }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            // JSON preserves field boundaries, nil versus empty text, and embedded
            // delimiters/newlines. Compare all stored event fields, including the
            // location/notes inheritance that occurrence-content caching affects.
            let fields: [[String?]] = result.events.sorted { $0.id < $1.id }.map {
                [$0.id, $0.uid, $0.notificationIdentity, $0.title,
                 String($0.start.timeIntervalSince1970), String($0.end.timeIntervalSince1970),
                 $0.location, $0.notes, $0.link?.absoluteString, $0.calendarID.uuidString,
                 $0.calendarName, String($0.colorIndex), $0.colorHex, String($0.isMuted)]
            }
            let canonical = try! JSONEncoder().encode(fields)
            let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
            print("\(name): \(result.events.count) events, \(String(format: "%.3f", elapsed))s; digest \(digest)")
        }
    }
}
