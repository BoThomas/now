# Static Review Fix Checklist

Static review performed without building, launching, or running tests, then independently re-checked. Items are grouped by priority. Check an item only after the implementation and its relevant regression coverage are complete.

## Must Fix

- [x] **Preserve cached ICS events when a refresh fails.** Full and targeted refreshes must retain the previous snapshot for each failed subscription instead of deleting its meetings. (`Sources/AppStore.swift:245-262`, `Sources/AppStore.swift:355-370`)
  *Done: extracted pure `AppStore.mergeICS` (failed subs keep cache + record error); covered by `SelfTest.fetchMergeTests`.*

- [x] **Reject stale asynchronous refresh results.** Track request generations or validate the current subscription ID, URL, and enabled state before applying a targeted or full result. Removed calendars must not be resurrected, and old requests must not overwrite newer data. (`Sources/AppStore.swift:234-262`, `Sources/AppStore.swift:355-377`)
  *Done: `mergeICS` drops results for removed/disabled/URL-edited subs; `FetchTracker` request generations drop superseded results (out-of-order targeted vs full); tested in `SelfTest.fetchMergeTests`.*

- [x] **Fix RFC timed-duration parsing.** Every duration containing `T`, including `PT30M`, `PT1H`, `P1DT2H`, and `-PT15M`, currently fails. Correctly parse these values rather than silently falling back to one hour when a feed supplies `DURATION` without `DTEND`. (`Sources/ICS.swift:226`, `Sources/ICS.swift:282-305`)
  *Done: `ICSParser.parseDuration` rewritten (strict RFC grammar, no months, sign, time part required after `T`); covered by `SelfTest.durationTests`.*

- [x] **Reject unsupported recurrence frequencies.** Never reinterpret `HOURLY`, `MINUTELY`, `SECONDLY`, malformed values, or future frequencies as daily recurrences. (`Sources/ICS.swift:354-382`)
  *Done: `RRULE.parse` only accepts DAILY/WEEKLY/MONTHLY/YEARLY; anything else → single first occurrence + per-calendar warning; tested.*

- [x] **Handle unsupported time zones safely.** Do not silently interpret unknown `TZID` values in the user's current zone. Add a pragmatic Windows/Outlook TZID-to-IANA mapping and reject still-unknown zones with a visible sync error. Full `VTIMEZONE` parsing is optional if unknown zones fail safely. (`Sources/ICS.swift:248-280`)
  *Done: ~90-entry Windows TZID map + GUID-prefix handling; unknown zones (incl. unimplemented VTIMEZONE-only zones) skip the event with a visible per-calendar warning (user decision: warning tier, not hard sync error); `SelfTest.zoneTests`.*

- [x] **Merge or queue newly due alerts.** A new reminder must not replace an already visible reminder and permanently discard its events. (`Sources/AppStore.swift:423-437`, `Sources/AlertUI.swift:21-25`)
  *Done: `AlertController.present` merges into the open panel via pure `mergedShown` (dedupe by id, deterministic order); tested.*

- [x] **Replace the 45-second reminder deadline.** Define a robust late-delivery policy that still alerts after sleep, delayed launch, delayed refresh, or temporary UI blocking. (`Sources/AppStore.swift:428-429`)
  *Done: reminders fire from the lead window until `now < event.end` (running meetings alert late, ended ones never); injectable `AppStore.now` clock + pure `dueForAlert` tested for wake/delayed-launch/delayed-refresh scenarios.*

- [x] **Schedule reminder-related timers in a suitable run-loop mode.** Tick, refresh, menu-bar, and EventKit debounce timers must not stop during menu tracking or modal loops. (`Sources/AppStore.swift:93-95`, `Sources/AppStore.swift:191-196`, `Sources/AppStore.swift:440-445`, `Sources/MenuBar.swift:20-22`)
  *Done: `AppStore.commonTimer` adds all four timers to the main run loop in `.common` mode. **Manual check pending**: hold the status menu open across a reminder deadline (see Targeted Manual Verification).*

- [x] **Stop silently approximating unsupported RRULE semantics.** Either implement each accepted rule correctly or reject it and expose a useful sync error. (`Sources/ICS.swift:19-49`, `Sources/ICS.swift:318-383`)
  *Done: strict `RRULE.parse` (unknown keys, BYWEEKNUM/BYYEARDAY/BYHOUR/BYMINUTE/BYSECOND, ordinal BYDAY on daily/weekly, yearly plain BYDAY, COUNT+UNTIL → rejected with warning) + rewritten expander implementing what it accepts; `SelfTest.recurrenceTests`.*

