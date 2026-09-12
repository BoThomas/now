import Foundation

/// Stable persisted keys and versioned content fingerprints. Preserve separators,
/// source UUID casing and exact original occurrence anchors across upgrades.
package enum ReminderIdentity {
    package static func key(_ id: String) -> String { StableDigest.sha256(id) }

    package static func eventKey(_ event: MeetingEvent) -> String {
        guard let identity = event.notificationIdentity else { return key(event.id) }
        return key(event.calendarID.uuidString + ":" + identity)
    }

    package static func legacyFingerprint(_ event: MeetingEvent) -> String {
        key([event.legacyID, event.title, String(event.end.timeIntervalSince1970), event.link?.absoluteString ?? "", String(event.isMuted)].joined(separator: "\n"))
    }

    package static func priorAgendaFingerprint(_ event: MeetingEvent) -> String {
        key([event.legacyID, event.title, String(event.end.timeIntervalSince1970), event.link?.absoluteString ?? "", event.location ?? "", String(event.isMuted)].joined(separator: "\n"))
    }

    package static func fingerprint(_ event: MeetingEvent) -> String {
        key([event.id, event.title, String(event.end.timeIntervalSince1970), event.link?.absoluteString ?? "", event.location ?? "", String(event.isMuted)].joined(separator: "\n"))
    }
}
