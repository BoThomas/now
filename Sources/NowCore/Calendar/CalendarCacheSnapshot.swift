import Foundation

/// Materialized occurrences only: restoration never expands stale recurrence rules.
package struct CachedMeeting: Codable, Sendable {
    package let uid: String
    package let notificationIdentity: String?
    package let title: String
    package let start: Date
    package let end: Date
    package let location: String?
    package let notes: String?
    package let link: URL?

    package init(_ event: MeetingEvent) {
        notificationIdentity = event.notificationIdentity
        uid = event.uid; title = event.title; start = event.start; end = event.end
        location = event.location; notes = event.notes; link = event.link
    }

    package func event(subscription: CalendarSubscription) -> MeetingEvent {
        MeetingEvent(uid: uid, title: title, start: start, end: end, location: location,
                     notes: notes, link: link, calendarID: subscription.id,
                     calendarName: subscription.name, colorIndex: subscription.colorIndex,
                     colorHex: subscription.colorHex, notificationIdentity: notificationIdentity)
    }

    var estimatedBytes: Int {
        // JSON escaping can expand each byte sixfold. Bound encoding allocations too.
        256 + [uid, notificationIdentity ?? "", title, location ?? "", notes ?? "", link?.absoluteString ?? ""].reduce(0) { $0 + $1.utf8.count * 6 }
    }
}

package struct CalendarCacheSnapshot: Codable, Sendable {
    package static let version = 1
    package var version = Self.version
    package let calendarID: UUID
    package let sourceFingerprint: String
    package let fetchedAt: Date
    package let coverageStart: Date
    package let coverageEnd: Date
    package let warning: String?
    package let meetings: [CachedMeeting]

    package init(subscription: CalendarSubscription, events: [MeetingEvent], fetchedAt: Date, warning: String?) {
        calendarID = subscription.id
        sourceFingerprint = Self.fingerprint(subscription.url)
        self.fetchedAt = fetchedAt
        coverageStart = fetchedAt.addingTimeInterval(-6 * 3600)
        coverageEnd = fetchedAt.addingTimeInterval(14 * 86400)
        self.warning = warning
        meetings = events.map(CachedMeeting.init)
    }

    package static func fingerprint(_ url: String) -> String { StableDigest.sha256(url) }

    package func matches(_ subscription: CalendarSubscription) -> Bool {
        subscription.isEnabled && calendarID == subscription.id && sourceFingerprint == Self.fingerprint(subscription.url)
    }

    package var isValid: Bool {
        version == Self.version && (0..<253_402_300_800).contains(fetchedAt.timeIntervalSince1970) &&
        coverageStart == fetchedAt.addingTimeInterval(-6 * 3600) &&
        coverageEnd == fetchedAt.addingTimeInterval(14 * 86400) &&
        meetings.count <= 10_000 && meetings.allSatisfy {
            $0.start.timeIntervalSince1970.isFinite && (0..<1_000_000_000_000).contains($0.end.timeIntervalSince1970) &&
            $0.start >= coverageStart && $0.start <= coverageEnd && $0.end > $0.start &&
            ($0.link == nil || ["http", "https"].contains($0.link?.scheme?.lowercased() ?? ""))
        }
    }

    package func events(subscription: CalendarSubscription, now: Date) -> [MeetingEvent] {
        guard isValid, matches(subscription), now >= coverageStart, now <= coverageEnd else { return [] }
        return meetings.filter { $0.end > now }.map { $0.event(subscription: subscription) }
    }
}

package struct CalendarCacheLoad: Sendable {
    package var snapshots: [UUID: CalendarCacheSnapshot] = [:]
    package var issues: [UUID: String] = [:]
}

package struct CalendarCacheInfo: Sendable {
    package let fetchedAt: Date
    package let coverageStart: Date
    package let coverageEnd: Date
    package var usingSavedData: Bool

    package init(snapshot: CalendarCacheSnapshot, usingSavedData: Bool) {
        fetchedAt = snapshot.fetchedAt; coverageStart = snapshot.coverageStart
        coverageEnd = snapshot.coverageEnd; self.usingSavedData = usingSavedData
    }

    package func covers(_ date: Date) -> Bool { date >= coverageStart && date <= coverageEnd }
}
