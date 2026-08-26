import Foundation

struct ICSProperty {
    let name: String
    let params: [String: String]
    let value: String
}

struct RRULE {
    var freq = ""
    var interval = 1
    var count: Int?
    var until: Date?
    var byday: [Int] = []
    var bymonthday: [Int] = []

    static let weekdayMap: [String: Int] = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    static func parse(_ text: String, eventTz: TimeZone?) -> RRULE? {
        var rule = RRULE()
        for pair in text.split(separator: ";") {
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2 else { continue }
            let key = String(keyValue[0]).uppercased()
            let value = String(keyValue[1])
            switch key {
            case "FREQ":
                rule.freq = value.uppercased()
            case "INTERVAL":
                rule.interval = max(1, Int(value) ?? 1)
            case "COUNT":
                rule.count = Int(value)
            case "UNTIL":
                rule.until = parseUntil(value, eventTz: eventTz)
            case "BYDAY":
                var days: [Int] = []
                for token in value.split(separator: ",") {
                    let name = String(token.suffix(2)).uppercased()
                    if let day = weekdayMap[name] { days.append(day) }
                }
                rule.byday = days
            case "BYMONTHDAY":
                rule.bymonthday = value.split(separator: ",").compactMap { Int($0) }
            default:
                break
            }
        }
        guard !rule.freq.isEmpty else { return nil }
        return rule
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

struct ParsedEvent {
    var uid: String
    var title: String
    var location: String?
    var description: String?
    var conference: String?
    var url: String?
    var status: String
    var isAllDay: Bool
    var dtStart: Date?
    var tz: TimeZone?
    var durationSeconds: TimeInterval
    var rrule: RRULE?
    var exdates: [Date]
    var recurrenceID: Date?
}

enum ICSParser {
    static func parse(_ text: String) -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        var current: [ICSProperty] = []
        var inEvent = false
        for line in unfolded(text) {
            if line == "BEGIN:VEVENT" {
                inEvent = true
                current = []
            } else if line == "END:VEVENT" {
                if inEvent, let event = makeEvent(current) { events.append(event) }
                inEvent = false
                current = []
            } else if inEvent, !line.isEmpty, let property = splitProperty(line) {
                current.append(property)
            }
        }
        return events
    }

    static func unfolded(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if !lines.isEmpty {
                    lines[lines.count - 1].append(contentsOf: line.dropFirst())
                    continue
                }
            }
            lines.append(line)
        }
        return lines
    }

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
            for pair in rest.split(separator: ";") {
                let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard keyValue.count == 2 else { continue }
                let key = String(keyValue[0]).uppercased()
                let rawValue = String(keyValue[1])
                params[key] = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return ICSProperty(name: String(name).uppercased(), params: params, value: value)
    }

    static func makeEvent(_ properties: [ICSProperty]) -> ParsedEvent? {
        var uid = ""
        var title = ""
        var location = ""
        var description = ""
        var conference = ""
        var url = ""
        var status = ""
        var isAllDay = false
        var dtStart: Date?
        var dtEnd: Date?
        var tz: TimeZone?
        var duration: TimeInterval?
        var rruleText = ""
        var exdates: [Date] = []
        var recurrenceID: Date?
        for property in properties {
            switch property.name {
            case "UID":
                uid = property.value
            case "SUMMARY":
                title = unescape(property.value)
            case "LOCATION":
                location = unescape(property.value)
            case "DESCRIPTION":
                description = unescape(property.value)
            case "STATUS":
                status = property.value.uppercased()
            case "DTSTART":
                let parsed = parseDate(property)
                dtStart = parsed.date
                tz = parsed.tz
                isAllDay = parsed.allDay
            case "DTEND":
                dtEnd = parseDate(property).date
            case "DURATION":
                duration = parseDuration(property.value)
            case "RRULE":
                rruleText = property.value
            case "EXDATE":
                for part in property.value.split(separator: ",") {
                    if let date = parseDate(ICSProperty(name: "X", params: property.params, value: String(part))).date {
                        exdates.append(date)
                    }
                }
            case "RECURRENCE-ID":
                recurrenceID = parseDate(property).date
            case "CONFERENCE", "X-GOOGLE-CONFERENCE", "X-MICROSOFT-SKYPETEAMSMEETINGURL", "X-MICROSOFT-ONLINEMEETINGURL":
                if conference.isEmpty { conference = property.value.trimmingCharacters(in: .whitespacesAndNewlines) }
            case "URL":
                url = property.value.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                break
            }
        }
        guard let start = dtStart else { return nil }
        if uid.isEmpty { uid = "\(title)-\(start.timeIntervalSince1970)" }
        let computedDuration = duration ?? dtEnd.map { $0.timeIntervalSince(start) } ?? 3600
        let rule = rruleText.isEmpty ? nil : RRULE.parse(rruleText, eventTz: tz)
        return ParsedEvent(
            uid: uid,
            title: title,
            location: location.isEmpty ? nil : location,
            description: description.isEmpty ? nil : description,
            conference: conference.isEmpty ? nil : conference,
            url: url.isEmpty ? nil : url,
            status: status,
            isAllDay: isAllDay,
            dtStart: start,
            tz: tz,
            durationSeconds: max(60, computedDuration),
            rrule: rule,
            exdates: exdates,
            recurrenceID: recurrenceID
        )
    }

    static func parseDate(_ property: ICSProperty) -> (date: Date?, tz: TimeZone?, allDay: Bool) {
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
        formatter.timeZone = zone ?? .current
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return (formatter.date(from: text), zone, false)
    }

    static func timeZone(fromTZID tzid: String) -> TimeZone? {
        if let tz = TimeZone(identifier: tzid) { return tz }
        let parts = tzid.split(separator: "/").map(String.init)
        if parts.count >= 2 {
            let candidate = parts.suffix(2).joined(separator: "/")
            if let tz = TimeZone(identifier: candidate) { return tz }
        }
        return TimeZone(abbreviation: tzid)
    }

    static func parseDuration(_ value: String) -> TimeInterval? {
        guard value.hasPrefix("P") || value.hasPrefix("-P") || value.hasPrefix("+P") else { return nil }
        var sign = 1.0
        var body = value
        if body.hasPrefix("-") { sign = -1; body = String(body.dropFirst()) }
        else if body.hasPrefix("+") { body = String(body.dropFirst()) }
        var total = 0.0
        var number = ""
        var inTime = false
        for ch in body.dropFirst() {
            if ch.isNumber { number.append(ch); continue }
            guard let n = Double(number) else { return nil }
            switch ch {
            case "W": total += n * 604800
            case "D": total += n * 86400
            case "H": total += n * 3600
            case "M": total += inTime ? n * 60 : n * 2592000
            case "S": total += n
            case "T": inTime = true
            default: return nil
            }
            number = ""
        }
        return sign * total
    }

    static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

