import Foundation

/// No titles, feed URLs, notes, or join links are stored in acknowledgement data.
/// Keep absent records until expiry or two successful source-owned omissions.
package struct ReminderLedger: Codable, Equatable, Sendable {
    package struct Entry: Codable, Equatable, Sendable {
        package var calendarID: UUID
        package var end: Date
        package var snooze: Date?
        package var misses = 0
        /// Older ledgers did not retain the scheduled start.
        package var start: Date?

        package init(calendarID: UUID, end: Date, snooze: Date? = nil, misses: Int = 0, start: Date? = nil) {
            self.calendarID = calendarID; self.end = end; self.snooze = snooze
            self.misses = misses; self.start = start
        }
    }
    package var entries: [String: Entry] = [:]
    package init() {}

    package mutating func record(_ event: MeetingEvent, snooze: Date? = nil) {
        entries[ReminderIdentity.eventKey(event)] = Entry(calendarID: event.calendarID, end: event.end, snooze: snooze, start: event.start)
    }

    @discardableResult
    package mutating func reconcile(events: [MeetingEvent], enabled: Set<UUID>, observed: Set<UUID>, now: Date,
                                    rearmOnReschedule: Set<String> = [], previousEvents: [MeetingEvent] = []) -> Set<String> {
        var rearmedIDs: Set<String> = []
        let previousByKey = Dictionary(previousEvents.map { (ReminderIdentity.eventKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        // Upgrade old occurrence-ID entries only when that exact occurrence is present.
        let legacyCounts = Dictionary(grouping: events, by: \.legacyID).mapValues(\.count)
        // An ambiguous old key cannot safely be assigned after one sibling disappears.
        for (id, count) in legacyCounts where count > 1 { entries.removeValue(forKey: ReminderIdentity.key(id)) }
        for event in events where legacyCounts[event.legacyID] == 1 {
            let old = ReminderIdentity.key(event.legacyID), key = ReminderIdentity.eventKey(event)
            if old != key, let entry = entries.removeValue(forKey: old), entries[key] == nil { entries[key] = entry }
        }
        let live = Dictionary(events.map { (ReminderIdentity.eventKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        for (key, var entry) in entries {
            if let event = live[key] {
                // Receipts own notification edits; only eligible fullscreen reminders re-arm.
                let previousStart = entry.start ?? previousByKey[key]?.start
                if rearmOnReschedule.contains(key), entry.snooze == nil,
                   let previousStart, previousStart != event.start {
                    entries.removeValue(forKey: key)
                    rearmedIDs.insert(event.id)
                    // Moving back must not revive retained handled memory.
                    if let previous = previousByKey[key] { rearmedIDs.insert(previous.id) }
                    continue
                }
                entry.start = event.start
                entry.end = event.end
                entry.misses = 0
            }
            else if observed.contains(entry.calendarID) { entry.misses += 1 }
            guard enabled.contains(entry.calendarID), entry.end > now else { entries.removeValue(forKey: key); continue }
            if entry.misses >= 2 { entries.removeValue(forKey: key) }
            else { entries[key] = entry }
        }
        if entries.count > 20_000 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.end > $1.value.end }.prefix(20_000).map { ($0.key, $0.value) })
        }
        return rearmedIDs
    }

    package mutating func invalidate(_ calendars: Set<UUID>) {
        entries = entries.filter { !calendars.contains($0.value.calendarID) }
    }
}
