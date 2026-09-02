import Foundation

struct ICSProperty {
    let name: String
    let params: [String: String]
    let value: String
}

// MARK: - Recurrence rules

struct RRULE: Equatable {
    enum Freq: String {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly = "YEARLY"
    }

    /// One `BYDAY` entry: a weekday (1=SU … 7=SA, matching `Calendar`'s
    /// `.weekday`) with an optional ordinal (`1MO`, `-1FR`) — ordinals are only
    /// valid for MONTHLY/YEARLY rules.
    struct ByDay: Equatable {
        var ordinal: Int?
        var weekday: Int
    }

    var freq: Freq
    var interval = 1
    var count: Int?
    var until: Date?
    var byday: [ByDay] = []
    var bymonthday: [Int] = []
    var bymonth: [Int] = []
    var bysetpos: [Int] = []
    /// Week start (1=SU … 7=SA); RFC default is MO.
    var wkst: Int

    static let weekdayMap: [String: Int] = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    private static func parseIntegerList(_ value: String) -> [Int]? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, let number = Int(part) else { return nil }
            result.append(number)
        }
        return result
    }

    /// Strict parser: anything this app cannot expand *correctly* returns nil
    /// (the event then falls back to a single occurrence and the feed gets a
    /// visible warning) instead of being silently approximated as something
    /// else. Unsupported: non-day-based frequencies, ordinals on DAILY/WEEKLY,
    /// BYWEEKNUM/BYYEARDAY/BYHOUR/BYMINUTE/BYSECOND, unknown fields, COUNT+UNTIL
    /// together, plain YEARLY BYDAY without BYMONTH.
    static func parse(_ text: String, eventTz: TimeZone?) -> RRULE? {
        var freq: Freq?
        var interval = 1
        var count: Int?
        var until: Date?
        var byday: [ByDay] = []
        var bymonthday: [Int] = []
        var bymonth: [Int] = []
        var bysetpos: [Int] = []
        var wkst: Int?
        for pair in text.split(separator: ";") {
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2 else { return nil }
            let key = String(keyValue[0]).uppercased()
            let value = String(keyValue[1])
            switch key {
            case "FREQ":
                guard let parsed = Freq(rawValue: value.uppercased()) else { return nil }
                freq = parsed
            case "INTERVAL":
                guard let parsed = Int(value), parsed >= 1 else { return nil }
                interval = parsed
            case "COUNT":
                guard let parsed = Int(value), parsed >= 1 else { return nil }
                count = parsed
            case "UNTIL":
                guard let parsed = parseUntil(value, eventTz: eventTz) else { return nil }
                until = parsed
            case "BYDAY":
                for token in value.split(separator: ",") {
                    guard let entry = parseByDay(String(token)) else { return nil }
                    byday.append(entry)
                }
                guard !byday.isEmpty else { return nil }
            case "BYMONTHDAY":
                guard let parsed = parseIntegerList(value) else { return nil }
                bymonthday = parsed
                guard !bymonthday.isEmpty, bymonthday.allSatisfy({ $0 != 0 && $0 >= -31 && $0 <= 31 }) else { return nil }
            case "BYMONTH":
                guard let parsed = parseIntegerList(value) else { return nil }
                bymonth = parsed
                guard !bymonth.isEmpty, bymonth.allSatisfy({ (1...12).contains($0) }) else { return nil }
            case "BYSETPOS":
                guard let parsed = parseIntegerList(value) else { return nil }
                bysetpos = parsed
                guard !bysetpos.isEmpty, bysetpos.allSatisfy({ $0 != 0 && $0 >= -366 && $0 <= 366 }) else { return nil }
            case "WKST":
                guard let parsed = weekdayMap[value.uppercased()] else { return nil }
                wkst = parsed
            case "BYWEEKNUM", "BYYEARDAY", "BYHOUR", "BYMINUTE", "BYSECOND":
                return nil // explicitly unsupported — never approximate
            default:
                return nil // unknown/extension field — reject instead of guessing
            }
        }
        guard let freq else { return nil }
        if count != nil, until != nil { return nil } // RFC: mutually exclusive
        switch freq {
        case .daily, .weekly:
            if byday.contains(where: { $0.ordinal != nil }) { return nil }
            if !bymonthday.isEmpty || !bymonth.isEmpty || !bysetpos.isEmpty { return nil }
        case .monthly:
            if !bysetpos.isEmpty, byday.isEmpty, bymonthday.isEmpty { return nil }
        case .yearly:
            if !bysetpos.isEmpty { return nil }
            if !byday.isEmpty, bymonth.isEmpty { return nil } // plain YEARLY BYDAY spans the whole year
        }
        return RRULE(freq: freq, interval: interval, count: count, until: until, byday: byday, bymonthday: bymonthday, bymonth: bymonth, bysetpos: bysetpos, wkst: wkst ?? weekdayMap["MO"]!)
    }

    static func parseByDay(_ token: String) -> ByDay? {
        let text = token.trimmingCharacters(in: .whitespaces).uppercased()
        guard text.count >= 2 else { return nil }
        let dayPart = String(text.suffix(2))
        guard let weekday = weekdayMap[dayPart] else { return nil }
        let prefix = String(text.dropLast(2))
        if prefix.isEmpty { return ByDay(ordinal: nil, weekday: weekday) }
        guard let ordinal = Int(prefix), ordinal != 0, ordinal >= -53, ordinal <= 53 else { return nil }
        return ByDay(ordinal: ordinal, weekday: weekday)
    }

    static func parseUntil(_ value: String, eventTz: TimeZone?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if value.hasSuffix("Z") {
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return formatter.date(from: value)
        }
        formatter.timeZone = eventTz ?? .current
        if value.contains("T") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            return formatter.date(from: value)
        }
        formatter.dateFormat = "yyyyMMdd"
        if let date = formatter.date(from: value) {
            return date.addingTimeInterval(86399)
        }
        return nil
    }
}

// MARK: - Parsed event