## Should Fix

- [x] **Enforce main-actor isolation.** Add appropriate `@MainActor` isolation to `AppStore`, `AlertController`, and `NativeCalendarSource`, including the EventKit permission path. Current call sites are mostly main-thread routed, so this is primarily contract enforcement and protection against future races rather than a confirmed current failure. (`Sources/AppStore.swift:6`, `Sources/AppStore.swift:158-167`, `Sources/NativeCalendars.swift:17-20`, `Sources/AlertUI.swift:8`)
  *Done: `@MainActor` on AppStore/AlertController/NativeCalendarSource/MenuBarController/AppDelegate; pure+testable members `nonisolated`; notification/timer closures hop via `MainActor.assumeIsolated` (main-queue/main-runloop delivery). Builds clean in Swift 5 mode; selftest green.*

- [x] **Respect focused alert controls when Return is pressed.** The global monitor must not join the first meeting when another Join button, Snooze, Close, or another control has focus. Only plain Return should trigger the global shortcut; modified Return must pass through. (`Sources/AlertUI.swift:101-133`, `Sources/AlertUI.swift:179-200`, `Sources/AlertUI.swift:305-314`)
  *Done: pure `AlertController.keyAction` — plain Return with a focused control PRESSES that control (`.pressFocused` → Return is translated into a Space keypress: macOS buttons activate via Space, and SwiftUI's FKA focus elements aren't NSButton first responders, so performClick beeps); nothing focused → global join/close; modified Return passes through. Manually verified incl. Full Keyboard Access.*

- [x] **Implement common monthly recurrence forms.** Support ordinal `BYDAY` values such as `1MO` and `-1FR`, negative `BYMONTHDAY`, and monthly `BYDAY`. (`Sources/ICS.swift:35-43`, `Sources/ICS.swift:369-375`)
  *Done: implemented in the rewritten expander (ordinal/plain BYDAY, negative BYMONTHDAY, BYSETPOS on monthly); tested.*

- [x] **Handle additional RRULE fields explicitly.** Implement or reject `BYMONTH`, `BYSETPOS`, `WKST`, `BYHOUR`, `BYMINUTE`, and `BYSECOND`. (`Sources/ICS.swift:20-47`)
  *Done: BYMONTH (monthly filter + yearly month selection), BYSETPOS (monthly), WKST (weekly week boundaries) implemented; BYHOUR/BYMINUTE/BYSECOND (+BYWEEKNUM/BYYEARDAY, unknown keys) rejected with warning; tested.*

- [x] **Enforce the exact recurrence window end.** Do not emit an occurrence later than `windowEnd` merely because it is on the same day. (`Sources/ICS.swift:332-341`)
  *Done: `occ <= windowEnd` enforced exactly in `RRULEExpander.occurrences` (and single events/overrides/RDATEs); boundary-tested on both window edges.*

- [x] **Fast-forward recurrence expansion and cap aggregate work.** Output and per-event iteration are already bounded, but each event can still perform up to 20,000 calendar-day operations and a feed can contain many recurring events. This work runs off the main actor, so the primary risks are CPU, battery, and fetch latency rather than direct UI blocking. Fast-forward old anchors, which also avoids silently losing recurrences anchored more than about 55 years ago, and enforce a feed-level work budget. (`Sources/ICS.swift:319-349`, `Sources/ICS.swift:535-543`)
  *Done: COUNT-less rules fast-forward to the window; per-event cap 20k + feed-level 200k budget with warnings (incl. COUNT-anchored-too-far warning); tested (1995-anchored weekly still expands).*

- [x] **Support or reject `RDATE` and `RANGE=THISANDFUTURE`.** Do not silently omit additional dates or apply range overrides as one-off changes. (`Sources/ICS.swift:179-222`, `Sources/ICS.swift:548-555`)
  *Done: RDATE implemented (master-zone inheritance, exdate-able, deduped); RANGE overrides rejected with a warning and the master occurrence kept; tested.*

- [x] **Inherit master data in detached recurrence overrides.** Omitted title, location, notes, link, end, and duration values should inherit from the master event. (`Sources/ICS.swift:537-570`)
  *Done: `ICSBuilder.inheriting` fills title/location/notes/link props/duration from the master; overrides without DTSTART (bare cancellations) work via the RECURRENCE-ID date; tested.*

