# Engineering constraints and regression notes

[Project map](quickstart.md) · [Agent instructions](../AGENTS.md)

Detailed constraints and debugging lessons moved from AGENTS.md. Read the relevant sections before
changing a subsystem. This relocation does not revalidate every historical observation; check
current source when working in that area. Commands and source paths in code spans are relative to
the repository root.

## Code signing (TCC stability)

TCC grants (Calendar permission) are keyed to the code signature's _designated requirement_. Ad-hoc
signing anchors the DR to the binary's cdhash → every rebuild = "a different app" = re-prompt. So
release/dev builds are signed with a self-signed identity **"now Developer"** (RSA-2048, codeSigning
EKU, valid to 2036) whose certificate hash anchors the DR instead — grants survive rebuilds and
release updates.

- The identity lives in the **login keychain** of the dev machine. Its expected SHA-1 fingerprint is
  `A505B08900C56A28709479297A049525A2A187C6`; `build-app.sh` signs by that exact fingerprint and
  falls back to ad-hoc with a warning unless `--require-identity` is set.
  `NOW_SIGNING_IDENTITY_SHA1` is the deliberate certificate-rotation override and must also be
  supplied to release preflights.
- Backup: the `.p12` (with its password) lives **only** in the password manager (1Password/Bitwarden
  file attachment) — there is deliberately no on-disk copy. Key material must NEVER be committed
  (`.gitignore` blocks `*.p12/*.pem/*.key`).
- Restore on a new machine:
  ```bash
  security import now-codesign-backup.p12 -k ~/Library/Keychains/login.keychain-db -P '<password>' -T /usr/bin/codesign
  security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db <cert.pem-from-p12>   # make find-identity see it as valid
  ```
  Without the `add-trusted-cert` step `security find-identity -v -p codesigning` reports "0 valid
  identities" (untrusted self-signed) and `codesign -s` won't find it.
- After expiry (2036) regenerate a cert the same way — every machine then re-grants once.
- Self-signed ≠ notarized: Gatekeeper still warns on other machines (README covers that). A real
  Developer ID + notarization remains the eventual proper fix.

## Hard-won knowledge (don't regress)

### Persistent ICS cache

`CalendarEventCache` saves accepted materialized occurrences per source (16 MB/source, 64 MB total)
under Application Support/<bundle ID>/CalendarCache-v1, with 0700 directory/0600 files and atomic
writes. Source URL fingerprints bind snapshots without copying feed tokens. `fetchedAt` is the
parser's clock, so coverage remains the exact original −6h…+14d window; never re-expand stale
recurrence rules. Shared async restore precedes ICS fetch results and reminder ticks, applies live
colors/names/title filters, drops ended events, and never advances successful-source observations or
`lastChecked`. Disabled/removed/URL-edited sources invalidate pending restore and queued writes;
serial disk ordering and request generations prevent stale writes. Successful empty results replace
disk contents; failures keep saved data. `cacheInfo` exposes per-source last success/coverage
independently of full-refresh “Last synced”; per-calendar status is shown only for a current
sync/offline error, expired coverage, or storage problem. Healthy cards rely on the shared timestamp
beside Refresh. Only NSURLErrorNotConnectedToInternet yields Offline in the existing red menu error
row; HTTP/DNS/timeout errors do not prove offline. Normal termination queues a disk barrier
synchronously, stops accepting new results, and replies to AppKit in common run-loop modes; a
main-queue Task can stall in the terminateLater modal loop. It does not wait for downloads.
Snoozes/acknowledgements persist separately through ReminderLedger.
`scripts/calendar-cache-smoke.py` uses real process restarts, synthetic loopback feeds, injected
URLProtocol offline errors, a temporary cache and a disposable preferences domain. Never seed the
live app's calendar data for testing.

### Calendar feed resource limits

`fetchData` streams decoded bytes and cancels at 5 MB (including unknown-length and gzip bodies),
with 25 s inactivity / 60 s total resource deadlines. A shared four-slot gate bounds downloads
across full and targeted refreshes; full refreshes publish each completed subscription through the
existing generation-aware merge and finalize only the batch timestamp/status. Parser input above
200k physical lines or 10k characters per unfolded line is rejected before event parsing
(`ICSParseResult.error` → `ICSBuildResult.error` → `FetchResult.error`), retaining cached events.
Resource rejection is a sync failure, not a partial-feed warning. `--parse` URL downloads use the
same transport. The local `calendar-fetch-smoke.py` compiles production helpers without launching
the app or constructing EventKit stores.

### Refresh correctness

`AppStore.mergeICS` (pure) is the single merge decision — a FAILED subscription keeps its cached
events + records `errors[id]`; results for removed/disabled/URL-edited subscriptions are dropped (no
resurrection); `FetchTracker` request generations drop superseded results (out-of-order targeted vs
full). `lastChecked` (displayed as "Last synced" in Settings/menu, per user preference) updates
whenever a full refresh completes, even on partial/total failure; targeted resyncs do not advance
it. Add/Remove request a full refresh; Add suppresses the redundant newly-enabled targeted request,
while re-enabling an existing source remains targeted. Dropdown failure counts open Settings, clear
on recovery/removal/disable, and participate in open-menu refresh signatures. `warnings[id]`
(orange, settings rows) = degraded feeds (skipped events, unsupported RRULE/TZID) — distinct from
`errors[id]` (red, sync failure). Selftest drives all of this via the pure functions
(`SelfTest.fetchMergeTests`) — never construct `AppStore` there (it owns an `EKEventStore`; selftest
must stay EventKit-free).

