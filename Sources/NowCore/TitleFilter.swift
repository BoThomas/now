import Foundation

/// A per-calendar title filter: meetings whose title matches never get a reminder
/// (they stay visible everywhere, grayed out). `exact` compares the whole title
/// case-insensitively; `regex` is an `NSRegularExpression` search (anchor with
/// `^…$` for whole-title, `(?i)` for case-insensitive). Invalid, empty, and
/// over-length regex patterns are inert — they match nothing, never fail decode,
/// and are flagged red in the editor instead.
package struct TitleFilterRule: Codable, Equatable, Identifiable, Sendable {
    package enum MatchMode: String, Codable, Sendable {
        case exact
        case regex
    }

    package var id = UUID()
    package var pattern: String
    package var mode: MatchMode = .exact

    package init(pattern: String, mode: MatchMode = .exact) {
        self.id = UUID()
        self.pattern = pattern
        self.mode = mode
    }

    enum CodingKeys: String, CodingKey {
        case id, pattern, mode
    }

    /// Synthesized Codable would hard-require every key; hand-rolled defaults keep
    /// hand-edited or future persisted JSON decodable (mirrors `CalendarSubscription`).
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        mode = try c.decodeIfPresent(MatchMode.self, forKey: .mode) ?? .exact
    }
}

extension TitleFilterRule {
    /// Regex patterns only: bound compile/backtracking surface. Exact rules are
    /// uncapped on purpose — plain equality is cheap, and truncating a title
    /// would silently break "whole title" semantics.
    nonisolated package static let maxRegexPatternLength = 500
    nonisolated package static let maxRulesPerCalendar = 50

    /// False for empty/whitespace patterns, invalid regex, and over-length regex
    /// patterns. Such rules are kept (editable/persisted) but match nothing.
    package var isValid: Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if mode == .regex {
            guard trimmed.count <= Self.maxRegexPatternLength else { return false }
            return (try? NSRegularExpression(pattern: trimmed)) != nil
        }
        return true
    }

    /// Single-rule match (selftests, popover rule listing). Bulk flag recomputation
    /// goes through `TitleFilterMatcher` so regexes compile once per batch.
    package func matches(title: String) -> Bool {
        TitleFilterMatcher(rules: [self]).matches(title: title)
    }

    package static func matches(title: String, rules: [TitleFilterRule]) -> Bool {
        TitleFilterMatcher(rules: rules).matches(title: title)
    }

    /// The rules matching `title`, in list order — drives the unmute confirmation
    /// popover (the toggle's state is exactly "this list is non-empty").
    package static func matchingRules(title: String, rules: [TitleFilterRule]) -> [TitleFilterRule] {
        rules.filter { $0.matches(title: title) }
    }

    /// The row-toggle add path: rules + one new exact rule for `title` (trimmed,
    /// verbatim). Normalization dedupes an already-present equivalent rule.
    package static func addingExact(title: String, rules: [TitleFilterRule]) -> [TitleFilterRule] {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rules }
        return normalized(rules + [TitleFilterRule(pattern: trimmed, mode: .exact)])
    }

    /// The popover Remove path: drops exactly the selected ids, keeps order.
    package static func removing(ids: Set<UUID>, from rules: [TitleFilterRule]) -> [TitleFilterRule] {
        rules.filter { !ids.contains($0.id) }
    }

    /// Shared normalization, run on decode AND on every commit: trims patterns,
    /// drops empty ones, dedupes (exact rules case-insensitively — matching is
    /// case-insensitive, so "Standup" and "standup" are the same rule; regex by
    /// identical pattern), and caps the rule count. Invalid regexes are KEPT —
    /// they are persisted state the user may still fix in the editor.
    package static func normalized(_ rules: [TitleFilterRule]) -> [TitleFilterRule] {
        var seen = Set<String>()
        var result: [TitleFilterRule] = []
        for var rule in rules {
            rule.pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rule.pattern.isEmpty else { continue }
            let key = rule.mode == .regex ? "r:\(rule.pattern)" : "e:\(rule.pattern.lowercased())"
            guard seen.insert(key).inserted else { continue }
            result.append(rule)
            if result.count == maxRulesPerCalendar { break }
        }
        return result
    }
}

/// Prepared matcher over one calendar's rules: every valid regex is compiled
/// EXACTLY ONCE per snapshot so bulk recomputation (feed cap: 10k events) never
/// compiles per event. Build one per calendar per recompute batch.
///
/// Residual risk (accepted, documented): `NSRegularExpression` has no match
/// timeout; a user-authored catastrophic-backtracking pattern can still hang a
/// recompute. The rule-count/pattern-length caps are hygiene, not a bound.
package struct TitleFilterMatcher {
    private let exactTitles: Set<String>
    private let regexes: [NSRegularExpression]

    package init(rules: [TitleFilterRule]) {
        var titles = Set<String>()
        var compiled: [NSRegularExpression] = []
        for rule in rules {
            let trimmed = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            switch rule.mode {
            case .exact:
                titles.insert(trimmed.lowercased())
            case .regex:
                guard trimmed.count <= TitleFilterRule.maxRegexPatternLength,
                      let regex = try? NSRegularExpression(pattern: trimmed) else { continue }
                compiled.append(regex)
            }
        }
        exactTitles = titles
        regexes = compiled
    }

    package func matches(title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if exactTitles.contains(trimmed.lowercased()) { return true }
        if !regexes.isEmpty {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            for regex in regexes where regex.firstMatch(in: trimmed, range: range) != nil {
                return true
            }
        }
        return false
    }

    /// Matchers keyed by calendar id, built from whichever half of the calendar
    /// collections a recompute site has (ICS merge/reconcile: subscriptions;
    /// native snapshot: native calendars).
    package static func byCalendar(subscriptions: [CalendarSubscription] = [], nativeCalendars: [NativeCalendar] = []) -> [UUID: TitleFilterMatcher] {
        var byID: [UUID: TitleFilterMatcher] = [:]
        for subscription in subscriptions { byID[subscription.id] = TitleFilterMatcher(rules: subscription.titleFilters) }
        for native in nativeCalendars { byID[native.id] = TitleFilterMatcher(rules: native.titleFilters) }
        return byID
    }

    /// Shared pure flag application for the subscription and EventKit reconcile
    /// paths. Calendars without rules explicitly clear a previously derived flag.
    package static func applying(to events: [MeetingEvent], subscriptions: [CalendarSubscription] = [], nativeCalendars: [NativeCalendar] = []) -> [MeetingEvent] {
        let matchers = byCalendar(subscriptions: subscriptions, nativeCalendars: nativeCalendars)
        return events.map { event in
            var copy = event
            copy.isMuted = matchers[event.calendarID]?.matches(title: event.title) ?? false
            return copy
        }
    }
}