- [x] **Resolve duplicate event revisions.** Use `SEQUENCE`, `DTSTAMP`, or an explicit revision policy so stale and current VEVENT revisions are not both emitted. (`Sources/ICS.swift:179-222`, `Sources/ICS.swift:535-555`)
  *Done: highest SEQUENCE, then latest DTSTAMP wins for masters and per-RECURRENCE-ID overrides; duplicate (uid,start) emission deduped; tested.*

- [x] **Reject invalid event durations.** Do not turn negative duration, zero duration, or `DTEND <= DTSTART` into a one-minute event. Reject invalid RFC duration syntax such as `P1M`. (`Sources/ICS.swift:226-242`, `Sources/ICS.swift:282-305`)
  *Done: invalid/negative/zero durations and `DTEND <= DTSTART` fall back to the 1-hour default (never 1 minute); tested for all cases.*

- [x] **Implement text unescaping left to right.** Prevent escaped backslashes followed by `n`, comma, or semicolon from being reinterpreted by later replacements. (`Sources/ICS.swift:308-315`)
  *Done: single-pass scanner; literal `\\n` survives; tested.*

- [x] **Define and test recurrence timestamp matching.** RFC recurrence identity is exact, so prefer normalized exact matching. Normalize at parse time, including letting TZID-less EXDATE and RECURRENCE-ID values inherit the master's DTSTART zone, rather than adding match-time slack. Retain a tolerance only if a real compatibility case demonstrates deliberate second-level drift; document and regression-test that case and ensure nearby legitimate occurrences cannot be conflated. (`Sources/ICS.swift:340`, `Sources/ICS.swift:550`)
  *Done: exact `Date` equality everywhere; TZID-less EXDATE/RECURRENCE-ID/RDATE inherit the master's zone at build time; no match-time slack retained (no known drift case); tested.*

- [x] **Improve meeting-link ranking.** Prefer actual join-like URLs over unrelated pages on known providers, and preserve the documented field priority over `ATTACH`. (`Sources/ICS.swift:395-411`)
  *Done: candidates ranked by join-quality (join-like+known > join-like > known > other) then field order (location → description → alt-desc → title → attach); Google-Meet-style root links count as join links; tested.*

- [x] **Consider all conference and attachment properties.** A bad first property must not hide a valid later browser link. (`Sources/ICS.swift:189-193`, `Sources/ICS.swift:216-217`)
  *Done: first *valid* CONFERENCE/ATTACH wins (garbage skipped); tested.*

- [x] **Reconcile an open alert with refreshed events.** Close or update cards when meetings are cancelled, removed, disabled, rescheduled, or otherwise changed. (`Sources/AppStore.swift:380-397`, `Sources/AppStore.swift:412-419`)
  *Done: `commitEvents` → `AlertController.reconcile` via pure `reconciledShownEvents` (vanished events drop, changed events update, rescheduled = new id → fresh reminder when due); preview alerts exempt; tested.*

- [x] **Deduplicate events by stable identity.** Avoid duplicate reminder cards and duplicate SwiftUI `ForEach` IDs. (`Sources/AppStore.swift:387-396`, `Sources/AppStore.swift:423-437`)
  *Done: `AppStore.normalizedEvents` dedupes every commit; alert merging dedupes by id; tested.*

- [x] **Define and implement pause, snooze, and dismissal persistence.** In particular, decide whether indefinite pause and unexpired snoozes survive relaunch. (`Sources/AppStore.swift:39`, `Sources/AppStore.swift:55-56`, `Sources/AppStore.swift:265-291`)
  *Done (user decision): `pausedUntil` (incl. indefinite) persists via `Persisted`; snoozes and alerted memory reset on relaunch so a delayed launch still alerts for a due/running meeting; Persisted round-trip + legacy decode tested.*

- [x] **Calculate tomorrow at 09:00 with calendar arithmetic.** Do not add a fixed 86,400 seconds across daylight-saving transitions. (`Sources/AppStore.swift:274-283`)
  *Done: `AppStore.nextMorning` (start-of-day + set-hour); tested across both 2026 Berlin DST transitions; now always pauses until *tomorrow* 09:00, matching the menu label.*

