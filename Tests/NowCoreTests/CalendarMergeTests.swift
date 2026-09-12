import Foundation
import NowCore

extension CoreTests {
    static func calendarMerge(_ check: inout Check) {
        let sub = cacheSubscription
        let item = modelEvent(calendarID: sub.id)
        var tracker = FetchTracker()
        let oldID = tracker.beginFull(subscriptionIDs: [sub.id])
        let newID = tracker.begin(subscriptionID: sub.id)
        check.expect(newID > oldID && tracker.latestPerSubscription[sub.id] == newID, "targeted fetch supersedes full generation")
        var live = sub; live.colorHex = "#abcdef"; live.titleFilters = [TitleFilterRule(pattern: item.title)]
        let stale = FetchResult(subscription: sub, events: [], error: nil, requestID: oldID)
        let dropped = CalendarSnapshotMerge.merge(current: [item], results: [stale], live: [live], previousErrors: [:],
            latestRequestIDs: tracker.latestPerSubscription, colorHex: { $0.colorHex })
        check.expect(dropped.events.map(\.id) == [item.id] && dropped.observedCalendarIDs.isEmpty && !dropped.allSucceeded,
                     "stale empty result cannot delete events or count as omission")
        check.expect(dropped.events.first?.isMuted == true && dropped.events.first?.colorHex == live.colorHex, "stale fetch still respects current filtering/presentation")
        let failed = FetchResult(subscription: sub, events: [], error: "synthetic transport failure", requestID: newID)
        let retained = CalendarSnapshotMerge.merge(current: [item], results: [failed], live: [sub], previousErrors: [:],
            previousWarnings: [sub.id: "old warning"], latestRequestIDs: tracker.latestPerSubscription, colorHex: { $0.colorHex })
        check.expect(retained.events.map(\.id) == [item.id] && retained.warnings[sub.id] == "old warning"
                     && retained.errors[sub.id] != nil && retained.observedCalendarIDs.isEmpty, "failed source retains accepted events/warnings without observation")

        let empty = FetchResult(subscription: sub, events: [], error: nil, requestID: newID)
        let accepted = CalendarSnapshotMerge.merge(current: [item], results: [empty], live: [sub], previousErrors: retained.errors,
            previousWarnings: retained.warnings, latestRequestIDs: tracker.latestPerSubscription, colorHex: { $0.colorHex })
        check.expect(accepted.events.isEmpty && accepted.errors.isEmpty && accepted.warnings.isEmpty
                     && accepted.observedCalendarIDs == [sub.id] && accepted.allSucceeded, "complete current empty snapshot is accepted observation")
        var ledger = ReminderLedger(); ledger.record(item)
        ledger.reconcile(events: retained.events, enabled: [sub.id], observed: retained.observedCalendarIDs, now: item.start)
        ledger.reconcile(events: accepted.events, enabled: [sub.id], observed: accepted.observedCalendarIDs, now: item.start)
        check.expect(ledger.entries[ReminderIdentity.eventKey(item)]?.misses == 1, "merge observations drive exactly one ledger omission")
        ledger.reconcile(events: [], enabled: [sub.id], observed: [], now: item.start)
        check.expect(!ledger.entries.isEmpty, "unrelated commits cannot count as second omission")
        ledger.reconcile(events: accepted.events, enabled: [sub.id], observed: accepted.observedCalendarIDs, now: item.start)
        check.expect(ledger.entries.isEmpty, "second accepted source omission retires bookkeeping")

        live = sub; live.url += "&changed=1"
        let edited = CalendarSnapshotMerge.merge(current: [item], results: [empty], live: [live], previousErrors: [:], colorHex: { $0.colorHex })
        check.expect(edited.events.count == 1 && edited.observedCalendarIDs.isEmpty, "URL-edited source rejects in-flight old result")
        live = sub; live.isEnabled = false
        let disabled = CalendarSnapshotMerge.merge(current: [item], results: [empty], live: [live], previousErrors: retained.errors, colorHex: { $0.colorHex })
        check.expect(disabled.events.isEmpty && disabled.errors.isEmpty && disabled.observedCalendarIDs.isEmpty, "disabled calendar never resurrected")
        let invalidated = CalendarSnapshotMerge.merge(current: [item], results: [], live: [sub], previousErrors: retained.errors,
            invalidatedCalendarIDs: [sub.id], colorHex: { $0.colorHex })
        check.expect(invalidated.events.isEmpty && invalidated.errors.isEmpty, "explicit invalidation clears old source state")
    }
}