enum RRULEExpander {
    static func occurrences(of event: ParsedEvent, windowStart: Date, windowEnd: Date) -> [Date] {
        guard let dtStart = event.dtStart else { return [] }
        guard let rule = event.rrule else { return [dtStart] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = event.tz ?? .current
        let timeComps = cal.dateComponents([.hour, .minute, .second], from: dtStart)
        let anchor = cal.startOfDay(for: dtStart)
        let anchorWeekday = cal.component(.weekday, from: dtStart)
        let anchorDay = cal.component(.day, from: dtStart)
        let interval = max(1, rule.interval)
        var result: [Date] = []
        var produced = 0
        var day = anchor
        let lastDay = cal.startOfDay(for: windowEnd)
        var iter = 0
        while day <= lastDay && iter < 20000 {
            iter += 1
            if matches(day: day, cal: cal, rule: rule, anchor: anchor, anchorWeekday: anchorWeekday, anchorDay: anchorDay, interval: interval) {
                if let occ = cal.date(bySettingHour: timeComps.hour ?? 0, minute: timeComps.minute ?? 0, second: timeComps.second ?? 0, of: day), occ >= dtStart {
                    if let until = rule.until, occ > until { break }
                    produced += 1
                    if occ >= windowStart, !event.exdates.contains(where: { abs($0.timeIntervalSince(occ)) < 60 }) {
                        result.append(occ)
                    }
                    if let count = rule.count, produced >= count { break }
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    static func matches(day: Date, cal: Calendar, rule: RRULE, anchor: Date, anchorWeekday: Int, anchorDay: Int, interval: Int) -> Bool {
        let dayDiff = cal.dateComponents([.day], from: anchor, to: day).day ?? 0
        switch rule.freq {
        case "DAILY":
            if dayDiff % interval != 0 { return false }
            if !rule.byday.isEmpty {
                let wd = cal.component(.weekday, from: day)
                return rule.byday.contains(wd)
            }
            return true
        case "WEEKLY":
            let aWeek = cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
            let dWeek = cal.dateInterval(of: .weekOfYear, for: day)?.start ?? day
            let weeks = (cal.dateComponents([.day], from: aWeek, to: dWeek).day ?? 0) / 7
            if weeks % interval != 0 { return false }
            let wd = cal.component(.weekday, from: day)
            return rule.byday.isEmpty ? wd == anchorWeekday : rule.byday.contains(wd)
        case "MONTHLY":
            let a = cal.dateComponents([.year, .month], from: anchor)
            let d = cal.dateComponents([.year, .month], from: day)
            let months = (d.year! * 12 + d.month!) - (a.year! * 12 + a.month!)
            if months % interval != 0 { return false }
            let dom = cal.component(.day, from: day)
            return rule.bymonthday.isEmpty ? dom == anchorDay : rule.bymonthday.contains(dom)
        case "YEARLY":
            let a = cal.dateComponents([.year, .month, .day], from: anchor)
            let d = cal.dateComponents([.year, .month, .day], from: day)
            return (d.year! - a.year!) % interval == 0 && d.month == a.month && d.day == a.day
        default:
            return dayDiff % interval == 0
        }
    }
}

enum LinkExtractor {
    static let meetingHosts = ["zoom.us", "meet.google.com", "hangouts.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "gotomeet.me", "goto.com", "meet.jit.si", "whereby.com", "discord.gg", "discord.com", "slack.com", "chime.aws", "8x8.vc", "bluejeans.com", "facetime.apple.com"]

    static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func link(from event: ParsedEvent) -> URL? {
        if let conference = event.conference {
            let trimmed = conference.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return url
            }
        }
        if let urlValue = event.url {
            let trimmed = urlValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return url
            }
        }
        let texts = [event.location ?? "", event.description ?? ""].filter { !$0.isEmpty }
        guard let detector = detector, !texts.isEmpty else { return nil }
        var urls: [URL] = []
        for text in texts {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url { urls.append(url) }
            }
        }
        return urls.first { url in
            guard let host = url.host?.lowercased() else { return false }
            return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        } ?? urls.first { $0.scheme == "https" || $0.scheme == "http" }
    }
}

enum ICSBuilder {
    static func meetings(fromICS text: String, subscription: CalendarSubscription, now: Date) -> [MeetingEvent] {
        let resolvedHex = subscription.colorHex.isEmpty ? Palette.hex(for: subscription.colorIndex) : subscription.colorHex
        let windowStart = now.addingTimeInterval(-6 * 3600)
        let windowEnd = now.addingTimeInterval(14 * 86400)
        let parsed = ICSParser.parse(text)
        var result: [MeetingEvent] = []
        let groups = Dictionary(grouping: parsed.filter { $0.dtStart != nil && !$0.isAllDay }, by: { $0.uid })
        for (_, events) in groups {
            var occurrences: [(start: Date, event: ParsedEvent)] = []
            for master in events where master.recurrenceID == nil {
                guard master.status != "CANCELLED" else { continue }
                if master.rrule != nil {
                    for date in RRULEExpander.occurrences(of: master, windowStart: windowStart, windowEnd: windowEnd) {
                        occurrences.append((date, master))
                    }
                } else if let start = master.dtStart, start >= windowStart, start <= windowEnd {
                    occurrences.append((start, master))
                }
            }
            for override in events where override.recurrenceID != nil {
                guard let rid = override.recurrenceID else { continue }
                if let index = occurrences.firstIndex(where: { abs($0.start.timeIntervalSince(rid)) < 60 }) {
                    occurrences.remove(at: index)
                }
                if override.status != "CANCELLED", let start = override.dtStart, start >= windowStart, start <= windowEnd {
                    occurrences.append((start, override))
                }
            }
            for occurrence in occurrences {
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
        return result.filter { $0.end > windowStart }.sorted { $0.start < $1.start }
    }
}
