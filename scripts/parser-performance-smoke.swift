import Foundation
import CryptoKit

// Models use this fixed palette of sound names only for settings decoding.
// No AppStore/EventKit instance is linked into this parser benchmark.
enum AppStore { static let soundNames = ["Hero"] }

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
            "BEGIN:VEVENT\nUID:master-\(i)\nDTSTART:\(stamp(60))\nDURATION:PT30M\nRRULE:FREQ=DAILY;COUNT=14\nSUMMARY:Recurring\nDESCRIPTION:\(description)\nEND:VEVENT\n"
        }.joined()
        var dates = "BEGIN:VEVENT\nUID:overridden\nDTSTART:\(stamp(60))\nDURATION:PT30M\nSUMMARY:Master\nDESCRIPTION:https://zoom.us/j/123456789\n"
        for batch in 0..<10 {
            dates += "RDATE:" + (1...500).map { stamp((batch * 500 + $0) * 60) }.joined(separator: ",") + "\n"
        }
        dates += "END:VEVENT\n"
        for i in 1...2500 {
            let link = i.isMultiple(of: 2) ? "https://meet.google.com/abc-defg-hij" : ""
            dates += "BEGIN:VEVENT\nUID:overridden\nRECURRENCE-ID:\(stamp(i * 60))\nDTSTART:\(stamp(600))\nSUMMARY:Override \(i)\nDESCRIPTION:\(link)\nEND:VEVENT\n"
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
            let canonical = result.events.map { "\($0.id)|\($0.title)|\($0.start.timeIntervalSince1970)|\($0.end.timeIntervalSince1970)|\($0.link?.absoluteString ?? "")" }.sorted().joined(separator: "\n")
            let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
            print("\(name): \(result.events.count) events, \(String(format: "%.3f", elapsed))s; digest \(digest)")
        }
    }
}
