# Calendar ingestion and cache

[Project map](quickstart.md) · [Reminder delivery](reminders.md)

Both source types become [MeetingEvent](../Sources/Models.swift) values. ICS parsing and recurrence
expansion live in the shared [NowCore parser](../Sources/NowCore/ICS.swift); the macOS
[ICSBuilder](../Sources/ICS.swift) materializes those parsed values into application events.
[NativeCalendarSource](../Sources/NativeCalendars.swift) asks EventKit for already materialized
occurrences. Both enforce a start-time window of six hours before through fourteen days after fetch
time and exclude all-day/cancelled meetings. Native mapping also applies the configured
declined-event filter.

## From feed to accepted snapshot

`AppStore.refresh` starts native fetching and a full ICS batch. It first awaits the shared cache
restore, then `performFetch` publishes each completed source through `merge` rather than holding all
results until the slowest feed finishes. A rolling task group and shared four-slot download gate
bound overlap with targeted resyncs. Transport streams decoded bytes with a 5 MB cap and 25-second
inactivity/60-second resource timeouts. See [AppStore.swift](../Sources/AppStore.swift), including
`fetchTransport`, `decodeFeed`, and `CalendarTransportDelegate`.

`decodeFeed` passes text into `ICSBuilder.meetings`. `ICSParser` normalizes CRLF/CR, unfolds
continuation lines, and validates the entire calendar envelope before returning events. A complete
prefix followed by an unfinished component is a feed error; a complete empty calendar is a valid
empty result. Physical lines are capped at 200,000 and unfolded lines at 10,000 characters. Parser
errors propagate through `ICSBuildResult` and `FetchResult`, so a rejected feed cannot masquerade as
an empty success. The [structure and merge tests](../Tests/NowTests/SelfTest.swift) exercise these
boundaries.

`mergeICS` in [AppStore.swift](../Sources/AppStore.swift) checks the live source ID, enabled state,
URL, and request generation before accepting a result. A failure keeps previous events and adds a
source error. A success replaces that source's events, including when empty, and records a
successful source observation. Live colors and title filters are applied during merging, so a result
cannot overwrite a newer settings edit. `finishRefresh` advances the shared “Last synced” timestamp
whenever a full batch finishes, even if sources failed; targeted resyncs do not advance it. The
timestamp is therefore a completed-check time, not proof every source succeeded.

## Recurrence and identity

[ICSBuilder](../Sources/ICS.swift) groups records by UID, selects revisions with SEQUENCE/DTSTAMP,
expands supported rules, adds RDATEs, excludes EXDATEs, and replaces occurrences using exact
original recurrence dates. Sorted UID and anchor traversal keeps budget allocation deterministic.
The builder preserves distinct occurrences moved to the same actual start. Original occurrence
identity also feeds notification identity, while agenda IDs retain actual-start semantics in
[Models.swift](../Sources/Models.swift).

Unsupported RRULEs fall back to the first occurrence with a warning; they are not approximately
expanded. Unknown time zones and unsupported date forms can skip records with warnings. In contrast,
exhausting a recurrence or occurrence budget rejects the whole feed: 100,000 calculation steps per
series, 500,000 per feed, and 10,000 relevant occurrences. This preserves the last complete
snapshot. The expander verifies generated local dates/times across DST gaps before counting them.
For changes here, inspect recurrence, zone, override, and compliance fixtures in
[SelfTest.swift](../Tests/NowTests/SelfTest.swift), plus the
[workload](../scripts/feed-workload-smoke.py) and
[materialization performance](../scripts/parser-performance-smoke.py) harnesses.

`LinkExtractor.link` first accepts a usable explicit conference property, then a URL property
recognized as a meeting link. It searches recognized meeting links in location, description,
alternate description, title, and attachment order; there is no arbitrary HTTP(S) fallback in that
search. Native mapping synthesizes a `ParsedEvent` to share this extraction logic. Provider
recognition, precedence and display-location cleanup belong in
[NowCore](../Sources/NowCore/ICS.swift), not separate UI-specific matchers. Text URL discovery is
injected into that policy; the macOS overload in [Sources/ICS.swift](../Sources/ICS.swift) retains
`NSDataDetector`. Foundation imports alone do not make an API portable. The core-only runner tests
selection with synthetic detected URLs, not Linux parity with Apple's text detector.

## Restore and failure recovery

[CalendarCacheSnapshot](../Sources/CalendarEventCache.swift) stores materialized occurrences with
the original fetch clock and exact coverage bounds. It binds to the source UUID and a URL
fingerprint, reapplies current presentation/filter settings at restore, and refuses ended events or
times outside saved coverage. It never expands old recurrence rules into new future events. Cache
restore is neither a successful source observation nor a “Last synced” update.

The cache serializes writes/removals, limits snapshots to 16 MB and the aggregate to 64 MB, and uses
a 0700 directory with 0600 files and atomic replacement. Transient read errors preserve files. A
failed replacement quarantines the obsolete snapshot as a recovery file that is never auto-restored;
this prevents an accepted empty feed from resurrecting old meetings after restart. Source
disable/removal/URL changes invalidate pending restore and queued state through
[AppStore](../Sources/AppStore.swift). Profile-recovery protection is described in
[application state](application.md).

## Diagnose missing events

Run `./outputs/now.app/Contents/MacOS/now --parse <url-or-ics-file>` to inspect raw records, parsed
metadata, the fetch window, and kept meetings using production parsing. Check structural errors
first, then all-day/cancellation, time window, recurrence warnings, and live title filters. For
Apple Calendar, `--native list` inspects authorization/calendars and `--native` includes kept
events. Calendar authorization from a CLI belongs to the terminal app; use the GUI grant when
testing now's own access. Commands are implemented in [App.swift](../Sources/App.swift); detailed
operational constraints are in [AGENTS.md](../AGENTS.md).

Use [calendar-fetch-smoke.py](../scripts/calendar-fetch-smoke.py) for transport/structure and
[calendar-cache-smoke.py](../scripts/calendar-cache-smoke.py) for isolated process-restart recovery.
These complement the pure [cache tests](../Tests/NowTests/SelfTestCache.swift); do not seed live app
calendars for testing.

Before changing this area, read the relevant
[engineering constraints and regression notes](engineering-notes.md).