- [x] **Refresh the available native-calendar list on every EventKit store change.** Do not require an enabled native calendar before updating available calendar metadata. (`Sources/AppStore.swift:191-197`)
  *Done: the debounce guard no longer requires an enabled calendar; `fetchNativeEvents` refreshes infos and only fetches events when something is enabled.*

- [x] **Measure EventKit query latency and set a UI/reminder budget.** `events(matching:)` is synchronous and potentially slow, but the current main-thread design is deliberate. Before collecting results, document a pass/fail latency budget; then measure representative stores with `--native`, including warm queries and cold-cache queries after launch and wake. Complete the item with recorded measurements if they pass, or move/restructure the query behind a generation guard if they fail. (`Sources/AppStore.swift:174-188`, `Sources/NativeCalendars.swift:89-103`)
  *Done: budget documented (<50 ms warm / <500 ms cold, in `fetchEvents` docs); `--native` prints per-calendar timings. Recorded measurement (dev machine, 2 calendars, warm): 9 ms + 4 ms = 14 ms total — PASS. Cold-cache measurement after launch/wake should be re-checked on a heavier production store.*

- [x] **Align native and ICS fetch-window semantics.** Explicitly enforce the intended start-time bounds on the EventKit path. (`Sources/NativeCalendars.swift:91-102`)
  *Done: explicit `startDate ∈ [windowStart, windowEnd]` + `endDate > windowStart` filters (matching ICS), plus latency-budget documentation.*

- [x] **Distinguish last sync attempt from last successful sync.** Do not label a failed attempt as “Last synced.” (`Sources/AppStore.swift:355-373`, `Sources/SettingsUI.swift:663-664`)
  *Done: `lastRefresh` now only updates when every fetched subscription succeeded; menu + settings labels are truthful.*

- [x] **Verify activation policy after Settings closes, then fix if reproduced.** Static ordering suggests `windowWillClose` may run while `isVisible` is still true, but this needs a GUI check on the supported macOS versions. If the Dock icon remains, re-evaluate asynchronously after close; an unconditional idempotent re-evaluation through `syncActivationPolicy()` is also acceptable hardening. (`Sources/App.swift:136-150`)
  *Done: idempotent async re-evaluation added after every close. **Manual/visual check pending** (red button/⌘W/Quit dialog → Dock icon must vanish — see Targeted Manual Verification).*

- [x] **Route every Quit entry point through the custom quit flow.** The status menu must not bypass the Settings confirmation or active-alert handling. (`Sources/MenuBar.swift:100`, `Sources/MenuBar.swift:191-193`, `Sources/App.swift:82-112`)
  *Done: status-menu Quit now calls the shared `handleQuitRequest()` via an injected handler (⌘Q, app menu, status menu identical). Automated test of the GUI flows isn't feasible headless — behavior covered by code review + manual verification note.*

- [x] **Make multi-event alerts scrollable.** Keep later events and footer controls reachable on small displays and with accessibility text sizes. (`Sources/AlertUI.swift:159-173`, `Sources/AlertUI.swift:280-321`)
  *Done: event list wrapped in a ScrollView. **Manual/visual check pending** (small display + accessibility text sizing — see Targeted Manual Verification).*

- [x] **Correct alert keyboard instructions for no-link events.** Do not claim Return will join when it actually closes the reminder. (`Sources/AlertUI.swift:123-129`, `Sources/AlertUI.swift:201-203`)
  *Done: hint says "return close" when no shown event has a link.*

- [x] **Keep user-selected colors contrast-safe.** Use calendar colors decoratively or derive readable text and control colors for light, dark, and low-contrast selections. (`Sources/AlertUI.swift:232-260`, `Sources/SettingsUI.swift:288-298`)
  *Done: `Palette.readable(_:on:)` (luminance-floor lightening/darkening, pure + tested) — alert countdown/Join buttons/gradient use the readable variant on black; settings link text adapts to colorScheme. **Manual/visual check pending** in both appearances.*

- [x] **Allow stale native calendars to be forgotten when no current calendars exist.** Render stale rows independently of `nativeCalendarInfos.isEmpty`. (`Sources/SettingsUI.swift:699-715`, `Sources/SettingsUI.swift:786-805`)
  *Done: stale rows render in both branches. **Manual/visual check pending** (needs a live EventKit account change).*

