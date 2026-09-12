import Foundation
import NowCore
import AppKit

extension SelfTest {
    static func readinessTests(_ c: inout Checker) {
        var termination = TerminationRequestGate()
        let oldQuit = termination.begin()
        c.expect(termination.cancel() && !termination.finish(oldQuit), "readiness: cancelled update quit ignores late disk-barrier reply")
        let newQuit = termination.begin()
        c.expect(!termination.finish(oldQuit) && termination.finish(newQuit), "readiness: newer quit owns its own completion")
        let date = ISO8601DateFormatter().date(from: "2026-09-09T12:00:00Z")!
        let sub = CalendarSubscription(name: "Readiness", url: "https://example.invalid", colorIndex: 0)
        let master = """
        BEGIN:VEVENT
        UID:collision
        SUMMARY:Regular
        LOCATION:Old room
        DESCRIPTION:https://zoom.us/j/123
        DTSTART:20260910T100000Z
        DURATION:PT1H
        RRULE:FREQ=DAILY;COUNT=2
        END:VEVENT
        """
        let moved = """
        BEGIN:VEVENT
        UID:collision
        RECURRENCE-ID:20260910T100000Z
        DTSTART:20260911T100000Z
        SUMMARY:Moved
        LOCATION:
        DESCRIPTION:
        DURATION:PT30M
        END:VEVENT
        """
        func build(_ body: String) -> ICSBuildResult {
            ICSBuilder.meetings(fromICS: "BEGIN:VCALENDAR\nVERSION:2.0\n" + body + "\nEND:VCALENDAR\n", subscription: sub, now: date)
        }
        for text in [master + "\n" + moved, moved + "\n" + master] {
            let result = build(text)
            c.expect(result.error == nil && result.events.count == 2, "readiness: coincident recurring siblings survive either input order")
            c.expect(AppStore.normalizedEvents(result.events).count == 2, "readiness: agenda keeps both coincident occurrences")
            c.expect(Set(result.events.map(\.id)).count == 2 && Set(result.events.map(NotificationLogic.eventKey)).count == 2, "readiness: distinct agenda and notification identities")
            let edited = result.events.first { $0.title == "Moved" }
            c.expect(edited.map { $0.end.timeIntervalSince($0.start) } == 1800, "readiness: moved duration retained")
            c.expect(edited?.location == "" && edited?.notes == "" && edited?.link == nil, "readiness: explicit clears do not revive room, notes or old Join link")
            var ambiguous = ReminderLedger()
            if let first = result.events.first {
                ambiguous.entries[NotificationLogic.key(first.legacyID)] = .init(calendarID: sub.id, end: first.end)
                ambiguous.reconcile(events: result.events, enabled: [sub.id], observed: [], now: date)
                c.expect(result.events.allSatisfy { ambiguous.entries[NotificationLogic.eventKey($0)] == nil }, "readiness: ambiguous legacy acknowledgement never assigned to an arbitrary sibling")
                ambiguous.reconcile(events: [first], enabled: [sub.id], observed: [], now: date)
                c.expect(ambiguous.entries[NotificationLogic.eventKey(first)] == nil, "readiness: formerly ambiguous acknowledgement cannot migrate to a later survivor")
            }
        }
        let original = build(master).events[0]
        var ledger = ReminderLedger()
        let deadline = original.start.addingTimeInterval(60)
        ledger.entries[NotificationLogic.key(original.legacyID)] = .init(calendarID: sub.id, end: original.end, snooze: deadline)
        ledger.reconcile(events: [original], enabled: [sub.id], observed: [], now: date)
        c.expect(ledger.entries[NotificationLogic.eventKey(original)]?.snooze == deadline, "readiness: unambiguous pre-v2 agenda key preserves snooze")
        let retained = build(master + "\n" + moved.replacingOccurrences(of: "LOCATION:\nDESCRIPTION:\n", with: "")).events.first { $0.title == "Moved" }
        c.expect(retained?.location == "Old room" && retained?.link != nil, "readiness: truly omitted fields still inherit")
        let emptyTitle = build(master + "\n" + moved.replacingOccurrences(of: "SUMMARY:Moved", with: "SUMMARY:")).events.first { $0.title.isEmpty }
        c.expect(emptyTitle != nil, "readiness: explicitly empty summary stays empty")
        // The second override must target its anchor, never another moved sibling's new start.
        let excludedMaster = master.replacingOccurrences(of: "RRULE:FREQ=DAILY;COUNT=2", with: "RRULE:FREQ=DAILY;COUNT=2\nEXDATE:20260911T100000Z")
        let other = "BEGIN:VEVENT\nUID:collision\nRECURRENCE-ID:20260911T100000Z\nDTSTART:20260911T110000Z\nSUMMARY:Other\nEND:VEVENT"
        let crossed = build(excludedMaster + "\n" + moved.replacingOccurrences(of: "SUMMARY:Moved", with: "SUMMARY:Moved\nSEQUENCE:2") + "\n" + other)
        c.expect(Set(crossed.events.map(\.title)) == ["Moved", "Other"], "readiness: override removal matches original anchor even with EXDATE")

        let start = "DTSTART;TZID=Pacific/Honolulu:20260910T100000"
        let end = "DTEND:20260910T230000"
        let prefix = "BEGIN:VEVENT\nUID:order\n"
        let suffix = "\nEND:VEVENT"
        let forward = build(prefix + start + "\n" + end + suffix).events
        let reverse = build(prefix + end + "\n" + start + suffix).events
        c.expect(forward.first?.end == reverse.first?.end, "readiness: timezone-less DTEND independent of property order")
        for property in ["EXDATE;VALUE=DATE:20260910", "RDATE;VALUE=DATE:20260911"] {
            let result = build(master.replacingOccurrences(of: "END:VEVENT", with: property + "\nEND:VEVENT"))
            c.expect(result.events.count == 2 && !result.warnings.isEmpty, "readiness: DATE on timed series warns without silently adding midnight meetings")
        }
        for key in ["leadSeconds", "refreshMinutes", "soundEnabled", "soundName", "showMenuBarCountdown", "launchAtLogin", "snoozeSeconds", "skippedUpdateVersion"] {
            let object: [String: Any] = [key: ["invalid"], "notifySyncErrors": true, "menuMeetingLimit": 15]
            let data = try! JSONSerialization.data(withJSONObject: object)
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
            c.expect(settings?.notifySyncErrors == true && settings?.menuMeetingLimit == 15, "readiness: malformed \(key) preserves unrelated preferences")
        }
        let native = NativeCalendar(ekIdentifier: "test", name: "Test")
        var duplicateNative = native
        duplicateNative.id = sub.id
        let payload = Persisted(subscriptions: [sub, sub], nativeCalendars: [duplicateNative, native, native])
        let decoded = try? AppModelCoding.decoder().decode(Persisted.self, from: JSONEncoder().encode(payload))
        c.expect(decoded?.subscriptions.count == 1 && decoded?.nativeCalendars.count == 1 && decoded?.nativeCalendars.first?.id == native.id, "readiness: source decode removes duplicate IDs across both kinds")
        var guides = FeatureGuideState()
        let pending = guides.acknowledge(catalog: FeatureGuideCatalog.entries, installedUpdate: true)
        var restored = try! JSONDecoder().decode(FeatureGuideState.self, from: JSONEncoder().encode(guides))
        c.expect(restored.acknowledge(catalog: FeatureGuideCatalog.entries, installedUpdate: false) == pending, "readiness: never-shown guide survives ordinary restart")
        restored.pendingPresentation.subtract(pending)
        c.expect(restored.acknowledge(catalog: FeatureGuideCatalog.entries, installedUpdate: true).isEmpty, "readiness: displayed guide does not repeat")
        c.expect(AlertController.keyAction(modifiers: .numericPad, keyCode: 83, characters: "1", snoozeable: true, hasFocusedControl: false) == .joinIndex(1), "readiness: keypad digit joins card")
        c.expect(AlertController.keyAction(modifiers: .numericPad, keyCode: 76, characters: "\r", snoozeable: true, hasFocusedControl: false) == .joinOrClose, "readiness: keypad Enter joins")
        c.expect(AlertController.keyAction(modifiers: [.command, .numericPad], keyCode: 83, characters: "1", snoozeable: true, hasFocusedControl: false) == .passThrough, "readiness: modified keypad digit remains guarded")
    }
}
