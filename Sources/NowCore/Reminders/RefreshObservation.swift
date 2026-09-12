import Foundation

/// Only the full batch owned by the latest launch/wake may finish catch-up.
package struct CatchUpRefreshTracker: Sendable {
    package private(set) var pending = false
    private var owner: Int?
    package init() {}
    package mutating func begin() { pending = true; owner = nil }
    package mutating func started(_ requestID: Int) { if pending { owner = requestID } }
    package mutating func finish(_ requestID: Int) -> Bool {
        guard pending, owner == requestID else { return false }
        pending = false
        owner = nil
        return true
    }
}

/// One notification per continuous failure episode, after five minutes.
package struct SyncNotificationTracker: Codable, Sendable {
    package var firstFailure: [UUID: Date] = [:]
    package var notified: Set<UUID> = []
    package init() {}
    package mutating func candidates(failed: Set<UUID>, now: Date) -> Set<UUID> {
        firstFailure = firstFailure.filter { failed.contains($0.key) }
        notified.formIntersection(failed)
        for id in failed where firstFailure[id] == nil { firstFailure[id] = now }
        return Set(firstFailure.compactMap { id, start in
            !notified.contains(id) && now.timeIntervalSince(start) >= 300 ? id : nil
        })
    }
}

/// Source-owned omission retention. Failed or unrelated snapshots cannot age an entry.
package struct ReminderSnapshotTracker: Sendable {
    private var calendarByID: [String: UUID] = [:]
    private var missingOnce: Set<String> = []
    package init() {}

    package mutating func invalidate(calendarIDs: Set<UUID>) {
        calendarByID = calendarByID.filter { !calendarIDs.contains($0.value) }
        missingOnce.formIntersection(Set(calendarByID.keys))
    }

    package mutating func retainedIDs(current: [MeetingEvent], observedCalendarIDs: Set<UUID>, enabledCalendarIDs: Set<UUID>) -> Set<String> {
        let active = Set(current.map(\.id))
        calendarByID = calendarByID.filter { enabledCalendarIDs.contains($0.value) }
        for (id, calendarID) in calendarByID where observedCalendarIDs.contains(calendarID) && !active.contains(id) {
            if missingOnce.contains(id) { calendarByID.removeValue(forKey: id) }
            else { missingOnce.insert(id) }
        }
        for event in current where enabledCalendarIDs.contains(event.calendarID) {
            calendarByID[event.id] = event.calendarID
            missingOnce.remove(event.id)
        }
        let retained = Set(calendarByID.keys)
        missingOnce.formIntersection(retained)
        return retained
    }
}