struct ParsedEvent {
    var uid: String
    var title: String
    var location: String?
    var description: String?
    var altDescription: String?
    var conference: String?
    var url: String?
    var attach: String?
    var status: String
    var isAllDay: Bool
    var dtStart: Date?
    var tz: TimeZone?
    var durationSeconds: TimeInterval
    /// True when DTEND or a valid DURATION was present — detached recurrence
    /// overrides without one inherit the master's duration.
    var hasExplicitEnd: Bool
    var rrule: RRULE?
    /// Recurrence exceptions, resolved against the master's zone (see
    /// `ICSBuilder`); exact `Date` equality against occurrences.
    var exdates: [Date]
    var recurrenceID: Date?
    /// Raw properties kept so zones can be resolved with the MASTER's zone:
    /// TZID-less EXDATE / RECURRENCE-ID / RDATE values must inherit the
    /// master's DTSTART zone, not the local zone.
    var exdateProperties: [ICSProperty]
    var rdateProperties: [ICSProperty]
    var recurrenceIDProperty: ICSProperty?
    var recurrenceIDHasExplicitZone = false
    /// `RANGE=` parameter on RECURRENCE-ID (unsupported → override ignored).
    var recurrenceRange: String?
    /// Set when the VEVENT carried an RRULE this app rejects — surfaced as a
    /// feed warning; the event falls back to its single first occurrence.
    var unsupportedRRULEText: String?
    /// Revision markers for resolving duplicate VEVENT revisions.
    var sequence = 0
    var dtstamp: Date?

    init(uid: String, title: String, location: String?, description: String?, altDescription: String?, conference: String?, url: String?, attach: String?, status: String, isAllDay: Bool, dtStart: Date?, tz: TimeZone?, durationSeconds: TimeInterval, hasExplicitEnd: Bool = false, rrule: RRULE?, exdates: [Date], recurrenceID: Date?, sequence: Int = 0, dtstamp: Date? = nil) {
        self.uid = uid
        self.title = title
        self.location = location
        self.description = description
        self.altDescription = altDescription
        self.conference = conference
        self.url = url
        self.attach = attach
        self.status = status
        self.isAllDay = isAllDay
        self.dtStart = dtStart
        self.tz = tz
        self.durationSeconds = durationSeconds
        self.hasExplicitEnd = hasExplicitEnd
        self.rrule = rrule
        self.exdates = exdates
        self.recurrenceID = recurrenceID
        self.sequence = sequence
        self.dtstamp = dtstamp
        exdateProperties = []
        rdateProperties = []
        recurrenceIDProperty = nil
    }
}

// MARK: - Parser

enum ICSParser {
    static let maxLines = 200_000
    static let maxLineLength = 10_000
    private static let consumedDateProperties: Set<String> = ["DTSTART", "DTEND", "DTSTAMP", "EXDATE", "RDATE", "RECURRENCE-ID"]

    static func parse(_ text: String) -> (events: [ParsedEvent], warnings: [String]) {
        var events: [ParsedEvent] = []
        var warnings: [String] = []
        var current: [ICSProperty] = []
        var inEvent = false
        for line in unfolded(text, warnings: &warnings) {
            let token = line.trimmingCharacters(in: .whitespaces).uppercased()
            if token == "BEGIN:VEVENT" {
                inEvent = true
                current = []
            } else if token == "END:VEVENT" {
                if inEvent, let event = makeEvent(current, warnings: &warnings) { events.append(event) }
                inEvent = false
                current = []
            } else if inEvent, !line.isEmpty, let property = splitProperty(line) {
                current.append(property)
            }
        }
        return (events, warnings)
    }

