import Foundation

package enum SnoozePolicy {
    /// Every active card must support a choice; ended cards never constrain it.
    package struct Options: Equatable, Sendable {
        package var atStartEnabled: Bool
        package var enabledDurations: Set<Int>
        package var anyEnabled: Bool { atStartEnabled || !enabledDurations.isEmpty }
        package var plans: [Plan] {
            (atStartEnabled ? [.atStart] : []) + enabledDurations.sorted().map { .duration($0) }
        }
        package init(atStartEnabled: Bool, enabledDurations: Set<Int>) {
            self.atStartEnabled = atStartEnabled; self.enabledDurations = enabledDurations
        }
    }

    package enum Plan: Equatable, Sendable { case atStart, duration(Int) }

    package static func options(events: [MeetingEvent], now: Date, customSeconds: Int = 0) -> Options {
        let active = events.filter { now < $0.end }
        guard !active.isEmpty else { return Options(atStartEnabled: false, enabledDurations: []) }
        let atStart = active.allSatisfy { now < $0.start }
        let durations = Set(AppSettings.snoozeDurations(including: customSeconds).filter { seconds in
            active.allSatisfy { now.addingTimeInterval(TimeInterval(seconds)) < $0.end }
        })
        return Options(atStartEnabled: atStart, enabledDurations: durations)
    }

    /// Revalidate at activation; stale or unsafe choices leave the reminder open.
    package static func schedule(plan: Plan, events: [MeetingEvent], now: Date) -> [String: Date]? {
        let customSeconds: Int
        switch plan {
        case .atStart: customSeconds = 0
        case .duration(let seconds): customSeconds = seconds
        }
        guard options(events: events, now: now, customSeconds: customSeconds).plans.contains(plan) else { return nil }
        return Dictionary(uniqueKeysWithValues: events.filter { now < $0.end }.map { event in
            switch plan {
            case .atStart: return (event.id, event.start)
            case .duration(let seconds): return (event.id, now.addingTimeInterval(TimeInterval(seconds)))
            }
        })
    }

    package static func primaryPlan(options: Options, defaultSeconds: Int) -> Plan? {
        if defaultSeconds == 0 {
            if options.atStartEnabled { return .atStart }
            return options.enabledDurations.min().map { .duration($0) }
        }
        if let seconds = options.enabledDurations.filter({ $0 <= defaultSeconds }).max() {
            return .duration(seconds)
        }
        return options.atStartEnabled ? .atStart : nil
    }

    package static func selection(current: Plan?, options: Options, defaultSeconds: Int) -> Plan? {
        if let current, options.plans.contains(current) { return current }
        return primaryPlan(options: options, defaultSeconds: defaultSeconds)
    }

    package static func movedSelection(current: Plan?, options: Options, direction: Int) -> Plan? {
        let plans = options.plans
        guard !plans.isEmpty else { return nil }
        guard let current, let index = plans.firstIndex(of: current) else {
            return direction > 0 ? plans.first : plans.last
        }
        return plans[(index + (direction > 0 ? 1 : plans.count - 1)) % plans.count]
    }
}
