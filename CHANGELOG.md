# Changelog

## [2.0.0] - 2026-09-10

### Added

- Notifications as an alternative to fullscreen reminders.
- Notifications for ongoing meetings, sync problems, and updates.
- Offline reminders from previously synced ICS calendars.
- Guided setup and introductions to new features.

### Improved

- Clearer timing for late and snoozed reminders.
- Silent notification updates when meeting details change.
- Clearer permission controls and better reminder previews.
- More frequent update checks and optional update notifications.
- Faster calendar parsing and better settings recovery.

### Fixed

- Remind again when meetings are rescheduled.
- More reliable notification delivery and meeting detection.
- Prevent duplicate notifications for the same meeting.

### Security

- Stronger update verification and rollback protection.

## [1.10.0] - 2026-09-08

### Added

- Keep the agenda available while reminders are paused and isolate previews from real reminders.
- Choose how many meetings appear in the menu: 3, 5, 10, or 15. The default remains 5.

### Improved

- Faster calendar parsing through formatter reuse during each refresh.
- Clearer sync errors and empty-calendar messages, with sync failure details accessible from the
  menu.
- Consistent live sync counters and native reminder timing pickers in Settings.

### Fixed

- Reject incomplete or oversized calendar feeds without discarding previously loaded meetings.
- Handle recurrence limits deterministically and explain when a calendar cannot be fully processed.
- Correct calendar duration, nested alarm, exclusion, daylight-saving, and meeting-link parsing edge
  cases.
- Preserve snoozes and reminder history when meetings briefly disappear during a refresh.
- Clear old meetings and reminder state when a calendar URL changes.
- Avoid duplicate calendar requests when adding a subscription.
- Confirm quitting from the update window and improve consistency of timing calculations.

## [1.9.0] - 2026-09-07

### Added

- Choose a default snooze: Just in time, a preset duration, or a custom interval.
- Select snooze options directly from a custom fullscreen reminder dropdown.

### Improved

- Simplified reminder and snooze settings with compact timing controls and precise custom times.

### Changed

- Default snooze is Just in time when reminders appear before the start, or one minute for at-start
  reminders. Explicit saved snooze choices are preserved.

## [1.8.0] - 2026-09-04

### Added

- Smart menu bar countdowns switch from recently started meetings to the closer upcoming start at
  the midpoint
- A configurable elapsed-start window defaults to 10 minutes and remains independent from reminder
  delivery and running-event visibility
- Context-aware NOW, NEXT, and LATER sections use overlapping calendar-colored indicators for
  simultaneous meetings

### Improved

- Menu rows keep status icons compactly beside their titles and linkless multi-event reminders avoid
  duplicated missing-link symbols

### Fixed

- Countdown seconds update live while the menu is open
- Relative start times appear only for meetings happening today
- Event tooltips no longer replace the menu bar tooltip when leaving the dropdown

## [1.7.0] - 2026-09-03

### Added

- Per-calendar title filters can mute reminders by exact title or regular expression while keeping
  matching meetings visible and joinable
- Optional local meeting detection prevents new reminders from interrupting active calls, with
  separate best-effort browser detection

### Improved

- Linkless events now retain useful details, notes, copy actions, and locations throughout the app
- Meeting-link detection is more conservative, avoiding unrelated event and document URLs
- Successful in-app updates now show a one-time confirmation after startup is verified
- Release builds are smaller

### Fixed

- Retrying an update after a failed installation no longer carries the previous failure into the
  updated app

## [1.6.1] - 2026-09-01

### Fixed

- The Join button can no longer pick up mailto: or tel: links from event descriptions
- Reminder buttons stay readable when the panel loses focus in Light mode
- Double-clicking the app in Finder reopens Settings instead of appearing to do nothing
- Editing unrelated settings no longer restarts the auto-refresh countdown
- Calendar feeds cannot be redirected from HTTPS down to unencrypted HTTP

### Improved

- Reminder previews behave exactly like the real thing: they arm the keystroke guard and reveal the
  shortcut hints the same way
- "esc close" is now the last of the shortcut hints, with join/snooze leading

## [1.6.0] - 2026-08-31

### Improved

- Reminder panels ignore keystrokes for the first second after appearing, so typing done just before
  a reminder pops up can't accidentally join, snooze, or dismiss a meeting — the shortcut hints fade
  in once the keyboard is live again

## [1.5.0] - 2026-08-31

### Added

