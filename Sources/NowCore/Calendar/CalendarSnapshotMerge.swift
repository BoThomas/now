import Foundation

package struct CalendarMergeResult: Sendable {
    package let events: [MeetingEvent]
    package let errors: [UUID: String]
    package let warnings: [UUID: String]
    package let allSucceeded: Bool
    package let observedCalendarIDs: Set<UUID>
}

/// Accept complete, current source snapshots only. Failed/stale results retain
/// accepted data and never count as a successful omission for reminder history.
package enum CalendarSnapshotMerge {
    package static func merge(current: [MeetingEvent], results: [FetchResult], live: [CalendarSubscription], previousErrors: [UUID: String], previousWarnings: [UUID: String] = [:], latestRequestIDs: [UUID: Int] = [:], invalidatedCalendarIDs: Set<UUID> = [], colorHex: (CalendarSubscription) -> String) -> CalendarMergeResult {
        let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        let colorByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, colorHex($0)) })
        let matchers = TitleFilterMatcher.byCalendar(subscriptions: live)
        var events = current.compactMap { event -> MeetingEvent? in
            guard !invalidatedCalendarIDs.contains(event.calendarID),
                  let subscription = liveByID[event.calendarID], subscription.isEnabled else { return nil }
            var copy = event
            if let hex = colorByID[event.calendarID] { copy.colorHex = hex }
            copy.isMuted = matchers[event.calendarID]?.matches(title: event.title) ?? false
            return copy
        }
        let enabledIDs = Set(live.filter(\.isEnabled).map(\.id))
        var errors = previousErrors.filter { enabledIDs.contains($0.key) && !invalidatedCalendarIDs.contains($0.key) }
        var warnings = previousWarnings.filter { enabledIDs.contains($0.key) && !invalidatedCalendarIDs.contains($0.key) }
        var allSucceeded = true
        var observedCalendarIDs: Set<UUID> = []
        for result in results {
            guard let subscription = liveByID[result.subscription.id],
                  subscription.isEnabled,
                  subscription.url == result.subscription.url,
                  latestRequestIDs[result.subscription.id, default: result.requestID] == result.requestID else {
                allSucceeded = false
                continue
            }
            if let error = result.error {
                errors[subscription.id] = error
                allSucceeded = false
                continue
            }
            observedCalendarIDs.insert(subscription.id)
            errors.removeValue(forKey: subscription.id)
            if let warning = result.warning {
                warnings[subscription.id] = warning
            } else {
                warnings.removeValue(forKey: subscription.id)
            }
            events.removeAll { $0.calendarID == subscription.id }
            events.append(contentsOf: result.events.map { event in
                var copy = event
                if let hex = colorByID[event.calendarID] { copy.colorHex = hex }
                copy.isMuted = matchers[event.calendarID]?.matches(title: event.title) ?? false
                return copy
            })
        }
        return CalendarMergeResult(events: events, errors: errors, warnings: warnings,
                                   allSucceeded: allSucceeded, observedCalendarIDs: observedCalendarIDs)
    }
}