    /// Normalizes CRLF/CR → LF (CR+LF is one grapheme cluster in Swift, so a
    /// naive `split(separator: "\n")` sees one giant line), unfolds RFC 5545
    /// continuation lines, and caps parser workload (line count + length).
    static func unfolded(_ text: String, warnings: inout [String]) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        var truncated = false
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if !lines.isEmpty {
                    lines[lines.count - 1].append(contentsOf: line.dropFirst())
                    if lines[lines.count - 1].count > maxLineLength, !truncated {
                        truncated = true
                        warnings.append("Feed line longer than \(maxLineLength) characters — feed truncated")
                    }
                    continue
                }
            }
            if lines.count >= maxLines {
                if !truncated {
                    truncated = true
                    warnings.append("Feed longer than \(maxLines) lines — feed truncated")
                }
                break
            }
            lines.append(line)
        }
        return lines
    }

    /// Splits `NAME;PARAM=VALUE:VALUE` — the first unquoted `:` separates the
    /// value; parameter segments honor quotes so `TZID="Foo;Bar"` stays intact.
    static func splitProperty(_ line: String) -> ICSProperty? {
        var inQuotes = false
        var colonIndex: String.Index?
        for index in line.indices {
            let ch = line[index]
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == ":" && !inQuotes {
                colonIndex = index
                break
            }
        }
        guard let colonIndex = colonIndex else { return nil }
        let head = line[line.startIndex..<colonIndex]
        let value = String(line[line.index(after: colonIndex)...])
        var name = head
        var params: [String: String] = [:]
        if let semicolon = head.firstIndex(of: ";") {
            name = head[head.startIndex..<semicolon]
            let rest = head[head.index(after: semicolon)...]
            for pair in splitRespectingQuotes(rest, separator: ";") {
                let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard keyValue.count == 2 else { continue }
                let key = String(keyValue[0]).uppercased()
                var rawValue = String(keyValue[1])
                if rawValue.hasPrefix("\""), rawValue.hasSuffix("\""), rawValue.count >= 2 {
                    rawValue = String(rawValue.dropFirst().dropLast())
                }
                params[key] = rawValue
            }
        }
        return ICSProperty(name: String(name).uppercased(), params: params, value: value)
    }

    private static func splitRespectingQuotes(_ text: Substring, separator: Character) -> [String] {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        for ch in text {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == separator, !inQuotes {
                segments.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        segments.append(current)
        return segments
    }

    static func makeEvent(_ properties: [ICSProperty]) -> ParsedEvent? {
        var sink: [String] = []
        return makeEvent(properties, warnings: &sink)
    }

    static func makeEvent(_ properties: [ICSProperty], warnings: inout [String]) -> ParsedEvent? {
        var uid = ""
        var title = ""
        var location = ""
        var description = ""
        var altDescription = ""
        var conference = ""
        var url = ""
        var attach = ""
        var status = ""
        var isAllDay = false
        var dtStart: Date?
        var dtEnd: Date?
        var tz: TimeZone?
        var duration: TimeInterval?
        var rruleText = ""
        var exdateProperties: [ICSProperty] = []
        var rdateProperties: [ICSProperty] = []
        var recurrenceIDProperty: ICSProperty?
        var recurrenceRange: String?
        var sequence = 0
        var dtstamp: Date?
        var unsupportedRRULE: String?
        for property in properties {
            if consumedDateProperties.contains(property.name), hasUnknownZone(property) {
                warnings.append("Event \(uid.isEmpty ? "without UID" : "“\(uid)”") skipped: unknown time zone \(property.params["TZID"] ?? "?")")
                return nil
            }
            switch property.name {
            case "UID":
                uid = property.value
            case "SUMMARY":
                title = unescape(property.value)
            case "LOCATION":
                location = unescape(property.value)
            case "DESCRIPTION":
                description = unescape(property.value)
            case "X-ALT-DESC":
                if altDescription.isEmpty { altDescription = unescape(property.value) }
            case "ATTACH":
                let candidate = property.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if attach.isEmpty, property.params["ENCODING"]?.uppercased() != "BASE64",
                   let parsed = URL(string: candidate), parsed.scheme?.lowercased() == "http" || parsed.scheme?.lowercased() == "https" {
                    attach = candidate
                }
            case "STATUS":
                status = property.value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            case "DTSTART":
                let parsed = parseDate(property, fallbackTimeZone: tz)
                dtStart = parsed.date
                tz = parsed.tz
                isAllDay = parsed.allDay
            case "DTEND":
                dtEnd = parseDate(property, fallbackTimeZone: tz).date
            case "DURATION":
                duration = parseDuration(property.value)
            case "RRULE":
                rruleText = property.value
            case "EXDATE":
                exdateProperties.append(property)
            case "RDATE":
                rdateProperties.append(property)
            case "RECURRENCE-ID":
                recurrenceIDProperty = property
                recurrenceRange = property.params["RANGE"]
            case "SEQUENCE":
                sequence = Int(property.value.trimmingCharacters(in: .whitespaces)) ?? 0
            case "DTSTAMP":
                dtstamp = parseDate(property).date
            case "CONFERENCE", "X-GOOGLE-CONFERENCE", "X-MICROSOFT-SKYPETEAMSMEETINGURL", "X-MICROSOFT-ONLINEMEETINGURL":
                // First *valid* link wins — a garbage first property must not
                // hide a usable later one.
                let candidate = property.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if conference.isEmpty, LinkExtractor.joinURL(candidate) != nil {
                    conference = candidate
                }
            case "URL":
                url = property.value.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                break
            }
        }
        let rule = rruleText.isEmpty ? nil : RRULE.parse(rruleText, eventTz: tz)
        if !rruleText.isEmpty, rule == nil {
            unsupportedRRULE = rruleText
        }
        // Events need a start unless they are recurrence overrides (a bare
        // RECURRENCE-ID + STATUS:CANCELLED cancellation may omit DTSTART).
        let ridBestEffort = recurrenceIDProperty.flatMap { parseDate($0, fallbackTimeZone: tz).date }
        if dtStart == nil, recurrenceIDProperty == nil { return nil }
        if uid.isEmpty {
            let anchor = dtStart?.timeIntervalSince1970 ?? ridBestEffort?.timeIntervalSince1970 ?? 0
            uid = "\(title)-\(Int(anchor))"
        }
        // Duration precedence: valid DURATION > positive DTEND-DTSTART > 1h.
        // Invalid (negative/zero/malformed) values never shrink the event.
        let explicit = duration.flatMap { $0 > 0 ? $0 : nil }
        let fromEnd = dtEnd.flatMap { end -> TimeInterval? in
            guard let start = dtStart else { return nil }
            let delta = end.timeIntervalSince(start)
            return delta > 0 ? delta : nil
        }
        let computedDuration = explicit ?? fromEnd ?? 3600
        return ParsedEvent(
            uid: uid,
            title: title,
            location: location.isEmpty ? nil : location,
            description: description.isEmpty ? nil : description,
            altDescription: altDescription.isEmpty ? nil : altDescription,
            conference: conference.isEmpty ? nil : conference,
            url: url.isEmpty ? nil : url,
            attach: attach.isEmpty ? nil : attach,
            status: status,
            isAllDay: isAllDay,
            dtStart: dtStart,
            tz: tz,
            durationSeconds: max(60, computedDuration),
            hasExplicitEnd: explicit != nil || fromEnd != nil,
            rrule: rule,
            exdates: [],
            recurrenceID: ridBestEffort,
            sequence: sequence,
            dtstamp: dtstamp
        ).withRawRecurrence(
            exdateProperties: exdateProperties,
            rdateProperties: rdateProperties,
            recurrenceIDProperty: recurrenceIDProperty,
            recurrenceRange: recurrenceRange,
            unsupportedRRULE: unsupportedRRULE
        )
    }

    /// True when the property carries a `TZID` parameter this app cannot resolve.
    private static func hasUnknownZone(_ property: ICSProperty) -> Bool {
        guard let tzid = property.params["TZID"] else { return false }
        return timeZone(fromTZID: tzid) == nil
    }

    static func parseDate(_ property: ICSProperty, fallbackTimeZone: TimeZone? = nil) -> (date: Date?, tz: TimeZone?, allDay: Bool) {
        let value = property.value.trimmingCharacters(in: .whitespaces)
        if property.params["VALUE"] == "DATE" || (value.count == 8 && !value.contains("T")) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd"
            return (formatter.date(from: value), nil, true)
        }
        var text = value
        var zone: TimeZone?
        if text.hasSuffix("Z") {
            text = String(text.dropLast())
            zone = TimeZone(identifier: "UTC")
        } else if let tzid = property.params["TZID"] {
            zone = timeZone(fromTZID: tzid)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone ?? fallbackTimeZone ?? .current
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return (formatter.date(from: text), zone, false)
    }

    /// Pragmatic Windows/Outlook TZID → IANA mapping (the names Outlook
    /// publishes in feeds). Unknown TZIDs resolve to nil → the event is
    /// skipped with a visible warning instead of being shown at the wrong time.
    static let windowsTZIDMap: [String: String] = [
        "Dateline Standard Time": "Etc/GMT+12",
        "UTC-11": "Etc/GMT+11",
        "Aleutian Standard Time": "America/Adak",
        "Hawaiian Standard Time": "Pacific/Honolulu",
        "Marquesas Standard Time": "Pacific/Marquesas",
        "Alaskan Standard Time": "America/Anchorage",
        "UTC-09": "Etc/GMT+9",
        "Pacific Standard Time (Mexico)": "America/Tijuana",
        "UTC-08": "Etc/GMT+8",
        "Pacific Standard Time": "America/Los_Angeles",
        "US Mountain Standard Time": "America/Phoenix",
        "Mountain Standard Time (Mexico)": "America/Chihuahua",
        "UTC-07": "Etc/GMT+7",
        "Mountain Standard Time": "America/Denver",
        "Central America Standard Time": "America/Guatemala",
        "Central Standard Time": "America/Chicago",
        "Easter Island Standard Time": "Pacific/Easter",
        "Central Standard Time (Mexico)": "America/Mexico_City",
        "Canada Central Standard Time": "America/Regina",
        "SA Pacific Standard Time": "America/Bogota",
        "Eastern Standard Time": "America/New_York",
        "US Eastern Standard Time": "America/Indianapolis",
        "Venezuela Standard Time": "America/Caracas",
        "Paraguay Standard Time": "America/Asuncion",
        "Atlantic Standard Time": "America/Halifax",
        "Central Brazilian Standard Time": "America/Cuiaba",
        "SA Western Standard Time": "America/La_Paz",
        "Pacific SA Standard Time": "America/Santiago",
        "Newfoundland Standard Time": "America/St_Johns",
        "E. South America Standard Time": "America/Sao_Paulo",
        "Argentina Standard Time": "America/Buenos_Aires",
        "SA Eastern Standard Time": "America/Cayenne",
        "Greenland Standard Time": "America/Nuuk",
        "Montevideo Standard Time": "America/Montevideo",
        "Bahia Standard Time": "America/Bahia",
        "UTC-02": "Etc/GMT+2",
        "Azores Standard Time": "Atlantic/Azores",
        "Cape Verde Standard Time": "Atlantic/Cape_Verde",
        "UTC": "UTC",
        "Morocco Standard Time": "Africa/Casablanca",
        "GMT Standard Time": "Europe/London",
        "Greenwich Standard Time": "Atlantic/Reykjavik",
        "W. Europe Standard Time": "Europe/Berlin",
        "Central Europe Standard Time": "Europe/Prague",
        "Romance Standard Time": "Europe/Paris",
        "Central European Standard Time": "Europe/Warsaw",
        "W. Central Africa Standard Time": "Africa/Lagos",
        "Namibia Standard Time": "Africa/Windhoek",
        "Jordan Standard Time": "Asia/Amman",
        "GTB Standard Time": "Europe/Bucharest",
        "Middle East Standard Time": "Asia/Beirut",
        "Egypt Standard Time": "Africa/Cairo",
        "E. Europe Standard Time": "Europe/Chisinau",
        "Syria Standard Time": "Asia/Damascus",
        "West Bank Standard Time": "Asia/Hebron",
        "South Africa Standard Time": "Africa/Johannesburg",
        "FLE Standard Time": "Europe/Kiev",
        "Turkey Standard Time": "Europe/Istanbul",
        "Israel Standard Time": "Asia/Jerusalem",
        "Kaliningrad Standard Time": "Europe/Kaliningrad",
        "Libya Standard Time": "Africa/Tripoli",
        "Arabic Standard Time": "Asia/Baghdad",
        "Arab Standard Time": "Asia/Riyadh",
        "Belarus Standard Time": "Europe/Minsk",
        "Russian Standard Time": "Europe/Moscow",
        "E. Africa Standard Time": "Africa/Nairobi",
        "Iran Standard Time": "Asia/Tehran",
        "Arabian Standard Time": "Asia/Dubai",
        "Azerbaijan Standard Time": "Asia/Baku",
        "Russia Time Zone 3": "Europe/Samara",
        "Mauritius Standard Time": "Indian/Mauritius",
        "Georgian Standard Time": "Asia/Tbilisi",
        "Caucasus Standard Time": "Asia/Yerevan",
        "Afghanistan Standard Time": "Asia/Kabul",
        "West Asia Standard Time": "Asia/Karachi",
        "Ekaterinburg Standard Time": "Asia/Yekaterinburg",
        "India Standard Time": "Asia/Calcutta",
        "Sri Lanka Standard Time": "Asia/Colombo",
        "Nepal Standard Time": "Asia/Katmandu",
        "Central Asia Standard Time": "Asia/Almaty",
        "Bangladesh Standard Time": "Asia/Dhaka",
        "N. Central Asia Standard Time": "Asia/Novosibirsk",
        "Myanmar Standard Time": "Asia/Rangoon",
        "SE Asia Standard Time": "Asia/Bangkok",
        "North Asia Standard Time": "Asia/Krasnoyarsk",
        "China Standard Time": "Asia/Shanghai",
        "North Asia East Standard Time": "Asia/Irkutsk",
        "Singapore Standard Time": "Asia/Singapore",
        "W. Australia Standard Time": "Australia/Perth",
        "Taipei Standard Time": "Asia/Taipei",
        "Ulaanbaatar Standard Time": "Asia/Ulaanbaatar",
        "Tokyo Standard Time": "Asia/Tokyo",
        "Korea Standard Time": "Asia/Seoul",
        "Yakutsk Standard Time": "Asia/Yakutsk",
        "Cen. Australia Standard Time": "Australia/Adelaide",
        "AUS Central Standard Time": "Australia/Darwin",
        "E. Australia Standard Time": "Australia/Brisbane",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "West Pacific Standard Time": "Pacific/Port_Moresby",
        "Tasmania Standard Time": "Australia/Hobart",
        "Vladivostok Standard Time": "Asia/Vladivostok",
        "Magadan Standard Time": "Asia/Magadan",
        "Central Pacific Standard Time": "Pacific/Guadalcanal",
        "New Zealand Standard Time": "Pacific/Auckland",
        "Fiji Standard Time": "Pacific/Fiji",
        "Kamchatka Standard Time": "Asia/Kamchatka",
        "Tonga Standard Time": "Pacific/Tongatapu",
    ]

    static func timeZone(fromTZID tzid: String) -> TimeZone? {
        if let tz = TimeZone(identifier: tzid) { return tz }
        if let mapped = windowsTZIDMap[tzid], let tz = TimeZone(identifier: mapped) { return tz }
        // Microsoft sometimes prefixes a GUID: "/microsoft.com/…/W. Europe Standard Time"
        if let last = tzid.split(separator: "/").last, let tz = windowsTZIDMap[String(last)] {
            return TimeZone(identifier: tz)
        }
        let parts = tzid.split(separator: "/").map(String.init)
        if parts.count >= 2 {
            let candidate = parts.suffix(2).joined(separator: "/")
            if let tz = TimeZone(identifier: candidate) { return tz }
        }
        return TimeZone(abbreviation: tzid)
    }

    /// RFC 5545 duration (`[+|-]P[nW]` or `[+|-]P[nD][T[nH][nM][nS]]`). Months are not part
    /// of the format — `P1M` is invalid. Returns nil for malformed input and
    /// for anything with a non-positive total (callers treat that as invalid).
    static func parseDuration(_ value: String) -> TimeInterval? {
        let text = value.trimmingCharacters(in: .whitespaces)
        var sign = 1.0
        var body = Substring(text)
        if body.hasPrefix("-") { sign = -1; body = body.dropFirst() }
        else if body.hasPrefix("+") { body = body.dropFirst() }
        guard body.hasPrefix("P") else { return nil }
        body = body.dropFirst()
        var total = 0.0
        var sawComponent = false
        var sawTimeComponent = false
        var inTime = false
        var sawWeek = false
        var sawDay = false
        var lastTimeRank = 0
        var number = ""
        for ch in body {
            if ch.isNumber {
                number.append(ch)
                continue
            }
            if ch == "T" {
                guard !inTime, !sawWeek, number.isEmpty else { return nil }
                inTime = true
                continue
            }
            guard !number.isEmpty, let n = Double(number) else { return nil }
            switch ch {
            case "W":
                guard !inTime, !sawWeek, !sawDay, !sawComponent else { return nil }
                sawWeek = true; total += n * 604800
            case "D":
                guard !inTime, !sawWeek, !sawDay else { return nil }
                sawDay = true; total += n * 86400
            case "H":
                guard inTime, lastTimeRank < 1 else { return nil }
                lastTimeRank = 1; total += n * 3600; sawTimeComponent = true
            case "M":
                guard inTime, lastTimeRank < 2 else { return nil }
                lastTimeRank = 2; total += n * 60; sawTimeComponent = true // no months in RFC durations
            case "S":
                guard inTime, lastTimeRank < 3 else { return nil }
                lastTimeRank = 3; total += n; sawTimeComponent = true
            default: return nil
            }
            sawComponent = true
            number = ""
        }
        guard sawComponent, number.isEmpty, !inTime || sawTimeComponent else { return nil }
        return sign * total
    }

    /// Single left-to-right pass — later replacements can never reinterpret an
    /// escape produced by an earlier one (`\\n` stays backslash + n).
    static func unescape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        var iterator = value.makeIterator()
        while let ch = iterator.next() {
            if ch != "\\" {
                out.append(ch)
                continue
            }
            guard let next = iterator.next() else {
                out.append(ch) // trailing backslash → literal
                break
            }
            switch next {
            case "n", "N": out.append("\n")
            case ",": out.append(",")
            case ";": out.append(";")
            case "\\": out.append("\\")
            default:
                out.append(ch)
                out.append(next)
            }
        }
        return out
    }
}

