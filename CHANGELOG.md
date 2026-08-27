# Changelog
## [1.2.0] - 2026-08-27

### Added
- Just in time reminder option — fullscreen alert exactly when the meeting starts (fine tune now goes down to 0)
### Improved
- Smarter meeting link detection: Outlook HTML descriptions (X-ALT-DESC), attachments, event titles, and many more providers (RingCentral, join.me, Dialpad, …); native zoommtg:// and msteams: conference links are converted to browser URLs; unknown hosts with join-style paths (/j/, /join, confno=, …) are recognized
### Fixed
- Enabling a disabled calendar now syncs its events immediately instead of waiting for the next refresh

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
