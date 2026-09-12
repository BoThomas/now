import Foundation

/// Stateless decisions used by the shell's single commit transaction. This does
/// not own receipts or perform persistence; the transaction controls their order.
package enum ReminderReconciliation {
    /// Unmuting inside the lead window must neither surprise-alert nor retain a snooze.
    package static func ratchetSilence(previous: [MeetingEvent], fallbackMutedByID: [String: Bool] = [:], current: [MeetingEvent], alerted: Set<String>, snoozed: [String: Date], leadSeconds: Int, now: Date) -> (alerted: Set<String>, snoozed: [String: Date]) {
        var wasMuted = fallbackMutedByID
        for event in previous { wasMuted[event.id] = event.isMuted }
        var alerted = alerted
        var snoozed = snoozed
        let lead = TimeInterval(leadSeconds)
        for event in current {
            guard wasMuted[event.id] == true, !event.isMuted else { continue }
            guard now >= event.start.addingTimeInterval(-lead), now < event.end else { continue }
            alerted.insert(event.id)
            snoozed.removeValue(forKey: event.id)
        }
        return (alerted, snoozed)
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