extension ParsedEvent {
    /// Attaches raw recurrence properties + parser diagnostics (kept out of the
    /// memberwise init used by the native-calendar path, which has none of them).
    func withRawRecurrence(exdateProperties: [ICSProperty], rdateProperties: [ICSProperty], recurrenceIDProperty: ICSProperty?, recurrenceRange: String?, unsupportedRRULE: String?) -> ParsedEvent {
        var copy = self
        copy.exdateProperties = exdateProperties
        copy.rdateProperties = rdateProperties
        copy.recurrenceIDProperty = recurrenceIDProperty
        copy.recurrenceIDHasExplicitZone = recurrenceIDProperty.map { $0.params["TZID"] != nil || $0.value.trimmingCharacters(in: .whitespaces).hasSuffix("Z") } ?? false
        copy.recurrenceRange = recurrenceRange
        copy.unsupportedRRULEText = unsupportedRRULE
        return copy
    }
}

// MARK: - Recurrence expansion

enum RRULEExpander {
    /// Hard per-event cap on calendar-day/month operations (a COUNT rule
    /// anchored decades ago is the only way to hit it).
    static let maxIterationsPerEvent = 20_000

    static func occurrences(of event: ParsedEvent, windowStart: Date, windowEnd: Date) -> [Date] {
        var budget = maxIterationsPerEvent
        return occurrences(of: event, windowStart: windowStart, windowEnd: windowEnd, budget: &budget)
    }

