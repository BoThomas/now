import Foundation

/// Pure join-hook policy: what the shell runs when the user joins a meeting
/// and what is remembered about past executions. Spawning the process stays
/// in the macOS shell (see `JoinHookRunner`); these decisions remain testable
/// without one.
package enum JoinHook {
    /// How long the shell gets before it is terminated. A join hook is a
    /// background nicety, never worth blocking or leaking a process for.
    package static let timeoutSeconds: TimeInterval = 10
    /// Stored executions shown in Settings; oldest entries drop off the end.
    package static let maxRuns = 10
    /// Defensive cap for the stored command; longer scripts belong in a file.
    package static let maxCommandLength = 2_000

    /// The command a shell should execute verbatim, or nil when the setting
    /// is effectively empty/oversized and must not run anything.
    package static func normalizedCommand(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxCommandLength else { return nil }
        return trimmed
    }

    /// Whether joining `event` should run the hook: enabled, a usable command,
    /// and an occurrence whose hook has not run yet. Rescheduling re-arms it;
    /// Snooze changes reminder suppression without re-running the hook.
    package static func shouldRun(enabled: Bool, command: String, hasRun: Bool) -> Bool {
        enabled && normalizedCommand(command) != nil && !hasRun
    }

    /// Meeting data for the hook, passed as environment variables. It never
    /// becomes part of the command string — titles and links come from
    /// untrusted calendar content and must not be able to inject shell
    /// syntax. Variable values are not re-interpreted by the shell.
    package static func environment(for event: MeetingEvent) -> [String: String] {
        environment(title: event.title, calendarName: event.calendarName,
                    url: event.link?.absoluteString, start: event.start, end: event.end)
    }

    package static func environment(title: String, calendarName: String, url: String?,
                                    start: Date, end: Date) -> [String: String] {
        [
            "NOW_TITLE": title,
            "NOW_CALENDAR": calendarName,
            "NOW_URL": url ?? "",
            "NOW_START": ISO8601DateFormatter().string(from: start),
            "NOW_END": ISO8601DateFormatter().string(from: end),
        ]
    }

    /// Short stderr excerpt for a failed run — the only output now keeps, and
    /// never the command itself (which may embed tokens) or stdout.
    package static func excerpt(from stderr: String?, limit: Int = 200) -> String? {
        guard let text = stderr?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(limit))
    }

    /// Keeps the newest `maxRuns` entries (newest first).
    package static func capped(_ runs: [JoinHookRun]) -> [JoinHookRun] {
        Array(runs.prefix(maxRuns))
    }
}

/// One recorded join-hook execution, newest first, capped by `JoinHook.capped`.
package struct JoinHookRun: Codable, Equatable, Identifiable, Sendable {
    package enum Outcome: Codable, Equatable, Sendable {
        case success
        case failure(exitCode: Int)
        case timeout
        case launchFailure(String)
    }

    package var id = UUID()
    package var date: Date
    /// The meeting title at execution time; local diagnostics only.
    package var title: String
    /// True for Settings' "Run Test" executions against a synthetic meeting.
    package var isTest: Bool
    package var outcome: Outcome
    /// Truncated stderr (`JoinHook.excerpt`), nil when there was none.
    package var errorExcerpt: String?

    package init(date: Date, title: String, isTest: Bool, outcome: Outcome, errorExcerpt: String? = nil) {
        self.date = date
        self.title = title
        self.isTest = isTest
        self.outcome = outcome
        self.errorExcerpt = errorExcerpt
    }
}

extension ReminderLedger {
    /// Whether this occurrence's hook was already requested. Unlike reminder
    /// suppression, this survives Snooze; rescheduling re-arms it.
    package func hasRunJoinHook(_ event: MeetingEvent) -> Bool {
        entries[ReminderIdentity.eventKey(event)]?.joinHookRan == true
    }
}
