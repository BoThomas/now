import Foundation

/// Membership of one concrete delivery. Occurrence keys still own live content and source identity.
package struct ReminderDeliveryState: Codable, Equatable, Sendable {
    package var leads: Set<Int>
    package var snoozeToken: String?
    package var actionToken: String?
    package init(leads: Set<Int> = [], snoozeToken: String? = nil, actionToken: String? = nil) {
        self.leads = leads; self.snoozeToken = snoozeToken; self.actionToken = actionToken
    }
    package var isEmpty: Bool { leads.isEmpty && snoozeToken == nil }
}

extension ReminderLedger {
    package mutating func migrateLegacy(lead: Int) {
        for (key, var entry) in entries where entry.handledLeads == nil {
            entry.handledLeads = [lead]
            if entry.snooze != nil && entry.snoozeToken == nil { entry.snoozeToken = UUID().uuidString }
            entries[key] = entry
        }
    }

    package func due(_ event: MeetingEvent, leads: [Int], now: Date) -> ReminderDeliveryState {
        guard !event.isMuted, now < event.end else { return ReminderDeliveryState() }
        let entry = entries[ReminderIdentity.eventKey(event)]
        if let snooze = entry?.snooze, now < snooze { return ReminderDeliveryState() }
        let handled = entry?.handledLeads ?? (entry == nil ? [] : Set([leads.max() ?? 300]))
        let due = leads.filter { lead in
            let fire = event.start.addingTimeInterval(-Double(lead))
            return now >= fire && !handled.contains(lead)
                && (leadActivatedAt?[lead].map { fire > $0 } ?? true)
        }
        return ReminderDeliveryState(leads: Set(due), snoozeToken: entry?.snoozeToken,
                                     actionToken: entry?.actionToken)
    }

    package mutating func accept(_ delivery: ReminderDeliveryState, event: MeetingEvent) {
        let key = ReminderIdentity.eventKey(event)
        var entry = entries[key] ?? freshEntry(event)
        guard entry.actionToken == delivery.actionToken else { return }
        entry.handledLeads = (entry.handledLeads ?? []).union(delivery.leads)
        if let token = delivery.snoozeToken, token == entry.snoozeToken {
            entry.snooze = nil; entry.snoozeToken = nil
        }
        entries[key] = entry
    }

    package mutating func schedule(_ event: MeetingEvent, until: Date, leads: [Int]) {
        let key = ReminderIdentity.eventKey(event)
        var entry = entries[key] ?? freshEntry(event)
        entry.handledLeads = (entry.handledLeads ?? []).union(leads.filter {
            event.start.addingTimeInterval(-Double($0)) <= until
        })
        entry.snooze = until; entry.snoozeToken = UUID().uuidString
        entry.joined = false; entry.actionToken = UUID().uuidString
        entries[key] = entry
    }

    package mutating func join(_ event: MeetingEvent) {
        let key = ReminderIdentity.eventKey(event)
        var entry = entries[key] ?? freshEntry(event)
        entry.joined = true; entry.actionToken = UUID().uuidString
        entries[key] = entry
    }

    package func suppressAfterJoin(_ event: MeetingEvent, detectionEnabled: Bool, activity: MeetingActivity) -> Bool {
        entries[ReminderIdentity.eventKey(event)]?.joined == true && !(detectionEnabled && activity == .inactive)
    }

    package mutating func silenceDue(_ event: MeetingEvent, leads: [Int], now: Date) {
        let key = ReminderIdentity.eventKey(event)
        var entry = entries[key] ?? freshEntry(event)
        entry.handledLeads = (entry.handledLeads ?? []).union(leads.filter {
            now >= event.start.addingTimeInterval(-Double($0))
        })
        entry.snooze = nil; entry.snoozeToken = nil; entry.actionToken = UUID().uuidString
        entries[key] = entry
    }

    package mutating func changeLeads(from old: [Int], to new: [Int], at now: Date) {
        var cutoffs = leadActivatedAt ?? [:]
        for lead in Set(new).subtracting(old) { cutoffs[lead] = now }
        leadActivatedAt = cutoffs.filter { new.contains($0.key) }
        for (key, var entry) in entries {
            entry.handledLeads = entry.handledLeads?.intersection(new)
            entries[key] = entry
        }
    }

    private func freshEntry(_ event: MeetingEvent) -> Entry {
        var entry = Entry(calendarID: event.calendarID, end: event.end, start: event.start)
        entry.handledLeads = []
        return entry
    }

    func reconciledEntry(_ original: Entry, event: MeetingEvent, legacyLead: Int, rearm: Bool, protected: Set<Int>) -> Entry {
        var entry = original
        if entry.handledLeads == nil { entry.handledLeads = [legacyLead] }
        if entry.snooze != nil && entry.snoozeToken == nil { entry.snoozeToken = UUID().uuidString }
        if let start = entry.start, start != event.start {
            entry.joined = false; entry.actionToken = UUID().uuidString
            if let snooze = entry.snooze {
                let shifted = snooze.addingTimeInterval(event.start.timeIntervalSince(start))
                entry.snooze = shifted < event.end ? shifted : nil
                if entry.snooze == nil { entry.snoozeToken = nil }
            } else if rearm {
                entry.handledLeads = (entry.handledLeads ?? []).intersection(protected)
            }
        }
        if let snooze = entry.snooze, snooze >= event.end { entry.snooze = nil; entry.snoozeToken = nil }
        return entry
    }
}
