import Foundation
import NowCore

extension CoreTests {
    static func multipleReminders(_ check: inout Check) throws {
        let event = modelEvent(calendarID: cacheSubscription.id, identity: "multiple")
        let key = ReminderIdentity.eventKey(event)
        let before = event.start.addingTimeInterval(-600)
        let leads = [0, 300, 600]
        var ledger = ReminderLedger()
        var due = ledger.due(event, leads: leads, now: before)
        check.expect(due.leads == [600], "only first lead due at exact boundary")
        ledger.accept(due, event: event)
        check.expect(ledger.due(event, leads: leads, now: before).isEmpty, "accepted lead stays quiet")
        due = ledger.due(event, leads: leads, now: event.start)
        check.expect(due.leads == [0, 300], "later independent leads coalesce")
        check.expect(ledger.due(event, leads: leads, now: event.end).isEmpty, "exclusive end for every lead")

        ledger.schedule(event, until: event.start.addingTimeInterval(-180), leads: leads)
        check.expect(ledger.due(event, leads: leads, now: event.start.addingTimeInterval(-300)).isEmpty, "snooze silences intermediate lead")
        due = ledger.due(event, leads: leads, now: event.start.addingTimeInterval(-180))
        check.expect(due.leads.isEmpty && due.snoozeToken != nil, "explicit snooze owns its deadline")
        ledger.accept(due, event: event)
        check.expect(ledger.due(event, leads: leads, now: event.start).leads == [0], "regular lead after snooze retained")
        ledger.schedule(event, until: event.start, leads: leads)
        due = ledger.due(event, leads: leads, now: event.start)
        check.expect(due.snoozeToken != nil && due.leads.isEmpty, "at-start collision yields one delivery")
        ledger.join(event)
        for activity: MeetingActivity in [.unknown, .meeting(.zoom), .inactive] {
            check.expect(ledger.suppressAfterJoin(event, detectionEnabled: true, activity: activity) == (activity != .inactive), "Join detection truth table")
            check.expect(ledger.suppressAfterJoin(event, detectionEnabled: false, activity: activity), "disabled detection consumes after Join")
        }
        ledger.accept(due, event: event)
        check.expect(ledger.entries[key]?.snooze != nil, "stale pre-Join acceptance cannot consume snooze")
        ledger.schedule(event, until: event.start, leads: leads)
        check.expect(!ledger.suppressAfterJoin(event, detectionEnabled: false, activity: .unknown), "latest explicit Snooze overrides Join")
        ledger.changeLeads(from: leads, to: [300], at: before)
        check.expect(ledger.due(event, leads: [300], now: event.start).snoozeToken != nil, "Snooze survives removing source lead")

        ledger = try JSONDecoder().decode(ReminderLedger.self, from: JSONEncoder().encode(ledger))
        let moved = modelEvent(calendarID: event.calendarID, start: event.start.addingTimeInterval(7200), identity: event.notificationIdentity)
        ledger.join(event)
        ledger.reconcile(events: [moved], enabled: [event.calendarID], observed: [], now: before,
                         rearmOnReschedule: [key], leads: leads)
        check.expect(ledger.entries[key]?.snooze == moved.start && ledger.entries[key]?.joined == false, "start shift moves snooze and resets Join")
        ledger.reconcile(events: [moved], enabled: [event.calendarID], observed: [], now: before, leads: leads)
        check.expect(ledger.entries[key]?.snooze == moved.start, "same snapshot never shifts twice")
        ledger.reconcile(events: [event], enabled: [event.calendarID], observed: [], now: event.start, leads: leads)
        check.expect(ledger.due(event, leads: leads, now: event.start).snoozeToken != nil, "moving earlier catches up once")
        ledger.accept(ledger.due(event, leads: leads, now: event.start), event: event)
        check.expect(ledger.due(event, leads: leads, now: event.start).isEmpty, "caught-up snooze consumed")

        ledger = ReminderLedger()
        ledger.changeLeads(from: [300], to: leads, at: event.start.addingTimeInterval(-480))
        check.expect(ledger.due(event, leads: leads, now: event.start).leads == [0, 300], "settings edit skips already-passed added lead")
        ledger = try JSONDecoder().decode(ReminderLedger.self, from: JSONEncoder().encode(ledger))
        check.expect(ledger.due(event, leads: leads, now: event.start).leads == [0, 300], "cutoff survives restart and previously unloaded event")
        ledger.record(event, snooze: event.start)
        ledger.reconcile(events: [event], enabled: [event.calendarID], observed: [], now: before, leads: [300])
        check.expect(ledger.entries[key]?.handledLeads == [300] && ledger.entries[key]?.snoozeToken != nil, "legacy ledger migrates singleton and snooze")
        var unmuted = ReminderLedger()
        unmuted.schedule(event, until: event.start, leads: [])
        ReminderReconciliation.ratchetSilence(previousMutedByID: [event.id: true], current: [event],
            ledger: &unmuted, leads: leads, now: before)
        check.expect(unmuted.entries[key]?.handledLeads == [600] && unmuted.entries[key]?.snooze == nil,
                     "multi-lead unmute clears Snooze and handles only already-due lead")
        check.expect(unmuted.due(event, leads: leads, now: event.start).leads == [0, 300], "multi-lead unmute preserves future reminders")
        try multipleReminderSettings(&check)
    }

    private static func multipleReminderSettings(_ check: inout Check) throws {
        let audit = PreferenceDecoding()
        let decoder = JSONDecoder(); decoder.userInfo[PreferenceDecoding.key] = audit
        let legacy = try decoder.decode(AppSettings.self, from: Data("{\"leadSeconds\":37}".utf8))
        check.expect(legacy.reminderLeadSeconds == [37] && !audit.recovered, "healthy scalar migrates without recovery")
        var settings = AppSettings()
        settings.reminderLeadSeconds = [600, 0, 300, 300]
        check.expect(settings.reminderLeadSeconds == [0, 300, 600] && settings.snoozeSeconds == 0, "mixed zero preserves at-start default")
        let preferred = try decoder.decode(AppSettings.self, from: Data("{\"reminderLeadSeconds\":[0,300],\"leadSeconds\":\"obsolete\"}".utf8))
        check.expect(preferred.reminderLeadSeconds == [0, 300] && !audit.recovered, "new list takes precedence over obsolete scalar")
        let saved = try JSONEncoder().encode(settings)
        let roundtrip = try decoder.decode(AppSettings.self, from: saved)
        check.expect(roundtrip == settings, "multiple settings roundtrip")
        let wire = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        check.expect(wire["leadSeconds"] as? Int == 600, "legacy scalar retained for rollback")
        settings.reminderLeadSeconds = []
        check.expect(settings.reminderLeadSeconds == [300], "empty live settings normalize")
        settings.reminderLeadSeconds = [0]
        check.expect(settings.snoozeSeconds == 60, "singleton-zero retains safe snooze default")
        _ = try decoder.decode(AppSettings.self, from: Data("{\"reminderLeadSeconds\":[],\"soundEnabled\":false}".utf8))
        check.expect(audit.recovered, "damaged empty list signals recovery")
    }
}