- [x] **Protect private ICS URLs.** Calendar URLs frequently contain bearer-like tokens. Consider Keychain storage and display only a sanitized host or account hint outside the editor. (`Sources/Models.swift:4-14`, `Sources/AppStore.swift:473-488`, `Sources/SettingsUI.swift:349-354`)
  *Done (user decision: display sanitization only): rows show host-only (`SubscriptionRow.displayURL`); the full URL is visible solely inside the edit sheet. Keychain migration deliberately deferred — noted as future work.*

- [x] **Require HTTPS or explicitly warn before accepting HTTP feeds.** Do not silently send private calendar tokens over plaintext connections. (`Sources/AppStore.swift:340-343`, `Sources/SettingsUI.swift:509-510`, `Sources/SettingsUI.swift:568-569`)
  *Done: Add/Edit show an explicit warning dialog before accepting an HTTP link (`CalendarURL.confirmInsecureHTTP`).*

- [x] **Limit downloaded feed size and parser workload.** Prevent a malformed or hostile feed from consuming unbounded memory or CPU. (`Sources/AppStore.swift:315-331`, `Sources/AppStore.swift:340-352`)
  *Done: 5 MB download cap, 200k-line / 10k-char line caps in the parser, 10k events per feed, 200k-iteration feed recurrence budget — all surfaced as errors/warnings. (Body is downloaded before the size check; the 25 s timeout bounds the transient spike — documented in code.)*

- [x] **Validate decoded settings and color indices.** Normalize or reject unsupported lead times, refresh intervals, late visibility values, sound names, colors, and extreme indices. Avoid `abs(Int.min)`. (`Sources/Models.swift:23-30`, `Sources/Models.swift:50-60`, `Sources/Models.swift:86-94`, `Sources/Helpers.swift:6-8`)
  *Done: decode-time clamping/snapping to the offered values; `Palette.nsColor` positive modulo (Int.min-safe); tested in `SelfTest.settingsTests`.*

- [x] **Represent actual launch-at-login state.** Model `.enabled`, `.requiresApproval`, external disablement, and registration failures separately from persisted user intent. (`Sources/AppStore.swift:458-470`, `Sources/SettingsUI.swift:877`)
  *Done: `LoginItemControlling` seam + `SystemLoginItem`, published `loginItemState` (enabled/disabled/requiresApproval/failed) resolved by pure `resolvedLoginItemState`, refreshed on didBecomeActive (external changes adopted); Settings shows approval/failure hints, menu reflects actual state; state mapping tested. **Manual/visual check of the requiresApproval UI pending** (needs a real registration dance).*

- [x] **Require stable signing for releases.** Do not let an arbitrary signing failure silently produce an ad-hoc release that invalidates Calendar grants. Keep ad-hoc fallback limited to explicit development builds. (`build-app.sh:28-36`, `release.sh:155-158`)
  *Done: `./build-app.sh --require-identity` (used by `release.sh`) fails hard when the "now Developer" identity is missing; ad-hoc remains dev-only.*

- [x] **Resolve the macOS SDK dynamically.** Use `xcrun --show-sdk-path` or equivalent instead of requiring exactly `MacOSX15.4.sdk`. (`build-app.sh:8`, `build-app.sh:18-22`)
  *Done: `SDK_PATH="${SDK_PATH:-$(xcrun --show-sdk-path)}"` with override.*

- [x] **Correct README signing terminology.** Remove the contradiction between “ad-hoc signed” and the stable self-signed release identity. (`README.md:25`, `README.md:56`)
  *Done: download note now says "signed with a stable self-signed identity (not notarized with Apple)".*

## Can Fix

- [x] **Use modern EventKit authorization spelling for clarity.** `.authorized` and `.fullAccess` are aliases with raw value 3 in the target SDK, while `.writeOnly` is 4, so current behavior is already correct. An availability branch may still clarify the macOS 14 API and avoid deprecated terminology. (`Sources/NativeCalendars.swift:43-45`, `Sources/SettingsUI.swift:686-693`, `Sources/App.swift:188-205`)
  *Done: `isAuthorized` branches on availability (`fullAccess` on 14+, `.authorized` before); alias regression test added.*

- [x] **Parse quoted property parameters correctly.** Preserve semicolons inside quoted values and account for escaped quotes. Current behavior is unlikely to affect the `VALUE`, `TZID`, and `ENCODING` parameters the app consumes, but it is parser noncompliance. (`Sources/ICS.swift:130-158`)
  *Done: quote-aware param splitting; tested (semicolons, colons, escaped quotes).*

