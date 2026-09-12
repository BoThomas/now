import Foundation
import NowCore

extension CoreTests {
    static func ledgerLifecycle(_ check: inout Check) throws {
        let item = modelEvent(calendarID: cacheSubscription.id, identity: "ics:3:uid:1800000000.0")
        let key = ReminderIdentity.eventKey(item)
        check.expect(key == "e854cb9d208cec30d1511a16bdfd7211c9cb1b783020395540b37ede788ca7c8", "persisted occurrence hash matches independent vector")
        check.expect(ReminderIdentity.legacyFingerprint(item) == "a1e56280b92c2d481ba60ec04a1e9e38d9251546481bc3d27747da442fe7ba16", "legacy fingerprint bytes preserved")
        check.expect(ReminderIdentity.priorAgendaFingerprint(item) == "d62347b019e718fa586d203547c9c3f7e4b8bff6a2d142d9d3667fa759d30024", "prior fingerprint bytes preserved")
        check.expect(ReminderIdentity.fingerprint(item) == "3ca38adb44dd47096f70ad59a0d2b022c571a5681f7bce95d226cad16a9076ca", "current fingerprint bytes preserved")
        check.expect(NotificationLogic.eventKey(item) == key && NotificationLogic.fingerprint(item) == ReminderIdentity.fingerprint(item), "shell compatibility API delegates to shared identity")
        var ledger = ReminderLedger(); ledger.record(item)
        let encoded = try JSONEncoder().encode(ledger)
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let entries = json["entries"] as! [String: [String: Any]]
        check.expect(Set(entries[key]!.keys) == ["calendarID", "end", "start", "misses"], "ledger stores only existing timing/ownership keys")
        ledger = try JSONDecoder().decode(ReminderLedger.self, from: encoded)
        let enabled: Set<UUID> = [item.calendarID]
        ledger.reconcile(events: [], enabled: enabled, observed: [], now: item.start)
        check.expect(ledger.entries[key]?.misses == 0, "failed/unobserved refresh cannot age ledger")
        ledger.reconcile(events: [], enabled: enabled, observed: [UUID()], now: item.start)
        check.expect(ledger.entries[key]?.misses == 0, "unrelated calendar cannot age ledger")
        ledger.reconcile(events: [], enabled: enabled, observed: enabled, now: item.start)
        check.expect(ledger.entries[key]?.misses == 1, "first successful omission retained")
        ledger.reconcile(events: [item], enabled: enabled, observed: enabled, now: item.start)
        check.expect(ledger.entries[key]?.misses == 0, "returning occurrence resets omission")
        ledger.reconcile(events: [], enabled: enabled, observed: enabled, now: item.start)
        ledger.reconcile(events: [], enabled: enabled, observed: enabled, now: item.start)
        check.expect(ledger.entries.isEmpty, "second consecutive source omission retires ledger")

        ledger.record(item)
        let moved = modelEvent(calendarID: item.calendarID, start: item.start.addingTimeInterval(600), identity: item.notificationIdentity)
        let rearmed = ledger.reconcile(events: [moved], enabled: enabled, observed: enabled, now: item.start,
                                       rearmOnReschedule: [key], previousEvents: [item])
        check.expect(rearmed == [item.id, moved.id] && ledger.entries.isEmpty, "fullscreen reschedule clears both old/new handled IDs")
        ledger.record(item, snooze: item.start.addingTimeInterval(60))
        check.expect(ledger.reconcile(events: [moved], enabled: enabled, observed: enabled, now: item.start,
                                      rearmOnReschedule: [key], previousEvents: [item]).isEmpty, "explicit snooze owns rescheduled occurrence")
        check.expect(ledger.entries[key]?.snooze == item.start.addingTimeInterval(60), "reschedule preserves explicit snooze time")
        ledger.record(item)
        ledger.reconcile(events: [moved], enabled: enabled, observed: enabled, now: item.start, previousEvents: [item])
        check.expect(ledger.entries[key] != nil, "receipt-owned occurrence excluded from fullscreen rearm")

        let legacy = "{\"entries\":{\"\(ReminderIdentity.key(item.legacyID))\":{\"calendarID\":\"\(item.calendarID)\",\"end\":821696400,\"misses\":0}}}"
        ledger = try JSONDecoder().decode(ReminderLedger.self, from: Data(legacy.utf8))
        ledger.reconcile(events: [item], enabled: enabled, observed: enabled, now: item.start)
        check.expect(ledger.entries[key]?.start == item.start && ledger.entries.count == 1, "legacy entry migrates only on an exact occurrence")
        ledger = try JSONDecoder().decode(ReminderLedger.self, from: Data(legacy.utf8))
        let sibling = modelEvent(calendarID: item.calendarID, identity: "ics:3:uid:1800086400.0")
        ledger.reconcile(events: [item, sibling], enabled: enabled, observed: enabled, now: item.start)
        check.expect(ledger.entries.isEmpty, "ambiguous legacy key is not assigned to a moved sibling")
        ledger.record(item); ledger.reconcile(events: [item], enabled: enabled, observed: [], now: item.end)
        check.expect(ledger.entries.isEmpty, "ledger expires at exclusive end")
        ledger.record(item); ledger.invalidate(enabled)
        check.expect(ledger.entries.isEmpty, "explicit source invalidation clears ledger")
    }