### Reminder timing

reminders fire from the lead window until the meeting ENDS (`dueForAlert`, pure) — late delivery
after sleep/delayed launch still alerts; ended meetings never do. A due reminder MERGES into an open
panel (`AlertController.mergedShown`), never replaces it. `commitEvents` →
`alertController.reconcile` drops cards whose events vanished (preview alerts exempt). Pause
(`pausedUntil`, incl. indefinite) persists via `Persisted`; snoozes/alerted memory now persist
through ReminderLedger. All AppStore/MenuBar/EventKit-debounce timers run in `.common` run-loop mode
(`AppStore.commonTimer`) — `.default` stalls while a menu tracks or a modal loop runs.

### Rescheduled fullscreen reminders

`ReminderLedger.Entry.start` distinguishes a new scheduled start from the same handled reminder,
including across restarts. With fullscreen delivery, a start edit clears the old/current handled IDs
unless an explicit snooze or notification receipt owns the occurrence. Clear the old ID even before
the new reminder fires, so moving back cannot revive retained handled memory. Title/end edits keep
acknowledgement; notification edits retain their silent replacement lifecycle. Legacy entries use
the previous live snapshot's start when available, otherwise baseline on first restore without
repeating reminders. Notification lifecycle smoke covers rescheduling, moving back, snoozes, receipt
ownership, and restart.

### Title filters

`TitleFilterRule` is per calendar; exact rules are whole-title case-insensitive, regex rules use
`NSRegularExpression` search semantics. `MeetingEvent.isMuted` is derived only through the live-rule
recompute paths (`mergeICS`, subscription reconcile, native snapshot); `dueForAlert` skips muted
events and `menuBarFocus` skips them while lists keep them visible. Every rule commit goes through
`setTitleFilters` normalization. `commitEvents` ratchets muted→unmuted events already inside their
lead window into `alerted` and clears snoozes, preventing surprise alerts; open reminder cards are
reconciled away when muted. Menu titles must keep native foreground color for selection contrast.
Regex count/length caps are hygiene only: user-authored catastrophic backtracking remains an
accepted local risk.

### Meeting-aware suppression

optional and fail-open. `MeetingActivityProbe` reads CoreAudio process-object metadata only (never
audio, no microphone permission); explicit bundle-prefix allowlists classify native clients, while
browsers are a separate default-off setting because CoreAudio cannot identify the tab/site. Poll
every 3 s; meeting is immediate, inactive requires two snapshots. While a meeting is detected, due
reminders defer before their event start and are marked alerted at/after start. `.unknown` always
presents normally, existing panels stay open, and Preview bypasses suppression. Enabling first
probes capability; a failed fresh opt-in preserves the prior choice. Restoring a saved choice on
startup preserves it on transient failure and retries after 5 s, doubling to a 300 s cap, with
earlier activation/wake retries; unknown activity fails open. Unsupported capability does not retry
automatically. `--meeting` uses the exact production probe for live bundle-ID verification.
Live-verified on macOS 26: Zoom `us.zoom.xos`, Teams `com.microsoft.teams2.modulehost`, and Google
Meet in Helium `net.imput.helium.helper` stay active muted/unmuted and return inactive after leaving
while the app/browser remains open. Zoom and Meet also passed real calendar-event suppression end to
end; Zoom additionally passed pre-start deferral/re-alert and post-start permanent dismissal.

### Generated recurrence times

verify both local calendar day and hour/minute/second before emitting or counting an RRULE
occurrence. Nonexistent DST times are skipped and do not consume COUNT; the explicit DTSTART anchor
is preserved and repeated fall-back times yield one occurrence. Daily/weekly/monthly/yearly
gap-and-COUNT fixtures cover the shared expander.

### ICS parser is strict

the entire calendar envelope must have balanced, matching components before any parsed events are
returned. Incomplete input, nested calendars/events, and content outside a calendar are feed errors
that retain cached meetings, not successful empty snapshots. Complete empty calendars and complete
sibling calendar objects remain valid; UTF-8 BOMs and mixed-case boundaries are accepted.
`decodeFeed` and `--parse` use this same parser validation. `RRULE.parse` returns nil for anything
not expanded CORRECTLY (unknown keys, HOURLY-family, BYWEEKNUM/BYYEARDAY/BYHOUR/BYMINUTE/BYSECOND,
ordinal BYDAY on daily/weekly, yearly plain BYDAY, COUNT+UNTIL) → event falls back to its first
occurrence + feed warning; never silently approximated. Unknown TZIDs (after the Windows/Outlook
map) skip the event with a warning. EXDATE excludes DTSTART even without RRULE, while preserving the
master anchor. Occurrence identity is EXACT `Date` equality — TZID-less EXDATE/RECURRENCE-ID/RDATE
inherit the MASTER's zone at build time. Overrides inherit master data; SEQUENCE/DTSTAMP resolve
duplicate revisions; RDATE dates supported; `VALUE=PERIOD` is explicitly warned and skipped (period
expansion remains unsupported), `RANGE=` rejected. Budgets: 5 MB download, 200k physical lines, 10k
characters/unfolded line — reject the feed; 100k calculation steps/series, 500k/feed, 10k relevant
occurrences — reject incomplete feeds and retain the entire cached feed. There is no processing
wall-clock deadline. UID groups use sorted order for deterministic work allocation; an exact budget
fit succeeds (only attempted further work marks expansion incomplete). Error details report raw
record/recurring-series counts, consumed work and historical steps, and remain fully readable in
Settings. RDATE window filtering, exclusion and deduplication precede the relevant-date cap.
`python3 scripts/feed-workload-smoke.py` benchmarks heavy fixtures and tests cache/recovery plus
deterministic diagnostics across processes. `parseDuration` requires a time part after `T` and
rejects months (`P1M` is not RFC).