- Automatic update checks and in-app installation
- Update availability indicators in the menu and Settings

### Security

- Signed-update verification and automatic rollback when an updated app fails to start

### Improved

- Release validation and updater test coverage

## [1.4.0] - 2026-08-29

### Added

- Responsive Settings navigation with Command-number quick jumps and coordinated narrow layouts
- Numbered multi-meeting reminder cards with 1-9 join shortcuts

### Improved

- Strict, broader ICS recurrence handling with safe time-zone and workload limits
- Reminder accessibility, keyboard behavior, calendar controls, and sync status feedback

### Fixed

- Failed or stale refreshes no longer drop cached events or hide newer sync errors
- Delayed reminders, overlapping alerts, recurrence overrides, and persistence edge cases
- Release signing now verifies the exact stable identity and designated requirement

## [1.3.0] - 2026-08-28

### Added

- Apple Calendar integration — use your native macOS calendars alongside ICS feeds, with
  per-calendar enable + color and a "hide declined" option
- Grouped menu dropdown — events grouped by day, with rich hover tooltips (title, time, location,
  notes)

### Improved

- Alert windows now reliably get keyboard focus: Enter joins, Esc dismisses, "s" snoozes — including
  for already-started meetings
- Standard shortcuts (⌘Q, ⌘W, ⌘M, copy/paste) work in Settings
- Location row shows the provider name ("Zoom", "Google Meet", …) for link-only meetings
- Smaller download: app bundle 5.7 → 3.2 MB

### Fixed

- No duplicate alerts when a calendar sync briefly omits an event; snooze state survives it too
- Revoking Calendar permission clears events immediately
- Apple video-call decoration lines no longer leak into meeting notes

## [1.2.0] - 2026-08-27

### Added

- Just in time reminder option — fullscreen alert exactly when the meeting starts (fine tune now
  goes down to 0)

### Improved

- Smarter meeting link detection: Outlook HTML descriptions (X-ALT-DESC), attachments, event titles,
  and many more providers (RingCentral, join.me, Dialpad, …); native zoommtg:// and msteams:
  conference links are converted to browser URLs; unknown hosts with join-style paths (/j/, /join,
  confno=, …) are recognized

### Fixed

- Enabling a disabled calendar now syncs its events immediately instead of waiting for the next
  refresh

## [1.1.0] - 2026-08-27

### Added

- Enable/disable calendars — keeps them configured but stops sync and reminders
- Edit calendar name & URL with instant resync of that feed
- Delete confirmation before removing a calendar

### Improved

- Menu bar countdown now shows hours and minutes (e.g. “8h 56m”), also when late
- Event details: two-line date column (day + time) that never breaks
- Meeting links styled as links with pointing-hand cursor and URL tooltip
- Centered menu bar status dot across all countdown texts
- README badges link to releases and license

## [1.0.0] - 2026-08-27

- Initial release
- Fullscreen meeting reminders with one-click join (Zoom, Meet, Teams, Webex, any URL)
- Menu bar countdown, pause, upcoming list
- Shared iCal/ICS feeds with recurring events (RRULE/EXDATE/overrides)
- Per-calendar colors, sounds, late-meeting visibility

[1.0.0]: https://github.com/BoThomas/now/releases/tag/v1.0.0
[1.1.0]: https://github.com/BoThomas/now/compare/v1.0.0...v1.1.0
[1.2.0]: https://github.com/BoThomas/now/compare/v1.1.0...v1.2.0
[1.3.0]: https://github.com/BoThomas/now/compare/v1.2.0...v1.3.0
[1.4.0]: https://github.com/BoThomas/now/compare/v1.3.0...v1.4.0
[1.5.0]: https://github.com/BoThomas/now/compare/v1.4.0...v1.5.0
[1.6.0]: https://github.com/BoThomas/now/compare/v1.5.0...v1.6.0
[1.6.1]: https://github.com/BoThomas/now/compare/v1.6.0...v1.6.1
[1.7.0]: https://github.com/BoThomas/now/compare/v1.6.1...v1.7.0
[1.8.0]: https://github.com/BoThomas/now/compare/v1.7.0...v1.8.0
[1.9.0]: https://github.com/BoThomas/now/compare/v1.8.0...v1.9.0
[1.10.0]: https://github.com/BoThomas/now/compare/v1.9.0...v1.10.0
[2.0.0]: https://github.com/BoThomas/now/compare/v1.10.0...v2.0.0
