import Foundation

// MARK: - Feed → meetings

package struct ICSBuildResult: Sendable {
    package var events: [MeetingEvent] = []
    package var warnings: [String] = []
    package var error: String?
}

package enum ICSBuilder {
    /// One resolved revision shares its detected link across materialized dates.
    /// Overrides get their own content, so moved/changed links never reuse the master.
    private final class OccurrenceContent {
        let event: ParsedEvent
        private let detectLink: (ParsedEvent) -> URL?
        lazy var link: URL? = detectLink(event)
        init(_ event: ParsedEvent, detectLink: @escaping (ParsedEvent) -> URL?) {
            self.event = event; self.detectLink = detectLink
        }
    }
    private struct Occurrence {
        let start: Date
        let anchor: Date?
        let content: OccurrenceContent
        var event: ParsedEvent { content.event }
    }

    package static let maxEventsPerFeed = 10_000
    package static let maxFeedRecurrenceBudget = 500_000

    package static func meetings(fromICS text: String, subscription: CalendarSubscription, now: Date, colorHex: String, detectLink: @escaping (ParsedEvent) -> URL?) -> ICSBuildResult {
        let windowStart = now.addingTimeInterval(-6 * 3600)
        let windowEnd = now.addingTimeInterval(14 * 86400)
        let dateFormatters = ICSDateFormatters()
        let parsed = ICSParser.parse(text, dateFormatters: dateFormatters)
        if let error = parsed.error { return ICSBuildResult(error: error) }
        var warnings = parsed.warnings
        var result: [MeetingEvent] = []
        var feedBudget = maxFeedRecurrenceBudget
        var historicalSteps = 0
        var seenEventKeys = Set<String>()
        let groups = Dictionary(grouping: parsed.events, by: { $0.uid })
        let recurringSeries = groups.values.filter { $0.contains { $0.rrule != nil } }.count
        // Stable allocation of the deterministic work budget, independent of hashing.
        for uid in groups.keys.sorted() {
            let events = groups[uid]!
            let master = latestRevision(of: events.filter { $0.recurrenceIDProperty == nil && $0.dtStart != nil })
            var occurrences: [Date: Occurrence] = [:]
            if let originalMaster = master {
                var m = originalMaster
                if !m.isAllDay {
                    func timedDates(_ properties: [ICSProperty]) -> [ICSProperty] {
                        properties.filter { property in
                            let dateOnly = property.params["VALUE"]?.uppercased() == "DATE"
                                || property.value.split(separator: ",").contains { $0.count == 8 && !$0.contains("T") }
                            if dateOnly { warnings.append("\(property.name) DATE values on a timed event are not supported — dates skipped") }
                            return !dateOnly
                        }
                    }
                    m.exdateProperties = timedDates(m.exdateProperties)
                    m.rdateProperties = timedDates(m.rdateProperties)
                }
                m.exdates = Self.resolvedDates(m.exdateProperties, masterTz: m.tz, dateFormatters: dateFormatters)
                if m.unsupportedRRULEText != nil {
                    warnings.append("Unsupported RRULE \"\(m.unsupportedRRULEText!)\" — “\(m.title)” shows only its first occurrence")
                }
                guard m.status != "CANCELLED" else { continue }
                let content = OccurrenceContent(m, detectLink: detectLink)
                if m.rrule != nil, !m.isAllDay {
                    let initialBudget = min(feedBudget, RRULEExpander.maxIterationsPerEvent)
                    var eventBudget = initialBudget
                    let expansion = RRULEExpander.expand(m, windowStart: windowStart, windowEnd: windowEnd, budget: &eventBudget)
                    feedBudget -= initialBudget - eventBudget
                    historicalSteps += expansion.historicalSteps
                    if !expansion.completed {
                        let used = maxFeedRecurrenceBudget - feedBudget
                        let scope = feedBudget == 0 ? "calendar" : "series"
                        let limit = scope == "calendar" ? maxFeedRecurrenceBudget : RRULEExpander.maxIterationsPerEvent
                        let title = String(m.title.prefix(100))
                        let message = "Calendar not updated: recurrence processing reached the \(scope) limit of \(limit) calculation steps while checking “\(title)”. This feed contains \(parsed.events.count) event records and \(recurringSeries) recurring series. We used \(used) steps, including \(historicalSteps) checking dates before the current window. COUNT rules require counting from their original start on each refresh. Reduce old recurring history or use a smaller calendar export. Previously loaded meetings are kept if available; new changes could not be checked."
                        return ICSBuildResult(error: message)
                    }
                    for date in expansion.dates { occurrences[date] = Occurrence(start: date, anchor: date, content: content) }
                } else if !m.isAllDay, let start = m.dtStart, start >= windowStart, start <= windowEnd, !m.exdates.contains(start) {
                    occurrences[start] = Occurrence(start: start, anchor: (!m.rdateProperties.isEmpty || m.unsupportedRRULEText != nil) ? start : nil, content: content)
                }
                // RDATE: extra occurrence dates beyond the rule.
                if !m.isAllDay {
                    let excluded = Set(m.exdates)
                    let resolvedRDates = Self.resolvedDates(m.rdateProperties, masterTz: m.tz, dateFormatters: dateFormatters,
                        limit: maxEventsPerFeed + 1, window: windowStart...windowEnd,
                        minimum: m.dtStart, excluding: excluded)
                    if resolvedRDates.count > maxEventsPerFeed {
                        return ICSBuildResult(error: occurrenceLimitError(records: parsed.events.count, detail: "more than \(maxEventsPerFeed) distinct additional dates inside the six-hour lookback and next 14 days"))
                    }
                    for rdate in resolvedRDates where occurrences[rdate] == nil {
                        occurrences[rdate] = Occurrence(start: rdate, anchor: rdate, content: content)
                    }
                }
            }
            // Detached recurrence overrides.
            var overrides = events.filter { $0.recurrenceIDProperty != nil }
            overrides = overrides.enumerated().sorted {
                let lhs = revisionKey($0.element), rhs = revisionKey($1.element)
                return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
            }.map(\.element)
            var seenRids = Set<Date>()
            for override in overrides {
                if let range = override.recurrenceRange {
                    warnings.append("RECURRENCE-ID RANGE=\(range) is not supported — override ignored")
                    continue
                }
                guard let rid = Self.resolvedRecurrenceID(of: override, masterTz: master?.tz, dateFormatters: dateFormatters) else { continue }
                guard seenRids.insert(rid).inserted else { continue } // duplicate revision
                occurrences.removeValue(forKey: rid)
                guard override.status != "CANCELLED" else { continue }
                guard !override.isAllDay else { continue }
                let start = override.dtStart ?? rid
                guard start >= windowStart, start <= windowEnd else { continue }
                occurrences[rid] = Occurrence(start: start, anchor: rid, content: OccurrenceContent(Self.inheriting(override, from: master), detectLink: detectLink))
            }
            for anchor in occurrences.keys.sorted() {
                guard let occurrence = occurrences[anchor] else { continue }
                let eventKey = "\(occurrence.event.uid)|\((occurrence.anchor ?? occurrence.start).timeIntervalSince1970)"
                guard seenEventKeys.insert(eventKey).inserted else { continue }
                guard result.count < maxEventsPerFeed else {
                    return ICSBuildResult(error: occurrenceLimitError(records: parsed.events.count, detail: "more than \(maxEventsPerFeed) meeting occurrences inside the six-hour lookback and next 14 days"))
                }
                let end = occurrence.start.addingTimeInterval(occurrence.event.durationSeconds)
                result.append(MeetingEvent(
                    uid: occurrence.event.uid,
                    title: occurrence.event.title,
                    start: occurrence.start,
                    end: end,
                    location: occurrence.event.location,
                    notes: occurrence.event.description,
                    link: occurrence.content.link,
                    calendarID: subscription.id,
                    calendarName: subscription.name,
                    colorIndex: subscription.colorIndex,
                    colorHex: colorHex,
                    notificationIdentity: "ics:" + String(uid.utf8.count) + ":" + uid + ":" + (occurrence.anchor.map { String($0.timeIntervalSince1970) } ?? "single")
                ))
            }
        }
        let events = result
            .filter { $0.end > windowStart }
            .sorted { ($0.start, $0.title, $0.uid) < ($1.start, $1.title, $1.uid) }
        return ICSBuildResult(events: events, warnings: warnings)
    }

    private static func occurrenceLimitError(records: Int, detail: String) -> String {
        "Calendar not updated: this feed has \(records) event records producing \(detail). This exceeds the meeting safety limit. Use a smaller calendar export or reduce unusually dense recurrence dates. Previously loaded meetings are kept if available; new changes could not be checked."
    }

    /// Highest SEQUENCE / latest DTSTAMP wins — a stale VEVENT revision must not
    /// override the current one (flaky servers sometimes emit both).
    private static func latestRevision(of events: [ParsedEvent]) -> ParsedEvent? {
        events.max(by: { revisionKey($0) < revisionKey($1) })
    }

    private static func revisionKey(_ event: ParsedEvent) -> (Int, Date) {
        (event.sequence, event.dtstamp ?? .distantPast)
    }

    /// Resolves EXDATE/RDATE values: their own TZID/`Z` when present, otherwise
    /// the master's DTSTART zone (never the local zone).
    private static func resolvedDates(_ properties: [ICSProperty], masterTz: TimeZone?, dateFormatters: ICSDateFormatters, limit: Int? = nil, window: ClosedRange<Date>? = nil, minimum: Date? = nil, excluding: Set<Date> = []) -> [Date] {
        var dates: [Date] = []
        var seen = Set<Date>()
        for property in properties {
            for part in property.value.split(separator: ",") {
                let piece = ICSProperty(name: property.name, params: property.params, value: String(part))
                if let date = ICSParser.parseDate(piece, fallbackTimeZone: masterTz, dateFormatters: dateFormatters).date {
                    guard window?.contains(date) ?? true, minimum.map({ date >= $0 }) ?? true,
                          !excluding.contains(date), seen.insert(date).inserted else { continue }
                    dates.append(date)
                    if let limit, dates.count >= limit { return dates.sorted() }
                }
            }
        }
        return dates
    }

    private static func resolvedRecurrenceID(of override: ParsedEvent, masterTz: TimeZone?, dateFormatters: ICSDateFormatters) -> Date? {
        guard let property = override.recurrenceIDProperty else { return nil }
        if override.recurrenceIDHasExplicitZone { return override.recurrenceID }
        return ICSParser.parseDate(property, fallbackTimeZone: masterTz, dateFormatters: dateFormatters).date
    }

    /// A detached override inherits omitted fields from its master: title,
    /// location, notes, link properties, and duration/end.
    private static func inheriting(_ override: ParsedEvent, from master: ParsedEvent?) -> ParsedEvent {
        guard let master else { return override }
        var copy = override
        if !copy.hasExplicitTitle { copy.title = master.title }
        if copy.location == nil { copy.location = master.location }
        if copy.description == nil { copy.description = master.description }
        if copy.altDescription == nil { copy.altDescription = master.altDescription }
        if copy.conference == nil { copy.conference = master.conference }
        if copy.url == nil { copy.url = master.url }
        if copy.attach == nil { copy.attach = master.attach }
        if !copy.hasExplicitEnd { copy.durationSeconds = master.durationSeconds }
        return copy
    }
}