### Concurrency

`AppStore`, `AlertController`, `NativeCalendarSource`, `MeetingActivitySource`, `MenuBarController`,
`AppDelegate`, `UpdateController` are `@MainActor`; pure/static decision helpers are `nonisolated`
so the selftest can call them (`mergeICS`, `dueForAlert`, `normalizedEvents`, `prunedBookkeeping`,
`keyAction`, `UpdateLogic.*`, …; `FetchResult`/`FetchRequest`/`FetchTracker`/`AccessRequestGate` are
top-level for the same reason). Notification/timer closures delivered on main hop via
`MainActor.assumeIsolated`. Network+parse and CoreAudio meeting probes run off the main actor.

- **Auto-updater** (implementation: `Sources/Updater.swift`): updates itself from GitHub Releases —
  no Sparkle, no appcast, nothing hosted beyond GitHub.
  - **Trust = the TCC DR**: a staged bundle must satisfy
    `identifier "com.thomasboch.now" and certificate root = H"<fp>"` for a fingerprint in
    `UpdateLogic.pinnedFingerprints` — the same anchor that keeps Calendar grants stable. Rotation:
    ADD the new fp while still signing with the old cert, several releases, then switch, later drop
    old. Appending bytes to a Mach-O is NOT a signable tamper (codesign "strict validation" refuses)
    — the meaningful attack is a _validly re-signed_ (e.g. ad-hoc) bundle, which the DR gate
    rejects.
  - **The app never swaps itself**: `UpdateInstaller` spawns a detached `/bin/sh -c` helper (params
    via ENV, never interpolated — remote data must not reach a shell). Helper: bounded old-PID wait
    → old→backup sibling → staged→app → launch the actual executable (with `env -u NOW_UPDATE_ERROR`
    — a successful retry after a failed install must never inherit the old failure env; the app also
    `unsetenv`s it right after processing) → wait for an exact child-PID/random-token startup
    acknowledgement → backup→Trash. Child exit/timeout restores the old app; every mutation-time
    failure renames the failed new app aside, restores first, then relaunches the OLD app with
    `--env NOW_UPDATE_ERROR=<reason>` (app shows the error window and never auto-offers that version
    again). Never delete the installed path before the backup rename succeeds or trash the backup
    before startup health is acknowledged.
  - **Ordering/invariants**: decide-before-download (`decide()` on the manifest first; no
    release-age delay for automatic or manual checks — deleting a bad GitHub release is the rollback
    brake: it stops the spread but is not an undo); one updater-only URLSession enforces HTTPS for
    production API/assets and rejects disallowed redirects before following them (arbitrary HTTPS
    CDNs allowed), with loopback HTTP enabled only by an explicit loopback `NOW_UPDATE_API_BASE`.
    Archives stream to disk with a 100 MB cap, and unsigned extraction is monitored at 60 s / 500 MB
    / 50k entries. Signature validation uses strict/all-architectures/nested flags; staged apps
    require a canonical one-to-three-component `LSMinimumSystemVersion`. Staging requests carry
    generations so stale async completions cannot win; preparation failures remain version-owned and
    directly retryable. Launch cleanup recognizes only exact canonical-UUID artifacts, preserves
    helper-active paths, deletes staging only after 24 h, and retries moving valid old backups to
    Trash. Throttle: automatic attempts at least six hours apart, including launch/wake and
    failures; manual checks bypass. Escalation: auto-checks only light the menu item + About badge;
    the window auto-shows once per version after 18 hours uninstalled (`firstSeenUpdateDate`);
    manual checks always answer with the window. `lastNotifiedVersion` is set when the window is
    actually visible. Wake handling has one owner in AppDelegate registered on
    `NSWorkspace.shared.notificationCenter`.
  - **Update window**: plain SwiftUI `.defaultAction`/`.cancelAction` shortcuts are safe there (both
    buttons always exist — the alert's vanishing-button keyMonitor machinery is NOT used). Never
    show it while a reminder alert is open (defer; the `.screenSaver` panel sits above it) —
    `AppDelegate.pendingUpdateWindow` + `policyDidChange`. `syncActivationPolicy` has a third term
    (`updateWindow?.isVisible`). A successful install confirms itself, but only at the commit point:
    `start()` detects running version == `pendingInstallVersion` (`justInstalledVersion`, held in
    `pendingInstalledVersion`), and `startupHealthAcknowledged()` — called in AppDelegate right
    AFTER the +2 s `acknowledgeUpdatedStartup()` — consumes the marker
    (`stateAfterSuccessfulInstall`) and shows the one-time `.installed` window. The confirmation
    runs ONLY when `acknowledgeUpdatedStartup()` returns success: only a fully absent helper
    contract (both health env vars unset — an ordinary launch) acknowledges as a no-op success,
    while an injected health fault, a partial/empty contract, or an unwritable ack file reports
    failure — marker kept, no window, helper rolls back (never a false "Update installed"; fail
    closed). Before that ack the helper can still roll back, and the surviving marker is what lets
    the rolled-back OLD app suppress re-offering the failed version. The window title follows the
    content ("Update Complete" for `.installed`, "What’s New" for `.features`, else "Update now") —
    set synchronously before every `makeKeyAndOrderFront` (the windowContent observer's retitle
    lands a runloop tick later, so a reused window would flash its previous title) and refreshed on
    content change while visible.
  - **Quit-bypass**: installs quit via `AppDelegate.terminateForUpdate()` (closes alert, no
    confirmations) — never through `handleQuitRequest()`. Multi-instance guard: any
    `NSRunningApplication` with our bundle id and pid ≠ self blocks the update (CLI runs never
    register there).
  - **Testing**: `--update-check` prints what the updater sees (read-only).
    `scripts/update-smoke.sh` fakes everything locally (python http.server + a dynamically bumped,
    re-signed release — the re-sign invocation must MIRROR build-app.sh's codesign line). The
    directly launched child acknowledges startup, reports its version, and exits before UI; a
    negative case suppresses the acknowledgement and proves rollback before Trash; the stale-error
    case proves a successful retry's child never inherits a prior failure's `NOW_UPDATE_ERROR`.
    Needs the stable identity (ad-hoc can't pass the DR gate — by design). The staging dir is HIDDEN
    (`.now-update-*` — `ls` needs `-a` when debugging). 404 from `/releases/latest` = silent
    up-to-date; GitHub 403s without a User-Agent, so the updater pins `now/<version>`.
    `--update-smoke` exit codes: 0 spawned helper / 2 REFUSED / 3 up-to-date / 4 error;
    `NOW_UPDATE_API_BASE`/`NOW_UPDATE_REPO`/`NOW_UPDATE_TOKEN` (token only for overridden bases) are
    test hooks.

### CRLF feeds

many servers send `\r\n`. In Swift, CR+LF is a single grapheme cluster, so `split(separator: "\n")`
(Character) does NOT split CRLF lines — the whole file becomes one line and parsing silently yields
0 events. `ICSParser.unfolded` normalizes `\r\n`/`\r` → `\n` first. The selftest includes a CRLF
variant for regression.

### Standard shortcuts need a main menu

the app is `.accessory`/LSUIElement, so there was no menu bar and Cmd+V/Cmd+A beeper-failed.
`AppDelegate.setupMainMenu()` installs a minimal main menu — keep it: "now" app menu (Quit ⌘Q →
custom `handleQuitRequest()`: confirm when Settings is key, **dismiss-vs-quit dialog when a reminder
is showing** — set `AlertController.modalAlertActive` while it runs so the alert's key monitor
yields — else terminate), Edit (copy/paste via responder chain), and Window (Close ⌘W / Minimize ⌘M
— these are _menu_ key equivalents, NOT built-in window behaviors; without the items the shortcuts
do nothing). The menu bar only shows our menus while the app is ACTIVE **and** `.regular`: an
`.accessory` app activating with a window (even `makeKeyAndOrderFront` before `activate`) often
keeps the previous app's menu bar on screen. Policy is centralized in
`AppDelegate.syncActivationPolicy()` — `.regular` while Settings, the alert, or the update window is
visible, `.accessory` otherwise — wired via `windowWillClose` and `AlertController.policyDidChange`;
never set the policy anywhere else. Finder double-click on an already-running LSUIElement app sends
a reopen event; `applicationShouldHandleReopen` must surface Settings so the action never appears to
do nothing.

### Notification agenda reopen

`AppDelegate.openNotificationAgenda()` holds reopen suppression throughout synchronous native menu
tracking and renews the short grace when it returns. A foreground notification's completion/reopen
can arrive only after the user dismisses the menu; a deadline set solely before opening it expires
and incorrectly surfaces Settings afterward. Startup smoke holds the real agenda beyond one second
and injects reopens both during tracking and after dismissal; ordinary Finder reopen and explicitly
opened Settings must still work.

### Pasteboard vs. menu commands

standard text shortcuts are responder-chain actions; menu-bar-only apps must provide the menu
explicitly.

### Webex scheduled links

recognize `/<site>/j.php?MTID=<nonempty opaque id>` only on `webex.com` or its subdomains. Preserve
the original URL/query; homepages, help/recording pages, missing IDs, and lookalike hosts remain
rejected. Existing `/meet/` Personal Room links continue through the generic matcher.

### Meeting links

See [calendar link extraction](calendars.md#recurrence-and-identity) and
[NowCore/ICS.swift](../Sources/NowCore/ICS.swift). The recognized-provider search does not fall back
to arbitrary HTTP(S) URLs.

### Feed line endings/folding

RFC 5545 continuation lines (leading space/tab) are unfolded before parsing; text values are
unescaped (`\n`, `\,`, `\;`, `\\`).

### Window

events kept if start within −6h…+14d of fetch time; all-day and `STATUS:CANCELLED` events are always
skipped. If a user's events "don't show up," check they're actually in the future.

### Menu-bar focus vs. running visibility

`elapsedStartMinutes` controls only the maximum elapsed-start countdown window (−1 = never, 0 =
until end, N = N min after start; default 10). It deliberately replaces rather than migrates the
former `lateMinutes` visibility setting: AppStore re-encodes state at launch, so every existing user
starts this new semantic at 10 and the obsolete key is removed. `menuBarFocus` chooses the closest
eligible start and lets a future start win the exact midpoint tie; when no future start exists after
the window, it falls back to the soonest running end (`ends 23m`). Running events remain visible in
lists/menu until their scheduled end independently. Equal selected instants form a color-preserving,
overlapping dot cluster (max three visual dots; exact count via accessibility/dropdown). This
remains wholly independent from late reminder delivery in `dueForAlert`.

### Snooze re-fire

a snoozed alert re-fires while `now < event.end`, including after start.
`AppSettings.snoozeSeconds`: 0 = just in time when leadSeconds > 0; presets 60/180/300/600 plus
custom durations from 1 to 7200 seconds. Custom values persist exactly and join the sorted preset
list in settings and fullscreen controls; duplicate preset values appear only once. Reminder timing
and snooze settings share the same minutes/seconds editor. New and existing installs without a saved
snooze choice default to 0 when reminders fire before start, or 60 when reminder timing is just in
time; explicit choices survive. Changing reminder timing to just in time resets an incompatible
snooze default to 60. Shared snoozes must protect **every active card**:
`AlertController.snoozeOptions` ignores ended cards, offers a duration only if it expires strictly
before every active event's end, and offers just in time only if all active events are un-started.
Main button + "s" resolve `primarySnoozePlan` at activation: preferred duration → longest shorter
safe duration → just in time if safe → none. A just-in-time default falls back to the shortest safe
duration after start. `snoozeSchedule` revalidates every action at the current time and maps only
active events to fire dates (each own start for just in time); invalid/stale menu clicks leave the
reminder open. No choice means no snooze control. The custom dropdown respects modifier keys,
supports plain arrows/Return/Space/Escape, Tab/Shift-Tab and outside-click dismissal, and displays
menu-specific shortcut hints. Selection reconciles on time/option changes and event merges;
activation also resolves stale selections before acting. Pure scheduling, selection, and menu-key
helpers are regression-tested without EventKit or fullscreen panels.

### Transient event omissions

a fetch can briefly miss an event (`.EKEventStoreChanged` mid-CalDAV-sync, one bad/empty ICS
response). `ReminderSnapshotTracker` therefore prunes alert/snooze and muted-state bookkeeping only
after **two successful snapshots from the event's own calendar** omit it. Unrelated source commits,
failed/stale fetches, recolors, and rule edits do not count; a return resets the miss, and
disabling/removing the calendar clears its bookkeeping. Lagging bookkeeping is inert (`tick()`
iterates `events` only).

### Auth revocation

`appBecameActive` re-fetches on ANY EventKit status change — a deny must clear native events
immediately (fetchNativeEvents' unauthorized branch wipes them), not at the next 15-min refresh.

- **EventKit native calendars** (implementation: `Sources/NativeCalendars.swift`):
  - **One `EKEventStore` only** (`NativeCalendarSource.store`) — a second instance makes
    `calendars(for:)` return nothing on recent macOS. Never create another one; the `--native` CLI
    makes its own because no AppStore exists in that path.
  - **Permission split**: macOS 14+ needs `requestFullAccessToEvents()` (no read-only tier); the
    legacy `requestAccess(to: .event)` on 14+ grants **write-only**. Both plist keys ship
    (`NSCalendarsFullAccessUsageDescription` + `NSCalendarsUsageDescription`); entitlement
    `com.apple.security.personal-information.calendars` via `now.entitlements`. Prompt only from the
    settings UI ("Grant Access…"), never at launch; `EKEventStore()` alone is TCC-silent.
  - **TCC + signing**: TCC grants key to the signature's designated requirement — solved with the
    self-signed "now Developer" identity (see _Code signing_ above); ad-hoc fallback builds
    re-prompt per build (known). Status re-checked on `didBecomeActive` so granting via System
    Settings lights the UI up.
  - **Recurring events**: `events(matching:)` materializes each occurrence with shared
    `eventIdentifier`, distinct `startDate` → no RRULE code on the native path; fits
    `MeetingEvent.id` directly. No public conference API: synthesize a `ParsedEvent` from
    title/location/notes/url and reuse `LinkExtractor`.
  - `.EKEventStoreChanged` (debounced 1.5 s) → `fetchNativeEvents()`; native and ICS events are
    merged in `commitEvents` — `knownNativeCalendarIDs` distinguishes them by `calendarID` (our
    stable UUID, never the EK identifier).
  - Selftest stays EventKit-free: `NativeCalendarSource.parsedEvent(…)` is the pure mapping over
    plain values; only it is unit-tested.

### Settings layout

≥880 pt wide a section sidebar appears (entries + scroll-following selection via `SectionTopKey`,
⌘1-5 jumps, hold-⌘ hint reveal through `CommandHoldTracker` — hints live in a fixed-width slot so
nothing shifts); below it collapses to the plain form. Section titles/icons live in
`SettingsSection` — keep `sectionHeader(...)` calls routed through it so sidebar and headers stay in
sync. Default window 940×720, min 520×480.

### Colors

per-subscription `colorHex` in settings (ColorPicker). Changing a color re-tints already-fetched
events in place (`recolorEvents`). New subscriptions get a rotating palette default.

### Menu bar dropdown layout

event rows use `attributedTitle` with two tab stops: start times are right-aligned, then titles
align after the second tab. Muted/no-link symbols follow the title instead of consuming a
permanently reserved leading column; keep title text free of an explicit foreground color so
selection highlighting stays native. Context sections are NOW, NEXT (all events sharing the next
start; its header adds TOMORROW/date when needed), then LATER TODAY/TOMORROW/date. Running rows show
elapsed start + scheduled end inside the configured window, then remaining duration; future rows
show `in …` only when they start today. While the native menu tracks, the `.common` button timer
updates event-item titles/tooltips every second in place; structural/day/updater changes and event
content changes that affect a row rebuild it, avoiding frozen seconds or stale value-type snapshots
without destroying hover selection every tick. Native event help tags exist only on AppKit's
currently highlighted row so a stale event tooltip cannot cover the status-button tooltip after the
cursor leaves the dropdown. Settings' `UpcomingEventList` retains `Fmt.dayHeader` grouping. Long
titles are cut via `Fmt.ellipsized` (48 chars); hover shows a rich multi-line tooltip
(title/when/timing/location/notes via `tooltipText`, notes word-wrapped by `Fmt.wrapped`; no
join-link row, and location/notes lines that are nothing but the join link are suppressed —
`isJustJoinLink`). Refresh has ⌘R (`keyEquivalent: "r"` — works while the menu is open).

### Reminder location row

shows a meaningful `LOCATION`, but treats a location consisting only of the join URL as redundant
and falls back to `LinkExtractor.providerName(for:)` ("Zoom", "Google Meet", …). Link-only meetings
(including providers that put `us02web.zoom.us/j/…?pwd=…` directly in `LOCATION`) therefore show a
useful pin-label instead of a long URL.

### Concurrency

AppKit/MainActor via `@MainActor` on AppStore; fetches run through static nonisolated funcs + task
groups. Swift 5 language mode — keep new code compatible.

- `NSWorkspace.didWakeNotification` triggers a refresh (timers stall during sleep).
- Alert window: borderless NSPanel, `.screenSaver` level, `canJoinAllSpaces`, key-monitor handles
  esc/return/s. ALL three live in `AlertController.installMonitor()` — never rely on SwiftUI
  `keyboardShortcut` alone there: the snooze button is conditionally rendered, and a shortcut
  attached to a vanishing view silently dies (that's why "s" used to beep for started meetings). "s"
  snoozes while any event is still running (`end > now`), matching the button + hint; ⌘W/⌘M are
  swallowed silently (they'd beep on the borderless panel). Plain digits **1-9** join the Nth shown
  event (`joinIndex`, cards carry numbered badges) — with several simultaneous meetings, Return
  alone joining "the first" would be a bad guess. **Keyboard focus**: a timer-fired panel can't take
  focus as a background `.accessory` app (macOS ignores `activate()` without user interaction →
  keystrokes invisibly went to the app behind the overlay). `present()`/`closePanel()` therefore
  call `policyDidChange`, which runs `AppDelegate.syncActivationPolicy()` → app goes `.regular`
  while the alert is up (Dock icon + our menu bar — the accepted cost) and back to `.accessory` on
  close (unless Settings is still visible). **Button appearance**: the panel remains visible while
  inactive; native prominent/bordered controls can become black-on-black in inactive Light mode.
  `AlertJoinButtonStyle` and `AlertSecondaryButtonStyle` therefore own the fill and white label for
  every alert action; secondary actions deliberately have no outline, while
  `Palette.alertButtonColor` bounds the Join fill luminance — do not hand alert-button appearance
  back to system styles. **Plain Return**: nothing focused → global join/close; a control focused
  (Full Keyboard Access makes something ALWAYS focused) → `performClick` the focused NSButton
  (`.pressFocused`) — macOS buttons only natively respond to Space, so passing Return through made
  it dead; a focused Join must never be overridden by "join first meeting". **Keystroke guard**: for
  1 s after a fresh `present()` the key monitor swallows ALL keystrokes silently
  (`AlertController.keystrokeGuardInterval`, pure `keystrokeGuardActive` for the boundary) —
  keystrokes in flight from what the user was typing when the panel stole key focus must never
  join/snooze/close. The footer shortcut-hint row stays hidden until the guard expires (its fade-in
  = "keyboard live"; "esc close" is the last/right-most hint); any click in the panel (monitor also
  watches `leftMouseDown`) ends the guard early; previews arm the guard too (they must show the real
  behavior); a generation token keeps a stale expiry from disarming a newer panel; merges into an
  open panel never re-arm it. Quit while the alert shows asks "Quit now / Dismiss Reminder / Cancel"
  (`AlertController.modalAlertActive` yields the key monitor while that dialog is up).

## Gotchas

### zsh `path` is `$PATH`

`for path in …` overwrites the command lookup PATH, so later external commands (including inside the
same loop) fail with "command not found" — and `|| true`/`2>/dev/null` swallow it.
`scripts/update-smoke.sh`'s cleanup once silently failed to re-open the user's app this way. Use a
different loop-variable name (and absolute tool paths in cleanup paths).

- `swiftc` expression type-check blowups: break long `CGRect(...)` expressions with mixed
  Int/CGFloat math into sub-expressions (this bit `make-icon.swift`).
- `Color.quaternary`/`NSImage.withTintColor` don't exist on this target; use
  `Color.primary.opacity(...)` and manual NSImage tinting.
- Selftest constructs fixed dates in 2026 — keep deterministic (UTC/Berlin calendars explicitly).
- Icon: `make-icon.swift` renders the SF `alarm` symbol white-on-gradient; menu bar uses the same
  symbol for consistency.

### Preview isolation

real delivery replaces preview cards and resets preview state; Preview requests while real reminders
are open are ignored. Preview Join only dismisses, preview snooze only dismisses and never schedules
or writes bookkeeping, and stale Join actions are ignored. Real-to-real deliveries still merge. Pure
transition/action tests cover cancellation, mute, and reschedule reconciliation.

### Paused agenda

pause suppresses reminder delivery but keeps dropdown event rows and Join actions available
alongside Resume Now. `python3 scripts/reminder-state-smoke.py` checks production reminder state and
native menu actions using disposable loopback feeds and a unique app/preferences domain, without
opening reminder panels or accessing real calendars.

### Notification delivery

see `Sources/Notifications.swift` and README’s notification section. Defaults preserve
fullscreen/legacy suppression; all notification features opt-in. Never auto-prompt at launch or fall
back to fullscreen on denial. Route before permission; acknowledged means accepted for delivery, not
necessarily seen. Async submissions reserve occurrences and own unique request tokens; stale
completions cannot acknowledge/delete replacements. Receipt payloads contain opaque tokens and
persisted hashes, never saved URLs; action handling resolves live events after cold restore/refresh.
ReminderLedger persists handled/snoozed state with source-scoped two-snapshot omission retention,
expiry and invalidation. Catch-up uses a launch/wake cutoff owned by a full refresh started for the
latest wake; old full completions and targeted resyncs cannot clear it. Ordinary notifications due
in the same tick group by exact start Date. Singles retain Join/Snooze; groups offer Choose Meeting
to open the agenda, with titles hidden under privacy settings. Already delivered reminders are not
re-announced to combine later arrivals; catch-up waits for its owned completion to group ongoing
meetings; upcoming reminders and explicit snoozes retain normal delivery. Sync failures notify after
five minutes per continuous episode, independently of Pause. Selftest and
`scripts/notification-smoke.py` use pure helpers/fake transport; optional `--gui` creates a
separately signed synthetic preview. Never seed installed now's calendars or preferences for tests.

### Feature guides and update notices

`FeatureGuides.swift` has the extensible catalog, persisted encountered-ID history, and shared setup
UI. Add stable IDs for new introductions (never rename). Existing profiles show newly encountered
features after either automatic or manual ZIP upgrades; fresh profiles only record introduction
history because initial setup covers those choices. Manual discovery uses `.features` without
claiming a verified installation. Notification guidance explains meetings, sync problems, and
updates; its visible sync-problem checkbox recommends on for unconfigured notification users and
preserves the value for existing notification users. Sync-only selections still require permission
before applying. Record history only at `startupHealthAcknowledged`, after the helper health commit,
never during init/start. Newly introduced update guides persist in `pendingPresentation` until their
Update Complete or What’s New window actually becomes visible; an ordinary restart resumes unseen
guides. Displayed/closed guides never repeat. A skipped/closed guide must not repeat next update;
Setup commits its choices only after authorization and capability validation, with a
cancellation/settings-change guard. Update notifications use `UpdateState.lastNotificationVersion`,
independently of the existing window/failed-install marker; obey automatic-check preference and age
gate, notify silently once/version, remove withdrawn/installed/disabled notices, and never show
automatic delayed update windows while notifyUpdates is selected. Manual checks retain their window.
`scripts/notification-smoke.py` injects fake transport and stubs archive staging only in its
disposable compilation, testing production update routing and health-committed guide history without
network.

### First launch

`SetupAssistant.swift` owns sequential onboarding, separate from update-success feature guides.
`AppStore.hadSavedProfile` captures current/legacy payload presence before defaults are re-encoded.
New profiles persist an unfinished draft in `local.tboch.now.initial-setup.v1`; existing profiles
without this marker are enrolled completed, even with no calendars. The assistant resumes on
launch/reopen until finished, then opens Settings for sources. Completed profiles launch quietly
even without calendars. It does not modify general defaults or request Calendar access. Permission
and meeting-detection checks precede the one settings commit, with generation cancellation on
close/draft changes. `SetupAssistantState.applying` copies the exposed reminder and startup/update
choices plus permission-gated notification defaults, preserving other preferences.
`AlertController.presentPreview(settings:)` supports draft snooze/sound without mutating store
settings. AppDelegate includes the assistant in activation/quit/window policy and defers automatic
update windows while it is visible. Notification smoke covers resume, denial, failed capability,
cancellation, completion, and renders each step using fake transport.

### Three-screen setup

welcome holds autostart, update checks, and notification permission; combined reminders holds
style + adjacent style-aware Preview, lead time, during-meeting delivery, and privacy; ready is a
short celebration. Permission gates effective choices without erasing the draft, so back → enable
restores choices. No dedicated notification-test step, snooze/sound/browser/catch-up/update-notice
controls, marketing copy, or inline Settings card. Hidden options retain setup defaults. New setup
defaults sync-problem notifications on, committed only with confirmed notification permission;
existing profiles keep their choice. Welcome explains notification uses, and the reminders screen
shows a secondary-colored note while notification options are unavailable. Completion without
notification permission is valid and disables every notification route, including sync problems. Old
draft step IDs migrate safely.

### Preview timing

`AlertController.previewEvent(at:settings:)` is shared by both styles; use configured lead time, and
enough sample duration to fit the selected snooze. Both styles dismiss the sample on Snooze without
scheduling, real IDs, ledger changes, or opening Join URLs. Notification previews provide Snooze
only when safe, never Join. Setup defaults to lead 60 / snooze 0 for new profiles only. Settings has
a meeting preview, not a redundant generic test button.

### Join and paused notification Snooze

agenda/menu joins acknowledge only from the lead-window boundary until event end; early link opening
preserves the reminder. Explicit notification Snooze re-arms even while paused (including
refresh-deferred responses), but delivery stays paused and ended meetings never re-fire.

### Accepted notification lifecycle

never reuse fresh-delivery routing to invalidate an accepted receipt; snooze consumption must not
erase its own notification. Group membership removals retain the original banner (approved
stale-text fallback), with live actions and no second interruption. Outstanding meeting
edits/restorations use silent, labeled replacements; explicit user actions retire replacement
intent. Hidden receipts retain failed-replacement/one-omission intent; two successful source
omissions retire it. Unique add tokens, bounded old-token aliases, and persisted acceptance markers
handle replacement races/restarts. Source occurrence keys use ICS original recurrence anchors /
native occurrenceDate; recurring agenda IDs also include the anchor to distinguish coincident moved
siblings, persist through cache, and migrate legacy ledger/receipt keys only on an exact occurrence
match. Startup protects cold receipts through the initial full refresh plus a short callback grace
period; missing-meeting clicks open the menu-bar agenda. Unchanged meeting settings in feature setup
must preserve capability checks/retries. `scripts/notification-lifecycle-smoke.swift` runs through
the notification smoke harness; `--startup-smoke` also verifies real NSMenu fallback using fake
transport.

### v2 readiness fixes

notification responses wait only for cold restore/initial refresh, never an unrelated warm refresh.
Recurring agenda IDs retain actual-start reschedule semantics and add the source occurrence
identity; legacy ledger/receipt aliases migrate only when the old calendar/UID/start matches one
event unambiguously. Explicit empty SUMMARY/LOCATION/DESCRIPTION values do not inherit the master.
DTEND without TZID/Z is independently floating and property-order invariant. DATE EXDATE/RDATE on
timed events warns and skips rather than adding midnight meetings. Malformed AppSettings scalars
default individually; decoded source UUIDs are unique across ICS/native sources. Keypad metadata is
ignored for alert shortcuts, while Command/Option/Control guards remain. Helper exit callbacks clear
timed-out install attempts; missing staging is re-prepared before any swap. `scripts/preflight.sh`
runs the build (unless --app), selftest, all notification/startup/reminder/cache/fetch/workload
smoke suites and signed updater smoke; release.sh runs it before committing or publishing.

### Preference recovery

`StoredPreferences` distinguishes absent values from undecodable/wrong-type values.
`PreferenceDecoding` records lossy model decoding without losing valid siblings. Before launch
re-encoding, preserve the first damaged payload plus the latest two failures under
`<key>.recovery.v1`; `<key>.last-good.v1` stores a valid encoded backup. Prefer a verified backup,
otherwise retain salvageable data. Legacy migration only runs when the current key is absent.
Settings/menu show a persistent recovery notice; Reviewed acknowledges it without deleting copies.
Do not prune orphan cache files or delete mismatched snapshots while the profile recovery notice is
pending (including later launches); a restored older profile can have an older URL for the same
source UUID. JSON encoding/size errors keep saved bytes and report fixed messages without logging
feed tokens. UserDefaults has no synchronous disk-error result; never claim these checks prove disk
durability. `scripts/preference-recovery-smoke.swift` runs through notification smoke in a
disposable domain. Preflight uses `--all-smokes` to compile once for recovery, notification
lifecycle, startup and GUI focus fixtures.

### Cache I/O recovery

transient read/metadata errors preserve files; validated corruption, mismatch and size violations
retire them. Failed replacement writes quarantine the obsolete live snapshot as
`<UUID>.recovery.json`, which is never auto-restored, counts toward the aggregate budget and is
removed on success/source retirement. Apply 0600 before atomic rename. Keep the no-resurrection
invariant even when saving an accepted empty feed fails.

### Updater install validation

both staging and installation use `validationProblem` for strict pinned signature plus
version/build/OS validation. Install validation runs on the updater file queue and checks
attempt/root/manifest ownership on return before setting the pending marker or spawning the helper.
Extraction polling also runs on that dedicated queue, with a locked cancellation flag, never a
blocked Swift cooperative worker. The shared redirect-gated session delivers bounded archive chunks
to `UpdateArchiveDownload`; keep early cancellation and single completion safe. Old exact `.failed`
artifacts move to Trash only after verifying the installed bundle, and active/recent artifacts
remain protected. The signed updater smoke modifies a verified staged bundle (ad-hoc signature or
trusted wrong version) before checking the install gate.

### Parser materialization cost

occurrence maps use exact original Date anchors for override replacement, retain distinct coincident
moved siblings, and iterate sorted keys. One resolved master/override revision lazily detects its
link once; never reuse a master link for an override with explicitly changed/empty fields.
`python3 scripts/parser-performance-smoke.py --compare-head` checks output equivalence and reports
timings on repeated long descriptions and thousands of coincident overrides; ordinary preflight runs
the working-copy fixtures. Across extraction, use `--compare-revision d01dbd7` to retain the
original comparison point after commits. Each variant builds a complete revision through SwiftPM;
never mix a historical parser with current models or duplicate a private core into the working
harness.

### Shared parser boundary

`Sources/NowCore/ICS.swift` holds parsing, recurrence and link policy; `Sources/ICS.swift` holds
macOS text discovery and feed materialization. Keep `NSDataDetector` in the shell and inject
candidate URLs into shared link selection. Preserve URL priority, structured-conference handling and
the lack of arbitrary-link fallback. `CalendarSubscription`/`MeetingEvent` still depend on AppKit
palette defaults and settings decoding; extraction must not silently freeze or alter those defaults.
`NowCore` must not import the shell or compile fixture substitutions. `package` access exists only
for actual app/harness consumers. The core runner does not establish full materialization, storage,
notification or Windows compatibility; grow its coverage as those rules move.

### Activation compatibility

`AppActivation.activate()` chooses `NSApp.activate()` for ordinary windows on macOS 14+. Background
reminders explicitly request the legacy API even there: signed/registered GUI smoke on macOS 26
demonstrated that the cooperative API loses keyboard focus while the legacy request works. macOS 13
also uses the legacy method. Keep activation policy owned by AppDelegate and preserve panel/window
ordering. `python3 scripts/notification-smoke.py --activation-smoke` briefly presents a synthetic
fullscreen reminder from the background, checks key focus, and confirms accessory policy is restored
on close.