    static func reminderDecisions(_ check: inout Check) {
        let item = modelEvent(calendarID: cacheSubscription.id)
        for (offset, expected) in [(-301.0, false), (-300.0, true), (0.0, true), (3599.0, true), (3600.0, false)] {
            let now = item.start.addingTimeInterval(offset)
            check.expect(!ReminderTiming.dueForAlert(events: [item], alerted: [], snoozed: [:], leadSeconds: 300, now: now).isEmpty == expected, "lead/end delivery boundary \(offset)")
            check.expect(ReminderTiming.joinHandlesReminder(item, leadSeconds: 300, now: now) == expected, "join acknowledgement boundary \(offset)")
        }
        check.expect(ReminderTiming.dueForAlert(events: [item], alerted: [item.id], snoozed: [:], leadSeconds: 300, now: item.start).isEmpty, "handled meeting does not repeat")
        check.expect(ReminderTiming.dueForAlert(events: [item], alerted: [item.id], snoozed: [item.id: item.start], leadSeconds: 300, now: item.start).count == 1, "explicit snooze re-fires")
        var muted = item; muted.isMuted = true
        check.expect(ReminderTiming.dueForAlert(events: [muted], alerted: [], snoozed: [:], leadSeconds: 300, now: item.start).isEmpty, "muted event stays silent")
        let ratchet = ReminderReconciliation.ratchetSilence(previous: [muted], current: [item], alerted: [], snoozed: [item.id: item.start], leadSeconds: 300, now: item.start)
        check.expect(ratchet.alerted == [item.id] && ratchet.snoozed.isEmpty, "unmute inside lead window clears snooze and acknowledges")
        let early = ReminderReconciliation.ratchetSilence(previous: [muted], current: [item], alerted: [], snoozed: [:], leadSeconds: 300, now: item.start.addingTimeInterval(-301))
        check.expect(early.alerted.isEmpty, "early unmute retains future reminder")
        check.expect(ReminderReconciliation.normalizedEvents([item, item]).count == 1, "commit normalization removes duplicate IDs")

        var settings = AppSettings(); settings.catchUpDelivery = .skip; settings.inMeetingDelivery = .suppress
        check.expect(NotificationLogic.route(event: item, settings: settings, activity: .meeting(.zoom), catchUp: true, snoozed: false, now: item.start.addingTimeInterval(-1)) == .deferReminder, "meeting suppression precedes catch-up")
        check.expect(NotificationLogic.route(event: item, settings: settings, activity: .meeting(.zoom), catchUp: false, snoozed: true, now: item.start) == .handled, "in-meeting suppression handles at start")
        check.expect(NotificationLogic.route(event: item, settings: settings, activity: .unknown, catchUp: false, snoozed: false, now: item.start) == .fullscreen, "unknown activity fails open")
        check.expect(NotificationLogic.route(event: item, settings: settings, activity: .inactive, catchUp: true, snoozed: true, now: item.start) == .fullscreen, "explicit snooze bypasses catch-up skip")
        settings.inMeetingDelivery = .notification
        check.expect(NotificationLogic.route(event: item, settings: settings, activity: .meeting(.teams), catchUp: true, snoozed: false, now: item.start) == .notification, "notification route retained for permission adapter")
        let later = modelEvent(calendarID: UUID(), start: item.start.addingTimeInterval(0.001))
        check.expect(NotificationLogic.sameStartGroups([later, item]).count == 2, "notification grouping uses exact Date, not rounded seconds")
    }

