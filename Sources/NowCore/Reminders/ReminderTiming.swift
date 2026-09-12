import Foundation

/// Clock-driven eligibility, independent of timers, pause controls and UI delivery.
package enum ReminderTiming {
    package static func dueForAlert(events: [MeetingEvent], alerted: Set<String>, snoozed: [String: Date], leadSeconds: Int, now: Date) -> [MeetingEvent] {
        let lead = TimeInterval(leadSeconds)
        return events.filter { event in
            if event.isMuted { return false }
            if alerted.contains(event.id) {
                if let fireAt = snoozed[event.id], now >= fireAt, now < event.end { return true }
                return false
            }
            return now >= event.start.addingTimeInterval(-lead) && now < event.end
        }
    }

    package static func joinHandlesReminder(_ event: MeetingEvent, leadSeconds: Int, now: Date) -> Bool {
        now >= event.start.addingTimeInterval(-TimeInterval(leadSeconds)) && now < event.end
    }
}
