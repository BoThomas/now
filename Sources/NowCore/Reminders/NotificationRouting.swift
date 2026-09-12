import Foundation

package enum ReminderRoute: Equatable, Sendable { case fullscreen, notification, catchUp, deferReminder, handled }

/// Permission and delivery adapters run after policy; denied notification access
/// must never convert a discreet route into fullscreen delivery.
package enum NotificationLogic {
    package static func route(event: MeetingEvent, settings: AppSettings, activity: MeetingActivity,
                              catchUp: Bool, snoozed: Bool, now: Date) -> ReminderRoute {
        if case .meeting = activity {
            switch settings.inMeetingDelivery {
            case .suppress: return now >= event.start ? .handled : .deferReminder
            case .notification: return .notification
            case .normal: break
            }
        }
        if catchUp && !snoozed {
            switch settings.catchUpDelivery {
            case .normal: break
            case .notification: return .catchUp
            case .skip: return .handled
            }
        }
        return settings.reminderDelivery == .notification ? .notification : .fullscreen
    }

    package static func sameStartGroups(_ events: [MeetingEvent]) -> [[MeetingEvent]] {
        Dictionary(grouping: events, by: \.start).sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.id < $1.id } }
    }

    // Compatibility entrypoints for existing shell callers; identity has one owner.
    package static func key(_ id: String) -> String { ReminderIdentity.key(id) }
    package static func eventKey(_ event: MeetingEvent) -> String { ReminderIdentity.eventKey(event) }
    package static func legacyFingerprint(_ event: MeetingEvent) -> String { ReminderIdentity.legacyFingerprint(event) }
    package static func priorAgendaFingerprint(_ event: MeetingEvent) -> String { ReminderIdentity.priorAgendaFingerprint(event) }
    package static func fingerprint(_ event: MeetingEvent) -> String { ReminderIdentity.fingerprint(event) }
}
