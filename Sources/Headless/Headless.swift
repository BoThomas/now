import Foundation
import NowCore

@main enum HeadlessMain {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let mode = arguments.first else {
            print("usage: now-headless selftest | run --root DIR [--once | --duration N] [--wait-reminders N] [--snooze-after N]")
            return
        }
        arguments.removeFirst()
        switch mode {
        case "selftest": await SelfTest.run()
        case "run": await runCLI(arguments)
        default: print("unknown mode: \(mode)"); exit(2)
        }
    }

    static func runCLI(_ arguments: [String]) async {
        var root: URL?
        var once = false
        var duration: TimeInterval = 0
        var waitReminders = 0
        var snoozeAfter: Int?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--root": index += 1; root = arguments[safe: index].map { URL(fileURLWithPath: $0) }
            case "--once": once = true
            case "--duration": index += 1; duration = TimeInterval(arguments[safe: index] ?? "") ?? 0
            case "--wait-reminders": index += 1; waitReminders = Int(arguments[safe: index] ?? "") ?? 0
            case "--snooze-after": index += 1; snoozeAfter = Int(arguments[safe: index] ?? "")
            default: break
            }
            index += 1
        }
        guard let root else { print("missing --root"); exit(2) }
        let store = HeadlessStore(root: root)
        if once { await store.runOnce(waitForReminders: waitReminders, snoozeAfter: snoozeAfter) }
        else { await store.run(duration: max(duration, 1)) }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Deterministic Linux validation of the probe shell: portable link discovery,
/// file preferences/ledger recovery, feed materialization, merge retention,
/// offline restore, reminder/snooze/catch-up policy through the loop, real
/// cross-process restarts, and a bounded live-timer pass.
enum SelfTest {
    struct Check {
        var count = 0
        var failures: [String] = []
        mutating func expect(_ value: Bool, _ label: String) {
            count += 1
            if !value { failures.append(label) }
        }
    }

    static func run() async {
        var check = Check()
        portableLinks(&check)
        await preferencesAndLedgerFiles(&check)
        do {
            try await feedAndMaterialize(&check)
            try await reminderLifecycle(&check)
            try await rescheduleAndFailure(&check)
            try await offlineRestore(&check)
            try crossProcessRestart(&check)
            try liveTimer(&check)
        } catch {
            check.expect(false, "scenario fixture failed: \(error)")
        }
        if !check.failures.isEmpty {
            for failure in check.failures { print("FAIL: \(failure)") }
            exit(1)
        }
        print("HEADLESS PROBE OK — \(check.count) checks; portable links, file prefs/ledger, fetch/merge, offline restore, reminder loop, restart persistence, live timers")
    }

    // MARK: Fixtures

    static func calendar(_ body: String) -> String {
        "BEGIN:VCALENDAR\nVERSION:2.0\n" + body + "\nEND:VCALENDAR\n"
    }

    static func event(_ uid: String, _ properties: String) -> String {
        "BEGIN:VEVENT\nUID:\(uid)\n" + properties + "\nEND:VEVENT"
    }