    /// All occurrences within `[windowStart, windowEnd]` (bounds inclusive and
    /// enforced exactly). `budget` bounds the work spent per event and is
    /// decremented by the iterations consumed — the caller pools it across the
    /// whole feed.
    static func occurrences(of event: ParsedEvent, windowStart: Date, windowEnd: Date, budget: inout Int) -> [Date] {
        guard let dtStart = event.dtStart else { return [] }
        guard let rule = event.rrule else { return [dtStart] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = event.tz ?? .current
        cal.firstWeekday = rule.wkst
        let time = cal.dateComponents([.hour, .minute, .second], from: dtStart)
        let anchor = cal.startOfDay(for: dtStart)
        // Fast-forward: without COUNT, occurrences before the window are never
        // emitted, so jump straight to the window instead of walking decades of
        // days (which would also exhaust the budget and silently drop the event).
        // With COUNT every occurrence must be counted from the anchor.
        let firstDay = rule.count == nil ? max(anchor, cal.startOfDay(for: windowStart)) : anchor
        let lastDay = cal.startOfDay(for: windowEnd)
        let interval = max(1, rule.interval)
        var result: [Date] = []
        var produced = 0
        var exhausted = false

        @discardableResult func consider(_ day: Date) -> Bool {
            guard budget > 0 else { exhausted = true; return false }
            budget -= 1
            guard let occ = cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day), occ >= dtStart else { return true }
            if let until = rule.until, occ > until { exhausted = true; return false }
            produced += 1
            if occ >= windowStart, occ <= windowEnd, !event.exdates.contains(occ) {
                result.append(occ)
            }
            if let count = rule.count, produced >= count { exhausted = true; return false }
            return true
        }

        // DTSTART is always the first recurrence-set member, even when it does
        // not satisfy a BYxxx filter. COUNT includes it.
        consider(anchor)

        switch rule.freq {
        case .daily, .weekly:
            var day = firstDay
            while day <= lastDay, !exhausted {
                let matches = rule.freq == .daily
                    ? matchesDaily(day, cal: cal, rule: rule, anchor: anchor, interval: interval)
                    : matchesWeekly(day, cal: cal, rule: rule, anchor: anchor, anchorWeekday: cal.component(.weekday, from: anchor), interval: interval)
                if matches {
                    if let occurrence = cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day), occurrence != dtStart {
                        consider(day)
                    }
                } else if budget > 0 {
                    budget -= 1
                } else {
                    exhausted = true
                }
                guard budget > 0, let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        case .monthly, .yearly:
            let anchorComps = cal.dateComponents([.year, .month, .day], from: anchor)
            var month = startOfMonth(firstDay, cal: cal)
            let lastMonth = startOfMonth(lastDay, cal: cal)
            while month <= lastMonth, !exhausted {
                guard budget > 0 else { break }
                budget -= 1
                if monthsAlign(month, cal: cal, rule: rule, anchorComps: anchorComps, interval: interval) {
                    for day in matchingDays(ofMonth: month, cal: cal, rule: rule, anchorComps: anchorComps) {
                        guard day >= firstDay, day <= lastDay else { continue }
                        if let occurrence = cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day), occurrence != dtStart {
                            consider(day)
                        }
                        if exhausted { break }
                    }
                }
                guard let next = nextMonth(month, cal: cal) else { break }
                month = next
            }
        }
        return result
    }

    private static func matchesDaily(_ day: Date, cal: Calendar, rule: RRULE, anchor: Date, interval: Int) -> Bool {
        let dayDiff = cal.dateComponents([.day], from: anchor, to: day).day ?? 0
        guard dayDiff % interval == 0 else { return false }
        if !rule.byday.isEmpty {
            let weekday = cal.component(.weekday, from: day)
            return rule.byday.contains { $0.weekday == weekday }
        }
        return true
    }

    private static func matchesWeekly(_ day: Date, cal: Calendar, rule: RRULE, anchor: Date, anchorWeekday: Int, interval: Int) -> Bool {
        let anchorWeek = cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
        let dayWeek = cal.dateInterval(of: .weekOfYear, for: day)?.start ?? day
        let weeks = (cal.dateComponents([.day], from: anchorWeek, to: dayWeek).day ?? 0) / 7
        guard weeks % interval == 0 else { return false }
        let weekday = cal.component(.weekday, from: day)
        return rule.byday.isEmpty ? weekday == anchorWeekday : rule.byday.contains { $0.weekday == weekday }
    }

    private static func startOfMonth(_ day: Date, cal: Calendar) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: day)) ?? day
    }

    private static func nextMonth(_ month: Date, cal: Calendar) -> Date? {
        cal.date(byAdding: .month, value: 1, to: month)
    }

    private static func monthsAlign(_ month: Date, cal: Calendar, rule: RRULE, anchorComps: DateComponents, interval: Int) -> Bool {
        let comps = cal.dateComponents([.year, .month], from: month)
        guard let year = comps.year, let monthNumber = comps.month,
              let anchorYear = anchorComps.year, let anchorMonth = anchorComps.month else { return false }
        switch rule.freq {
        case .monthly:
            let months = (year * 12 + monthNumber) - (anchorYear * 12 + anchorMonth)
            guard months % interval == 0 else { return false }
            return rule.bymonth.isEmpty || rule.bymonth.contains(monthNumber)
        case .yearly:
            guard (year - anchorYear) % interval == 0 else { return false }
            if !rule.bymonth.isEmpty { return rule.bymonth.contains(monthNumber) }
            return rule.bymonthday.isEmpty ? monthNumber == anchorMonth : true
        default:
            return false
        }
    }

    /// Sorted start-of-days of `month` matching the MONTHLY/YEARLY day selection:
    /// BYMONTHDAY (incl. negative), ordinal/plain BYDAY, or the anchor day.
    private static func matchingDays(ofMonth month: Date, cal: Calendar, rule: RRULE, anchorComps: DateComponents) -> [Date] {
        guard let daysInMonth = cal.range(of: .day, in: .month, for: month)?.count else { return [] }
        func day(_ dom: Int) -> Date? {
            cal.date(byAdding: .day, value: dom - 1, to: month)
        }
        func monthDayMatches(_ values: [Int]) -> Set<Int> {
            var doms = Set<Int>()
            for dom in 1...daysInMonth {
                let fromEnd = daysInMonth - dom + 1
                if values.contains(dom) || values.contains(-fromEnd) { doms.insert(dom) }
            }
            return doms
        }
        func bydayMatches(_ entries: [RRULE.ByDay]) -> Set<Int> {
            var byWeekday: [Int: [Int]] = [:]
            for dom in 1...daysInMonth {
                guard let date = day(dom) else { continue }
                byWeekday[cal.component(.weekday, from: date), default: []].append(dom)
            }
            var doms = Set<Int>()
            for entry in entries {
                guard let list = byWeekday[entry.weekday] else { continue }
                if let ordinal = entry.ordinal {
                    let index = ordinal > 0 ? ordinal - 1 : list.count + ordinal
                    if index >= 0, index < list.count { doms.insert(list[index]) }
                } else {
                    doms.formUnion(list)
                }
            }
            return doms
        }
        let monthDays = rule.bymonthday.isEmpty ? nil : monthDayMatches(rule.bymonthday)
        let weekDays = rule.byday.isEmpty ? nil : bydayMatches(rule.byday)
        let candidates: Set<Int>
        if let monthDays, let weekDays {
            candidates = monthDays.intersection(weekDays)
        } else {
            candidates = monthDays ?? weekDays ?? []
        }
        var doms: Set<Int>
        if !rule.bysetpos.isEmpty {
            let sorted = candidates.sorted()
            var selected = Set<Int>()
            for position in rule.bysetpos {
                let index = position > 0 ? position - 1 : sorted.count + position
                if index >= 0, index < sorted.count { selected.insert(sorted[index]) }
            }
            doms = selected
        } else if monthDays != nil || weekDays != nil {
            doms = candidates
        } else if let anchorDay = anchorComps.day, anchorDay <= daysInMonth {
            doms = [anchorDay]
        } else {
            doms = []
        }
        return doms.sorted().compactMap(day)
    }
}