- [x] **Parse component boundaries case-insensitively.** Accept valid mixed-case `BEGIN:VEVENT` and `END:VEVENT` tokens. Real-world producers overwhelmingly emit uppercase, so this is defensive compatibility. (`Sources/ICS.swift:97-105`)
  *Done: token comparison uppercased/trimmed; tested.*

- [x] **Trim status values before comparison.** RFC producers should not pad values, but trimming prevents malformed whitespace from making a cancelled event appear active. (`Sources/ICS.swift:195-196`, `Sources/ICS.swift:539`, `Sources/ICS.swift:553`)
  *Done: STATUS trimmed + uppercased; tested with padded and lowercase values.*

- [x] **Make two-consecutive-miss bookkeeping match its documentation.** A second identical missing snapshot currently skips pruning. The stale entries are inert because `tick()` only reads current events, so this is cleanup correctness rather than active reminder behavior. (`Sources/AppStore.swift:387-395`)
  *Done: `AppStore.prunedBookkeeping` runs on every commit; second identical miss prunes; tested in `SelfTest.bookkeepingTests`.*

- [x] **Use deterministic event ordering for equal start times.** Add stable tie-breakers such as calendar, title, and ID. (`Sources/ICS.swift:574`, `Sources/AppStore.swift:388`)
  *Done: `AppStore.normalizedEvents` sorts by (start, calendar, title, id); ICSBuilder uses the same tie-breakers.*

- [x] **Prevent duplicate normalized subscription URLs.** Avoid duplicate fetches and reminders for the same feed. (`Sources/SettingsUI.swift:504-517`, `Sources/SettingsUI.swift:563-575`)
  *Done: `CalendarURL.normalize` (webcal→https, lowercased scheme/host, trailing slash) + duplicate rejection in Add/Edit; tested.*

- [x] **Disable status-menu Refresh while syncing.** Avoid queuing an unnecessary complete refresh. (`Sources/MenuBar.swift:89`)
  *Done.*

- [x] **Add useful status-item accessibility state.** Include the app name, meeting name, start time, paused state, and running/late state as appropriate. (`Sources/MenuBar.swift:26-50`)
  *Done: `setAccessibilityLabel` with app name + paused/no-meetings/next-meeting/running variants. **Manual VoiceOver check pending** (see Targeted Manual Verification).*

- [x] **Name hidden-label and icon-only Settings controls for accessibility.** Include the affected calendar in toggle, color-picker, edit, delete, and expand labels. (`Sources/SettingsUI.swift:335-380`, `Sources/SettingsUI.swift:412-446`)
  *Done: accessibility labels added incl. calendar names (both row types). **Manual VoiceOver check pending**.*

- [x] **Avoid presenting no-link events as unavailable menu items.** Use an informational presentation that does not imply the event itself is disabled. (`Sources/MenuBar.swift:136-154`)
  *Done: no-link rows stay enabled with a no-op action instead of a grayed-out item.*

- [x] **Make the Settings window resizable.** Improve support for small displays, accessibility scaling, and longer text. (`Sources/App.swift:114-121`)
  *Done: `.resizable` + minSize 520×480. **Manual/visual check pending**.*

- [x] **Make `AppStore.start()` idempotent and add lifecycle cleanup.** Invalidate timers and remove observers before replacement and during deinitialization. (`Sources/AppStore.swift:82-98`)
  *Done: `started` guard + `deinit` invalidating all three timers and removing the didBecomeActive observer.*

- [x] **Wrap or truncate long unbroken tooltip tokens.** Prevent URLs and identifiers from creating extremely wide tooltips. (`Sources/Helpers.swift:119-139`)
  *Done: `Fmt.wrapped` chunks overlong tokens at the wrap width; tested.*

- [x] **Recover valid persisted entries individually.** One malformed subscription or native calendar should not discard the entire persisted state. (`Sources/Models.swift:97-113`, `Sources/AppStore.swift:479-490`)
  *Done: `FailableDecoded` per-element recovery; malformed settings → defaults; tested.*

## Must Add Tests

- [x] Add a regression test confirming that `.authorized`/`.fullAccess` are readable aliases, while `.writeOnly`, `.denied`, `.restricted`, and `.notDetermined` are not readable.

