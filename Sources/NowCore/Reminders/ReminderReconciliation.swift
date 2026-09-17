import Foundation

/// Stateless decisions used by the shell's single commit transaction. This does
/// not own receipts or perform persistence; the transaction controls their order.
package enum ReminderReconciliation {
    /// Unmuting inside the lead window must neither surprise-alert nor retain a snooze.
    package static func ratchetSilence(previousMutedByID: [String: Bool], current: [MeetingEvent],
                                      ledger: inout ReminderLedger, leads: [Int], now: Date) {
        for event in current {
            guard previousMutedByID[event.id] == true, !event.isMuted, now < event.end,
                  leads.contains(where: { now >= event.start.addingTimeInterval(-Double($0)) }) else { continue }
            ledger.silenceDue(event, leads: leads, now: now)
        }
    }

    package static func retainedMutedStates(previous: [String: Bool], current: [MeetingEvent], retainedIDs: Set<String>) -> [String: Bool] {
        var retained = previous.filter { retainedIDs.contains($0.key) }
        for event in current { retained[event.id] = event.isMuted }
        return retained
    }

    package static func normalizedEvents(_ events: [MeetingEvent]) -> [MeetingEvent] {
        var seen = Set<String>()
        var unique: [MeetingEvent] = []
        for event in events.sorted(by: { ($0.start, $0.calendarName, $0.title, $0.id) < ($1.start, $1.calendarName, $1.title, $1.id) }) {
            if seen.insert(event.id).inserted { unique.append(event) }
        }
        return unique
    }

    package static func prunedBookkeeping(alerted: Set<String>, snoozed: [String: Date], retainedIDs: Set<String>) -> (alerted: Set<String>, snoozed: [String: Date]) {
        (alerted.intersection(retainedIDs), snoozed.filter { retainedIDs.contains($0.key) })
    }
}