    static func observationOwnership(_ check: inout Check) {
        let item = modelEvent(calendarID: cacheSubscription.id)
        var tracker = ReminderSnapshotTracker()
        _ = tracker.retainedIDs(current: [item], observedCalendarIDs: [], enabledCalendarIDs: [item.calendarID])
        for observed: Set<UUID> in [[], [UUID()], [item.calendarID]] {
            check.expect(tracker.retainedIDs(current: [], observedCalendarIDs: observed, enabledCalendarIDs: [item.calendarID]) == [item.id], "snapshot ownership retains through unrelated/first omission")
        }
        check.expect(tracker.retainedIDs(current: [], observedCalendarIDs: [item.calendarID], enabledCalendarIDs: [item.calendarID]).isEmpty, "snapshot tracker retires second own omission")
        var catchUp = CatchUpRefreshTracker()
        catchUp.begin(); catchUp.started(1); catchUp.begin(); catchUp.started(2)
        check.expect(!catchUp.finish(1) && catchUp.pending && catchUp.finish(2) && !catchUp.pending, "latest wake owns catch-up completion")
        var sync = SyncNotificationTracker()
        check.expect(sync.candidates(failed: [item.calendarID], now: item.start).isEmpty, "sync warning waits for continuous episode")
        check.expect(sync.candidates(failed: [item.calendarID], now: item.start.addingTimeInterval(300)) == [item.calendarID], "sync warning eligible at five minutes")
        sync.notified.insert(item.calendarID)
        check.expect(sync.candidates(failed: [item.calendarID], now: item.start.addingTimeInterval(600)).isEmpty, "sync episode not repeated")
        _ = sync.candidates(failed: [], now: item.start.addingTimeInterval(601))
        check.expect(sync.firstFailure.isEmpty && sync.notified.isEmpty, "successful sync resets episode")
        var activity = MeetingActivityDebouncer()
        _ = activity.apply(.meeting(.zoom))
        check.expect(activity.apply(.inactive) == .meeting(.zoom) && activity.apply(.inactive) == .inactive, "two inactive probes end detected activity")
        _ = activity.apply(.meeting(.teams))
        check.expect(activity.apply(.unknown) == .unknown, "unknown probe resets detection")
    }

    static func snoozeDecisions(_ check: inout Check) {
        let item = modelEvent(calendarID: cacheSubscription.id)
        let nearEnd = modelEvent(calendarID: UUID(), start: item.start.addingTimeInterval(-3500))
        let options = SnoozePolicy.options(events: [item, nearEnd], now: item.start, customSeconds: 37)
        check.expect(!options.atStartEnabled && options.enabledDurations == [37, 60], "shared snooze respects shortest remaining event")
        check.expect(SnoozePolicy.primaryPlan(options: options, defaultSeconds: 300) == .duration(60), "duration default shortens to longest safe choice")
        check.expect(SnoozePolicy.primaryPlan(options: options, defaultSeconds: 0) == .duration(37), "at-start default falls back to shortest safe choice")
        check.expect(SnoozePolicy.schedule(plan: .duration(60), events: [item, nearEnd], now: item.start.addingTimeInterval(40)) == nil, "stale snooze rejects exact end boundary")
        let now = item.start.addingTimeInterval(-300)
        let future = modelEvent(calendarID: UUID(), start: item.start.addingTimeInterval(60))
        let schedule = SnoozePolicy.schedule(plan: .atStart, events: [item, future], now: now)
        check.expect(schedule == [item.id: item.start, future.id: future.start], "just-in-time snooze uses each occurrence start")
        check.expect(SnoozePolicy.schedule(plan: .duration(7201), events: [item], now: now) == nil, "oversized custom snooze rejected")
        check.expect(!SnoozePolicy.options(events: [item], now: item.end).anyEnabled, "ended reminders have no snooze")
    }
}