- [x] After adding an injectable fetch seam, test that a failed full refresh preserves cached events and reminder eligibility.
  *Seam = pure `AppStore.mergeICS` + `FetchTracker` (no AppStore/EKEventStore constructed).*

- [x] After adding an injectable fetch seam, test that a failed targeted refresh preserves cached events and records its error.

- [x] After adding an injectable fetch seam, test removal, disabling, and URL editing while requests are in flight.

- [x] After adding an injectable fetch seam, test out-of-order targeted and full refresh completion.

- [x] Test `DURATION:PT30M`, `PT1H`, and `P1DT2H`.

- [x] Test zero, negative, malformed, and unsupported duration values, including `P1M`.

- [x] Test `DTEND <= DTSTART` handling.

- [x] Test that unsupported or malformed recurrence frequencies never become daily recurrences.

- [x] Test unknown `TZID`, common Windows/Outlook mappings, parse-time inheritance for TZID-less recurrence exceptions, and safe rejection of unimplemented `VTIMEZONE` definitions.

- [x] After adding an injectable clock, test wake, delayed launch, and delayed refresh after the current 45-second cutoff.

- [x] After extracting reminder scheduling into a clock-driven pure helper, test a newly due meeting while another reminder is already open; use the existing injectable `onAlert` closure to capture delivery.

- [x] After extracting alert key-event classification into a pure function, test focused Join, Snooze, and Close buttons against global Return handling.

- [x] After extracting alert key-event classification into a pure function, test plain versus modified Return, Escape, `s`, Command-W, and Command-M.

- [x] After extracting event commit and pruning decisions into a pure function, test two identical consecutive missing snapshots and bookkeeping pruning without constructing `AppStore` or `EKEventStore`.

- [x] After extracting event-to-open-alert reconciliation behind a pure decision or alert-controller seam, test cancellation, removal, disabling, and rescheduling while an alert is open.

- [x] After extracting event normalization from `commitEvents`, test duplicate event IDs without constructing `AppStore` or `EKEventStore`.

- [x] After extracting the next-morning date calculation into a pure helper, test “tomorrow 09:00” across both daylight-saving transitions.

- [x] Test persisted-state migration and malformed or out-of-range settings, colors, subscriptions, and native calendars.
  *Malformed/out-of-range settings, colors (hex fallback, palette modulo, contrast derivation), subscriptions and native calendars: covered in `SelfTest.settingsTests`. The legacy-UserDefaults-domain migration hop (`loadState`) deliberately has no automated test — driving it would write junk into the app's real defaults domain.*

- [x] Enforce actor isolation at compile time and verify the project builds with the chosen strict-concurrency settings; do not add a runtime unit test for actor annotations.

## Should Add Tests

- [x] Test monthly `BYMONTHDAY`, negative `BYMONTHDAY`, ordinal `BYDAY`, and `BYSETPOS`.

- [x] Test RRULE `COUNT`, `UNTIL`, `INTERVAL`, and `WKST` semantics.

- [x] Test yearly recurrences, leap-day events, DST gaps, and DST overlaps.

- [x] Test exact `windowStart` and `windowEnd` boundaries.

- [x] Test `RDATE` and `RANGE=THISANDFUTURE` handling.

- [x] Test detached override inheritance for title, location, notes, link, end, and duration.

- [x] Test moved and cancelled detached occurrences both into and out of the fetch window.

- [x] Test duplicate masters and overrides with differing `SEQUENCE` and `DTSTAMP`.

- [x] Test recurrence workload limits and old recurrence fast-forwarding.

- [x] Test quoted parameters containing semicolons, colons, and escaped quotes.

- [x] Test lowercase and mixed-case component boundaries.

- [x] Test escaped backslash combinations, including a literal `\\n`.

- [x] Test cancellation status with surrounding whitespace.

- [x] Test multiple conference and attachment properties.

- [x] Test known-host non-join URLs against actual join URLs on unknown hosts.

- [x] Test attachment versus location and description link priority.

- [x] Test pause, snooze, and dismissal behavior across relaunch.