// MARK: - Meeting links

enum LinkExtractor {
    static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Picks a meeting join link for an event. Structured conference properties
    /// are authoritative. Every other field, including URL, must contain a URL
    /// with a recognized provider shape or an explicit generic join path; an
    /// arbitrary event/document/recording URL must never be labelled "Join".
    static func link(from event: ParsedEvent) -> URL? {
        if let conference = event.conference, let url = joinURL(conference) { return url }
        if let urlValue = event.url, let url = joinURL(urlValue), isMeetingLink(url) { return url }
        var candidates: [(url: URL, field: Int)] = []
        let fields: [(String?, Int)] = [
            (event.location, 0),
            (event.description, 1),
            (event.altDescription.map(decodeHTMLEntities), 2),
            (event.title, 3),
            (event.attach, 4),
        ]
        if let detector = detector {
            for (text, rank) in fields {
                guard let text, !text.isEmpty else { continue }
                for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let url = match.url,
                       let scheme = url.scheme?.lowercased(),
                       (scheme == "http" || scheme == "https"),
                       isMeetingLink(url) {
                        candidates.append((url, rank))
                    }
                }
            }
        }
        return candidates
            .sorted { $0.field < $1.field }
            .first?.url
    }

    /// Accepts an http(s) URL and also converts common native-scheme meeting links
    /// (`zoommtg://zoom.us/join?confno=…`, `msteams:/l/meetup-join/…`) into browser-usable ones.
    static func joinURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" { return url }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if scheme == "zoommtg" || scheme == "zoomus" {
            guard let host = url.host, host != "" else { return nil }
            let query = parts?.queryItems ?? []
            if let confno = query.first(where: { $0.name == "confno" })?.value, !confno.isEmpty {
                var comps = URLComponents()
                comps.scheme = "https"
                comps.host = host
                comps.path = "/j/\(confno)"
                if let pwd = query.first(where: { $0.name == "pwd" })?.value, !pwd.isEmpty {
                    comps.queryItems = [URLQueryItem(name: "pwd", value: pwd)]
                }
                return comps.url
            }
            return nil
        }
        if scheme == "msteams" || scheme == "teams" {
            guard url.path.hasPrefix("/l/") else { return nil }
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = "teams.microsoft.com"
            comps.path = url.path
            comps.query = parts?.query
            return comps.url
        }
        return nil
    }

    /// Friendly service name for a join link ("Zoom", "Google Meet", …), used as the
    /// location fallback in the reminder. Falls back to the bare host (sans www).
    static let providerNames: [String: String] = [
        "zoom.us": "Zoom", "zoom.com": "Zoom",
        "meet.google.com": "Google Meet", "hangouts.google.com": "Google Meet",
        "teams.microsoft.com": "Microsoft Teams", "teams.live.com": "Microsoft Teams",
        "webex.com": "Webex", "gotomeet.me": "GoTo Meeting", "goto.com": "GoTo Meeting",
        "meet.jit.si": "Jitsi Meet", "whereby.com": "Whereby",
        "discord.gg": "Discord", "discord.com": "Discord",
        "slack.com": "Slack", "chime.aws": "Amazon Chime", "8x8.vc": "8x8 Meet",
        "bluejeans.com": "BlueJeans", "facetime.apple.com": "FaceTime",
        "ringcentral.com": "RingCentral", "join.me": "join.me", "dialpad.com": "Dialpad",
        "uberconference.com": "UberConference", "freeconferencecall.com": "FreeConferenceCall",
        "meeting.zoho.com": "Zoho Meeting",
    ]

    static func providerName(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        for (suffix, name) in providerNames where host == suffix || host.hasSuffix("." + suffix) {
            return name
        }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    /// Human-facing location for the fullscreen reminder. Calendar providers
    /// frequently put the conference URL itself in LOCATION; repeating that
    /// long URL beside a Join button is not a useful place name, so show the
    /// friendly provider instead. Real locations always win.
    static func displayLocation(_ location: String?, link: URL?) -> String? {
        if let location {
            let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !isJoinLinkOnlyText(trimmed, link: link) {
                return trimmed
            }
        }
        return link.flatMap(providerName)
    }

    /// Conservative URL classifier. Provider homepages, recordings and support
    /// pages are not meetings merely because they live on a meeting provider.
    /// Unknown/self-hosted services remain supported through explicit join path
    /// shapes such as `/join/42`, `/meet/room` and `/j/123`.
    static func isMeetingLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let path = url.path.lowercased()
        let segments = path.split(separator: "/").map(String.init)

        if segments.contains(where: { $0 == "j" || $0 == "join" || $0 == "meet" || $0 == "meetup-join" }) {
            return true
        }

        if host == "meet.google.com" || host.hasSuffix(".meet.google.com") {
            let code = path.split(separator: "/").first.map(String.init) ?? ""
            let groups = code.split(separator: "-")
            return groups.count == 3 && groups.allSatisfy { !$0.isEmpty }
        }
        if host == "hangouts.google.com" || host.hasSuffix(".hangouts.google.com") {
            return path.split(separator: "/").count >= 2
        }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "zoom.com" || host.hasSuffix(".zoom.com") {
            return path.hasPrefix("/my/") || path.hasPrefix("/wc/join/") || path.hasPrefix("/w/")
        }
        if host == "teams.microsoft.com" || host.hasSuffix(".teams.microsoft.com") ||
           host == "teams.live.com" || host.hasSuffix(".teams.live.com") {
            return path.hasPrefix("/l/meetup/")
        }
        if host == "meet.jit.si" || host.hasSuffix(".meet.jit.si") ||
           host == "whereby.com" || host.hasSuffix(".whereby.com") ||
           host == "facetime.apple.com" || host.hasSuffix(".facetime.apple.com") ||
           host == "discord.gg" || host.hasSuffix(".discord.gg") {
            return !path.split(separator: "/").isEmpty
        }
        if host == "gotomeet.me" || host.hasSuffix(".gotomeet.me") || host == "meet.goto.com" ||
           host == "8x8.vc" || host.hasSuffix(".8x8.vc") || host == "join.me" || host.hasSuffix(".join.me") {
            return !path.split(separator: "/").isEmpty
        }
        if host == "bluejeans.com" || host.hasSuffix(".bluejeans.com") {
            let room = path.split(separator: "/").first.map(String.init) ?? ""
            return !room.isEmpty && room.allSatisfy(\.isNumber)
        }
        if host == "meetings.dialpad.com" || host.hasSuffix(".meetings.dialpad.com") {
            return path.hasPrefix("/room/")
        }
        if host == "app.chime.aws" || host.hasSuffix(".app.chime.aws") {
            return path.hasPrefix("/meetings/")
        }
        if host == "app.slack.com" || host.hasSuffix(".app.slack.com") {
            return path.hasPrefix("/huddle/")
        }
        if host == "freeconferencecall.com" || host.hasSuffix(".freeconferencecall.com") {
            return path.hasPrefix("/wall/")
        }
        return false
    }

    /// True when every non-empty line of `text` is either Apple's conference decoration
    /// (`----( Video Call )----`, `---===---`, …) or the event's join link itself — i.e.
    /// the description carries no information beyond the Join button and should be
    /// hidden wherever notes are displayed. Link *extraction* is unaffected.
    static func isJoinLinkOnlyText(_ text: String, link: URL?) -> Bool {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        for line in lines {
            if isDecorationLine(line) { continue }
            if let link, line == link.absoluteString { continue }
            return false
        }
        return true
    }

    /// Ruler lines (`---===---`, `-----`) and decorated labels (`----( Video Call )----`).
    /// The dashes are required: a bare parenthetical like "( see doc )" is real content.
    static func isDecorationLine(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        if line.allSatisfy({ $0 == "-" || $0 == "=" }) { return true }
        var inner = line
        var leading = 0
        while inner.hasPrefix("-") { inner.removeFirst(); leading += 1 }
        var trailing = 0
        while inner.hasSuffix("-") { inner.removeLast(); trailing += 1 }
        guard leading >= 2, trailing >= 2 else { return false }
        let label = inner.trimmingCharacters(in: .whitespaces)
        return label.hasPrefix("(") && label.hasSuffix(")") && label.count >= 3
    }

    static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#13;", with: "")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