    static func instant(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value) ?? Date()
    }

    static func icsStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    static func tempRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-headless-selftest-\(label)-" + UUID().uuidString)
        try? FileManager.default.removeItem(at: root)
        return root
    }

    static func writeFeed(_ text: String, to root: URL) throws -> URL {
        let url = root.appendingPathComponent("feed.ics")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.data(using: .utf8)?.write(to: url)
        return url
    }

    static func makeStore(_ root: URL, _ clock: ManualClock) -> HeadlessStore {
        HeadlessStore(root: root, clock: { clock.date() }, logging: { _ in })
    }

    static func configure(_ store: HeadlessStore, subscription: CalendarSubscription? = nil,
                          leads: [Int] = [300]) async {
        var prefs = await store.prefs
        if let subscription { prefs.subscriptions = [subscription] }
        prefs.settings.reminderLeadSeconds = leads
        await store.setPreferences(prefs)
    }

    static func runChild(_ arguments: [String]) throws -> (lines: [String], status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (text.split(separator: "\n").map(String.init), process.terminationStatus)
    }

    static func writePreferences(_ preferences: Persisted, to root: URL) {
        if let data = try? JSONEncoder().encode(preferences) {
            HeadlessFile.write(data, to: root.appendingPathComponent("preferences.json"))
        }
    }

    // MARK: Scenarios

    static func portableLinks(_ check: inout Check) {
        let zoom = URL(string: "https://zoom.us/j/123?pwd=abc")!
        let docs = URL(string: "https://example.invalid/document")!
        let meet = URL(string: "https://meet.google.com/abc-defg-hij")!
        let found = PortableLinkDetector.urls(inText: "Join \(zoom.absoluteString), or docs \(docs.absoluteString).")
        check.expect(found.first == zoom && found.contains(docs), "detector finds links and trims sentence punctuation")
        check.expect(PortableLinkDetector.urls(inText: "(link: \(meet.absoluteString))") == [meet], "parenthesized link extracted clean")
        check.expect(PortableLinkDetector.urls(inText: "go https://zoom.us/j/9?pwd=a&amp;b now").contains(URL(string: "https://zoom.us/j/9?pwd=a&b")!),
                     "entity-encoded query decoded")
        check.expect(PortableLinkDetector.urls(inText: "no links, just words (ftp://x.invalid too)") == [], "no candidates from plain or non-http text")
        check.expect(PortableLinkDetector.urls(inText: String(repeating: "x", count: 200_000)).isEmpty, "oversized text bounded")
        guard var item = ICSParser.parse(calendar(event("l1", "DTSTART:20270310T100000Z"))).events.first else {
            check.expect(false, "link fixture parses"); return
        }
        item.location = "room"
        item.description = "see \(docs.absoluteString) or \(zoom.absoluteString)"
        check.expect(LinkExtractor.link(from: item, urlsInText: PortableLinkDetector.urls(inText:)) == zoom,
                     "location candidates rank ahead of description via core selection")
        item.conference = docs.absoluteString
        check.expect(LinkExtractor.link(from: item, urlsInText: PortableLinkDetector.urls(inText:)) == docs,
                     "explicit conference stays authoritative")
        item.conference = nil
        item.description = "only \(docs.absoluteString)"
        check.expect(LinkExtractor.link(from: item, urlsInText: PortableLinkDetector.urls(inText:)) == nil,
                     "no arbitrary web-link fallback through the portable detector")
    }

    static func preferencesAndLedgerFiles(_ check: inout Check) async {
        let base = instant("2027-03-10T09:00:00Z")
        let root = (try? tempRoot("prefs")) ?? FileManager.default.temporaryDirectory
        let feed = root.appendingPathComponent("feed.ics").absoluteString
        let store = makeStore(root, ManualClock(base))
        await configure(store, subscription: CalendarSubscription(name: "Work", url: feed, colorIndex: 2, colorHex: ""), leads: [30, 300])
        let reloaded = makeStore(root, ManualClock(base.addingTimeInterval(5)))
        let report = await reloaded.loadState()
        let prefs = await reloaded.prefs
        check.expect(prefs.subscriptions.count == 1 && prefs.subscriptions.first?.url == feed, "preferences round-trip keeps subscriptions")
        check.expect(prefs.settings.reminderLeadSeconds == [30, 300], "settings leads round-trip")
        check.expect(!report.preferencesRecovered, "clean load reports no recovery")
        check.expect(HeadlessFile.permissions(of: root.appendingPathComponent("preferences.json")) == 0o600, "preferences file private")
        let damaged = """
        {"subscriptions":[{"id":"11111111-1111-1111-1111-111111111111","name":"Kept","url":"file:///feed.ics"}],"settings":{"refreshMinutes":"soon"}}
        """
        try? damaged.data(using: .utf8)?.write(to: root.appendingPathComponent("preferences.json"))
        let recovered = makeStore(root, ManualClock(base))
        let damagedReport = await recovered.loadState()
        let damagedPrefs = await recovered.prefs
        check.expect(damagedPrefs.subscriptions.first?.name == "Kept" && damagedPrefs.settings.refreshMinutes == 15,
                     "damaged field recovers its default, siblings survive")
        check.expect(damagedReport.preferencesRecovered, "recovery audited")
        var ledger = ReminderLedger()
        let keptID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        ledger.record(MeetingEvent(uid: "x", title: "T", start: base, end: base.addingTimeInterval(600), location: nil,
                                   notes: nil, link: nil, calendarID: keptID, calendarName: "Kept", colorIndex: 0, colorHex: "#fff"),
                      snooze: base.addingTimeInterval(60))
        if let data = try? JSONEncoder().encode(ledger) {
            HeadlessFile.write(data, to: root.appendingPathComponent("ledger.json"))
        }
        let ledgerStore = makeStore(root, ManualClock(base))
        _ = await ledgerStore.loadState()
        let loadedLedger = await ledgerStore.ledger
        check.expect(loadedLedger.entries.count == 1 && loadedLedger.entries.values.first?.snooze == base.addingTimeInterval(60),
                     "ledger round-trips through disk")
        check.expect(HeadlessFile.permissions(of: root.appendingPathComponent("ledger.json")) == 0o600, "ledger file private")
        try? Data("not json".utf8).write(to: root.appendingPathComponent("ledger.json"))
        let corrupt = makeStore(root, ManualClock(base))
        let corruptReport = await corrupt.loadState()
        let corruptLedger = await corrupt.ledger
        check.expect(corruptReport.ledgerRecovered && corruptLedger.entries.isEmpty, "corrupt ledger resets like the macOS defaults store")
        try? FileManager.default.removeItem(at: root)
    }

    static func feedAndMaterialize(_ check: inout Check) async throws {
        let base = instant("2027-03-10T09:00:00Z")
        let clock = ManualClock(base)
        let root = try tempRoot("feed")
        let zoom = URL(string: "https://zoom.us/j/42?pwd=z")!
        let meet = URL(string: "https://meet.google.com/aaa-bbb-ccc")!
        let feed = try writeFeed(calendar([
            event("e1", "DTSTART:20270310T091000Z\nDURATION:PT30M\nSUMMARY:Design sync\nDESCRIPTION:Join \(zoom.absoluteString) early"),
            event("e2", "DTSTART:20270310T093000Z\nDURATION:PT15M\nSUMMARY:Standup\nLOCATION:\(meet.absoluteString)"),
            event("e3", "DTSTART:20270301T100000Z\nDURATION:PT30M\nSUMMARY:Old")
        ].joined(separator: "\n")), to: root)
        let store = makeStore(root, clock)
        var subscription = CalendarSubscription(name: "Work", url: feed.absoluteString, colorIndex: 1, colorHex: "")
        subscription.titleFilters = [TitleFilterRule(pattern: "standup", mode: .exact)]
        await configure(store, subscription: subscription)
        _ = await store.startup()
        let events = await store.events
        check.expect(events.count == 2, "events outside the 6h/14d window drop; two materialize")
        check.expect(events.first { $0.uid == "e1" }?.link == zoom, "zoom link discovered from description text")
        check.expect(events.first { $0.uid == "e2" }?.link == meet, "meet link discovered from location")
        check.expect(events.first { $0.uid == "e2" }?.isMuted == true, "title filter mutes without hiding")
        check.expect(events.allSatisfy { $0.colorHex == HeadlessPalette.hex(for: 1) }, "palette injected decoder-locally")
        check.expect((await store.errors).isEmpty, "successful feed reports no errors")
        try? FileManager.default.removeItem(at: root)
    }

    static func reminderLifecycle(_ check: inout Check) async throws {
        let base = instant("2027-03-10T09:00:00Z")
        let clock = ManualClock(base)
        let root = try tempRoot("loop")
        let feed = try writeFeed(calendar(event("r1", "DTSTART:20270310T091000Z\nDURATION:PT30M\nSUMMARY:Loop sync")), to: root)
        let store = makeStore(root, clock)
        await configure(store, subscription: CalendarSubscription(name: "W", url: feed.absoluteString, colorIndex: 0, colorHex: ""))
        _ = await store.startup()
        await store.tick()
        check.expect((await store.deliveries).isEmpty, "no reminder before the lead fires")
        clock.advance(301)
        await store.tick()
        check.expect((await store.deliveries).filter { $0.hasPrefix("REMINDER") && $0.contains("fullscreen") }.count == 1,
                     "lead fires one fullscreen reminder")
        await store.tick()
        check.expect((await store.deliveries).count == 1, "handled reminder never refires")
        await store.snoozeDelivered(seconds: 120)
        clock.advance(30)
        await store.tick()
        check.expect((await store.deliveries).count == 1, "snoozed reminder stays quiet")
        let joined = await store.join(eventID: (await store.events).first!.id)
        check.expect(joined, "join recorded")
        clock.advance(95)
        await store.tick()
        check.expect((await store.deliveries).count == 1, "join suppresses the expired snooze")
        await store.pause(seconds: 600)
        clock.advance(300)
        await store.tick()
        check.expect((await store.deliveries).count == 1, "pause blocks delivery while agenda stays usable")
        await store.resume()
        check.expect(await !store.isPaused, "resume clears pause")
        try? FileManager.default.removeItem(at: root)
    }

    static func rescheduleAndFailure(_ check: inout Check) async throws {
        let base = instant("2027-03-10T09:00:00Z")
        let clock = ManualClock(base)
        let root = try tempRoot("reschedule")
        let feed = try writeFeed(calendar(event("m1", "DTSTART:20270310T091000Z\nDURATION:PT30M\nSUMMARY:Moving sync")), to: root)
        let store = makeStore(root, clock)
        let subscription = CalendarSubscription(name: "W", url: feed.absoluteString, colorIndex: 0, colorHex: "")
        await configure(store, subscription: subscription)
        _ = await store.startup()
        clock.advance(301)
        await store.tick()
        check.expect((await store.deliveries).count == 1, "first occurrence alerts")
        _ = try writeFeed(calendar(event("m1", "DTSTART:20270310T094000Z\nDURATION:PT30M\nSUMMARY:Moving sync")), to: root)
        await store.refresh()
        clock.advance(1800)
        await store.tick()
        check.expect((await store.deliveries).count == 2, "rescheduled occurrence re-arms its reminder")
        var prefs = await store.prefs
        prefs.subscriptions[0].url = root.appendingPathComponent("missing.ics").absoluteString
        await store.setPreferences(prefs)
        await store.refresh()
        check.expect((await store.events).count == 1, "failed feed retains the accepted snapshot")
        check.expect((await store.errors).count == 1, "failure records a source error")
        var disabled = await store.prefs
        disabled.subscriptions[0].isEnabled = false
        await store.setPreferences(disabled)
        await store.refresh()
        check.expect((await store.events).isEmpty, "disabled calendar drops its events")
        try? FileManager.default.removeItem(at: root)
    }

    static func offlineRestore(_ check: inout Check) async throws {
        let base = instant("2027-03-10T09:00:00Z")
        let clock = ManualClock(base)
        let root = try tempRoot("offline")
        let feed = try writeFeed(calendar(event("o1", "DTSTART:20270310T100000Z\nDURATION:PT30M\nSUMMARY:Offline sync")), to: root)
        let subscription = CalendarSubscription(name: "W", url: feed.absoluteString, colorIndex: 0, colorHex: "")
        let store = makeStore(root, clock)
        await configure(store, subscription: subscription)
        _ = await store.startup()
        try FileManager.default.removeItem(at: feed)
        let offline = makeStore(root, ManualClock(base.addingTimeInterval(60)))
        await configure(offline, subscription: subscription)
        let report = await offline.startup()
        check.expect(report.restoredEvents == 1, "cache snapshot restores the agenda")
        check.expect((await offline.events).count == 1, "failed refresh keeps restored events")
        check.expect((await offline.errors).count == 1, "missing feed surfaces an error, not an empty success")
        check.expect((await offline.agenda()).count == 1, "restored event still actionable")
        try? FileManager.default.removeItem(at: root)
    }

    static func crossProcessRestart(_ check: inout Check) throws {
        let wall = Date()
        let root = try tempRoot("restart")
        let feed = try writeFeed(calendar([
            event("p1", "DTSTART:\(icsStamp(wall.addingTimeInterval(45)))\nDURATION:PT30M\nSUMMARY:Alpha"),
            event("p2", "DTSTART:\(icsStamp(wall.addingTimeInterval(45)))\nDURATION:PT30M\nSUMMARY:Beta")
        ].joined(separator: "\n")), to: root)
        var settings = AppSettings()
        settings.reminderLeadSeconds = [30]
        writePreferences(Persisted(subscriptions: [CalendarSubscription(name: "W", url: feed.absoluteString, colorIndex: 0, colorHex: "")],
                                   settings: settings), to: root)
        let first = try runChild(["run", "--root", root.path, "--once", "--wait-reminders", "2", "--snooze-after", "3600"])
        check.expect(first.status == 0, "first child exits cleanly")
        check.expect(first.lines.filter { $0.hasPrefix("REMINDER") }.count == 2, "both due meetings alert in the child")
        check.expect(first.lines.filter { $0.hasPrefix("SNOOZED") }.count == 2, "alerted meetings snooze through SnoozePolicy")
        let second = try runChild(["run", "--root", root.path, "--once"])
        check.expect(second.status == 0, "second child exits cleanly")
        check.expect(second.lines.filter { $0.hasPrefix("REMINDER") }.isEmpty && second.lines.filter { $0.hasPrefix("CATCHUP") }.isEmpty,
                     "handled and snoozed state survives a real process restart")
        let catchUpRoot = try tempRoot("catchup")
        let running = try writeFeed(calendar(event("c1", "DTSTART:\(icsStamp(wall.addingTimeInterval(-60)))\nDURATION:PT15M\nSUMMARY:Already running")), to: catchUpRoot)
        var catchUpSettings = AppSettings()
        catchUpSettings.reminderLeadSeconds = [30]
        catchUpSettings.notifyOnCatchUp = true
        writePreferences(Persisted(subscriptions: [CalendarSubscription(name: "W", url: running.absoluteString, colorIndex: 0, colorHex: "")],
                                   settings: catchUpSettings), to: catchUpRoot)
        let third = try runChild(["run", "--root", catchUpRoot.path, "--once", "--wait-reminders", "1"])
        check.expect(third.lines.contains { $0.hasPrefix("CATCHUP") }, "running meeting routes as catch-up after launch")
        let fourth = try runChild(["run", "--root", catchUpRoot.path, "--once"])
        check.expect(fourth.lines.filter { $0.hasPrefix("CATCHUP") }.isEmpty, "catch-up delivery handled across restart")
        check.expect(HeadlessFile.permissions(of: root.appendingPathComponent("ledger.json")) == 0o600, "restart ledger private")
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: catchUpRoot)
    }

    static func liveTimer(_ check: inout Check) throws {
        let wall = Date()
        let root = try tempRoot("live")
        let feed = try writeFeed(calendar(event("t1", "DTSTART:\(icsStamp(wall.addingTimeInterval(6)))\nDURATION:PT10M\nSUMMARY:Live sync")), to: root)
        var settings = AppSettings()
        settings.reminderLeadSeconds = [5]
        writePreferences(Persisted(subscriptions: [CalendarSubscription(name: "W", url: feed.absoluteString, colorIndex: 0, colorHex: "")],
                                   settings: settings), to: root)
        let child = try runChild(["run", "--root", root.path, "--duration", "8"])
        check.expect(child.status == 0, "live child exits cleanly")
        check.expect(child.lines.filter { $0.hasPrefix("REMINDER") }.count == 1, "one-second tick loop delivers the live reminder")
        check.expect(child.lines.contains { $0.hasPrefix("DONE") }, "bounded duration run terminates")
        try? FileManager.default.removeItem(at: root)
    }
}