- [x] Test identical behavior from every Quit entry point.
  *Manually verified: ⌘Q / app menu / status menu all confirm while Settings is key; quit-while-alert-showing now asks "Quit now / Dismiss Reminder / Cancel" (dialog above the panel, alert's key monitor yields via `modalAlertActive`); plain quit with nothing open terminates.*

- [x] Test stale native-calendar cleanup after all EventKit calendars disappear.
  *Manually verified (Internet Accounts → Calendars off/on): warning row + Forget appear even with zero calendars left; Forget works; calendar reconnects when the account returns.*

- [x] After introducing a login-item abstraction, test enabled, disabled, externally disabled, requires-approval, and failure states.

- [x] Test duplicate URL normalization and prevention.

- [x] After introducing an access-request abstraction, test permission-request reentrancy and repeated clicks without invoking TCC.
  *Done via the pure `AccessRequestGate` (single-flight, no TCC involved); `SelfTest.settingsTests`.*

- [x] Strengthen the CRLF regression test to compare IDs, timestamps, titles, durations, and links, not only event counts. (`Sources/SelfTest.swift:142-144`)

## Post-Review UX Additions (manual-pass feedback)

- [x] **Numbered cards + keys 1-9 to join a specific meeting in multi-event alerts.** Plain Return alone joining only the first card was flagged as bad UX during the manual pass. Cards now carry numbered badges (calendar-color filled, contrast-safe); plain digits join that card; Return joins the first (or the only) event; the hint line explains both. Covered by `SelfTest` digit-classification tests + a manual multi-event check with the local test feed.

- [x] **Settings section sidebar with ⌘1-5 quick jumps (wide windows ≥880 pt).** Entries for all five sections with scroll-following selection; holding ⌘ for ~0.35 s fades in `⌘N` hints in a reserved-width slot (nothing shifts); VoiceOver reads clean titles with selected-trait; below the threshold the sidebar disappears and the form fills the window (default window size widened to 940×720 so the sidebar shows out of the box).

- [x] **Responsive Settings layout for the now-resizable window.** Calendar rows and event rows wrap their action buttons/join links to a second line via `ViewThatFits` instead of crushing the title block; the lead-time presets flow in an adaptive grid (multiple rows, re-wrapping with width); the "Hide events I've declined" toggle is left-aligned again. *(Visual check by user pending — see below.)*

## Verification For Every Completed Change

- [x] Add or update focused regression coverage.
- [x] Run `./build-app.sh`.
- [x] Run `./outputs/now.app/Contents/MacOS/now --selftest`.
- [x] For startup, Settings, menu-bar, alert, or lifecycle changes, perform the documented GUI smoke test.

*All four were performed after every completed item during the fix pass (build + selftest after each phase, `launch → alive after ~4 s → kill` GUI smoke after every startup/lifecycle/UI change; `--parse`/`--native` CLI smoke for parser + EventKit paths). These stay an obligation for future changes, not a one-time task.*

## Targeted Manual Verification

> **Status:** these need a human with eyes on the screen (or a model with screen capture / input injection). The implementing agent could not verify them — automated checks cover the logic, not the visuals. Recommended order: keyboard/alert items first (regressions there are most likely), then accessibility, then the policy/lifecycle checks.

- [x] Hold the status menu open across a reminder deadline and verify reminder delivery after the timer scheduling change.
  *Manually verified with a local 12-event test feed — reminder appears over the tracking menu.*

- [x] Open, minimize, reopen, and close Settings with the red button, Command-W, and the Quit dialog's “Close Settings” action; verify `.regular` to `.accessory` transitions and immediate Dock-icon removal.
  *Manually verified — all green.*

- [x] Show a large multi-event alert on a small display and verify all cards and controls remain reachable.
  *Manually verified with a 12-event feed: list scrolls, later cards reachable, footer controls stay visible (fixed-size fonts mean accessibility text scaling doesn't rescale the alert — noted).*

- [x] Verify alert layout and controls with accessibility text sizing and Full Keyboard Access.
  *FKA navigation verified (Tab/Space/Return); alert uses fixed-size fonts so macOS text-size settings don't rescale it — layout robustness verified via the 12-event overflow test.*

- [x] Verify status-item and Settings control labels with VoiceOver.
  *Manually verified — status item speaks meeting/time/paused state; Settings controls announce their purpose incl. calendar names.*

- [x] Verify focused Join, Snooze, and Close controls plus plain and modified Return in the alert panel.
  *Manually verified: Space on focused buttons ✓, focused Return (via Return→Space translation) ✓, plain Return with FKA off ✓, modified Return (⇧/⌘) ✓, esc ✓, s ✓, ⌘W/⌘M ✓, quit-vs-dismiss dialog ✓.*