// MARK: - Feed → meetings

enum ICSBuilder {
    static let maxEventsPerFeed = 10_000
    static let maxFeedRecurrenceBudget = 200_000

    static func meetings(fromICS text: String, subscription: CalendarSubscription, now: Date) -> (events: [MeetingEvent], warnings: [String]) {
        let resolvedHex = subscription.colorHex.isEmpty ? Palette.hex(for: subscription.colorIndex) : subscription.colorHex
        let windowStart = now.addingTimeInterval(-6 * 3600)
        let windowEnd = now.addingTimeInterval(14 * 86400)
        let parsed = ICSParser.parse(text)
        var warnings = parsed.warnings
        var result: [MeetingEvent] = []
        var feedBudget = maxFeedRecurrenceBudget
        var budgetWarned = false
        var eventCapWarned = false
        var seenEventKeys = Set<String>()
        let groups = Dictionary(grouping: parsed.events, by: { $0.uid })
        for (_, events) in groups {
            guard result.count < maxEventsPerFeed else {
                if !eventCapWarned {
                    eventCapWarned = true
                    warnings.append("Feed has more than \(maxEventsPerFeed) events — truncated")
                }
                break
            }
            let master = latestRevision(of: events.filter { $0.recurrenceIDProperty == nil && $0.dtStart != nil })
            var occurrences: [(start: Date, event: ParsedEvent)] = []
            if let originalMaster = master {
                var m = originalMaster
                m.exdates = Self.resolvedDates(m.exdateProperties, masterTz: m.tz)
                if m.unsupportedRRULEText != nil {
                    warnings.append("Unsupported RRULE \"\(m.unsupportedRRULEText!)\" — “\(m.title)” shows only its first occurrence")
                }
                guard m.status != "CANCELLED" else { continue }
                if m.rrule != nil, !m.isAllDay {
                    let initialBudget = min(feedBudget, RRULEExpander.maxIterationsPerEvent)
                    var eventBudget = initialBudget
                    let dates = RRULEExpander.occurrences(of: m, windowStart: windowStart, windowEnd: windowEnd, budget: &eventBudget)
                    feedBudget -= initialBudget - eventBudget
                    if feedBudget <= 0, !budgetWarned {
                        budgetWarned = true
                        warnings.append("Recurrence workload limit reached — some events may be missing")
                    }
                    if eventBudget <= 0 {
                        warnings.append("“\(m.title)” reached its recurrence workload limit — some occurrences may be missing")
                    }
                    for date in dates { occurrences.append((date, m)) }
                } else if !m.isAllDay, let start = m.dtStart, start >= windowStart, start <= windowEnd {
                    occurrences.append((start, m))
                }
                // RDATE: extra occurrence dates beyond the rule.
                if !m.isAllDay {
                    let resolvedRDates = Self.resolvedDates(m.rdateProperties, masterTz: m.tz, limit: maxEventsPerFeed + 1)
                    if resolvedRDates.count > maxEventsPerFeed, !eventCapWarned {
                        eventCapWarned = true
                        warnings.append("Feed has more than \(maxEventsPerFeed) events — recurrence dates truncated")
                    }
                    var occurrenceStarts = Set(occurrences.map(\.start))
                    for rdate in resolvedRDates.prefix(maxEventsPerFeed) {
                        guard rdate >= windowStart, rdate <= windowEnd, rdate >= (m.dtStart ?? rdate),
                              !m.exdates.contains(rdate),
                              occurrenceStarts.insert(rdate).inserted else { continue }
                        occurrences.append((rdate, m))
                    }
                }
            }
            // Detached recurrence overrides.
            var overrides = events.filter { $0.recurrenceIDProperty != nil }
            overrides.sort { revisionKey($0) > revisionKey($1) }
            var seenRids = Set<Date>()
            for override in overrides {
                if let range = override.recurrenceRange {
                    warnings.append("RECURRENCE-ID RANGE=\(range) is not supported — override ignored")
                    continue
                }
                guard let rid = Self.resolvedRecurrenceID(of: override, masterTz: master?.tz) else { continue }
                guard seenRids.insert(rid).inserted else { continue } // duplicate revision
                if let index = occurrences.firstIndex(where: { $0.start == rid }) {
                    occurrences.remove(at: index)
                }
                guard override.status != "CANCELLED" else { continue }
                guard !override.isAllDay else { continue }
                let start = override.dtStart ?? rid
                guard start >= windowStart, start <= windowEnd else { continue }
                occurrences.append((start, Self.inheriting(override, from: master)))
            }
            for occurrence in occurrences {
                let eventKey = "\(occurrence.event.uid)|\(Int(occurrence.start.timeIntervalSince1970))"
                guard seenEventKeys.insert(eventKey).inserted else { continue }
                guard result.count < maxEventsPerFeed else {
                    if !eventCapWarned {
                        eventCapWarned = true
                        warnings.append("Feed has more than \(maxEventsPerFeed) events — truncated")
                    }
                    break
                }
                let end = occurrence.start.addingTimeInterval(occurrence.event.durationSeconds)
                result.append(MeetingEvent(
                    uid: occurrence.event.uid,
                    title: occurrence.event.title,
                    start: occurrence.start,
                    end: end,
                    location: occurrence.event.location,
                    notes: occurrence.event.description,
                    link: LinkExtractor.link(from: occurrence.event),
                    calendarID: subscription.id,
                    calendarName: subscription.name,
                    colorIndex: subscription.colorIndex,
                    colorHex: resolvedHex
                ))
            }
        }
        let events = result
            .filter { $0.end > windowStart }
            .sorted { ($0.start, $0.title, $0.uid) < ($1.start, $1.title, $1.uid) }
        return (events, warnings)
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
    private static func resolvedDates(_ properties: [ICSProperty], masterTz: TimeZone?, limit: Int? = nil) -> [Date] {
        var dates: [Date] = []
        for property in properties {
            for part in property.value.split(separator: ",") {
                let piece = ICSProperty(name: property.name, params: property.params, value: String(part))
                if let date = ICSParser.parseDate(piece, fallbackTimeZone: masterTz).date {
                    dates.append(date)
                    if let limit, dates.count >= limit { return dates }
                }
            }
        }
        return dates
    }

    private static func resolvedRecurrenceID(of override: ParsedEvent, masterTz: TimeZone?) -> Date? {
        guard let property = override.recurrenceIDProperty else { return nil }
        if override.recurrenceIDHasExplicitZone { return override.recurrenceID }
        return ICSParser.parseDate(property, fallbackTimeZone: masterTz).date
    }

    /// A detached override inherits omitted fields from its master: title,
    /// location, notes, link properties, and duration/end.
    private static func inheriting(_ override: ParsedEvent, from master: ParsedEvent?) -> ParsedEvent {
        guard let master else { return override }
        var copy = override
        if copy.title.isEmpty { copy.title = master.title }
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
