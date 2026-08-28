# Static Review Fix Checklist

Static review performed without building, launching, or running tests, then independently re-checked. Items are grouped by priority. Check an item only after the implementation and its relevant regression coverage are complete.

## Must Fix

- [ ] **Preserve cached ICS events when a refresh fails.** Full and targeted refreshes must retain the previous snapshot for each failed subscription instead of deleting its meetings. (`Sources/AppStore.swift:245-262`, `Sources/AppStore.swift:355-370`)

- [ ] **Reject stale asynchronous refresh results.** Track request generations or validate the current subscription ID, URL, and enabled state before applying a targeted or full result. Removed calendars must not be resurrected, and old requests must not overwrite newer data. (`Sources/AppStore.swift:234-262`, `Sources/AppStore.swift:355-377`)

- [ ] **Fix RFC timed-duration parsing.** Every duration containing `T`, including `PT30M`, `PT1H`, `P1DT2H`, and `-PT15M`, currently fails. Correctly parse these values rather than silently falling back to one hour when a feed supplies `DURATION` without `DTEND`. (`Sources/ICS.swift:226`, `Sources/ICS.swift:282-305`)

- [ ] **Reject unsupported recurrence frequencies.** Never reinterpret `HOURLY`, `MINUTELY`, `SECONDLY`, malformed values, or future frequencies as daily recurrences. (`Sources/ICS.swift:354-382`)

- [ ] **Handle unsupported time zones safely.** Do not silently interpret unknown `TZID` values in the user's current zone. Add a pragmatic Windows/Outlook TZID-to-IANA mapping and reject still-unknown zones with a visible sync error. Full `VTIMEZONE` parsing is optional if unknown zones fail safely. (`Sources/ICS.swift:248-280`)

- [ ] **Merge or queue newly due alerts.** A new reminder must not replace an already visible reminder and permanently discard its events. (`Sources/AppStore.swift:423-437`, `Sources/AlertUI.swift:21-25`)

- [ ] **Replace the 45-second reminder deadline.** Define a robust late-delivery policy that still alerts after sleep, delayed launch, delayed refresh, or temporary UI blocking. (`Sources/AppStore.swift:428-429`)

- [ ] **Schedule reminder-related timers in a suitable run-loop mode.** Tick, refresh, menu-bar, and EventKit debounce timers must not stop during menu tracking or modal loops. (`Sources/AppStore.swift:93-95`, `Sources/AppStore.swift:191-196`, `Sources/AppStore.swift:440-445`, `Sources/MenuBar.swift:20-22`)

- [ ] **Stop silently approximating unsupported RRULE semantics.** Either implement each accepted rule correctly or reject it and expose a useful sync error. (`Sources/ICS.swift:19-49`, `Sources/ICS.swift:318-383`)

## Should Fix

- [ ] **Enforce main-actor isolation.** Add appropriate `@MainActor` isolation to `AppStore`, `AlertController`, and `NativeCalendarSource`, including the EventKit permission path. Current call sites are mostly main-thread routed, so this is primarily contract enforcement and protection against future races rather than a confirmed current failure. (`Sources/AppStore.swift:6`, `Sources/AppStore.swift:158-167`, `Sources/NativeCalendars.swift:17-20`, `Sources/AlertUI.swift:8`)

- [ ] **Respect focused alert controls when Return is pressed.** The global monitor must not join the first meeting when another Join button, Snooze, Close, or another control has focus. Only plain Return should trigger the global shortcut; modified Return must pass through. (`Sources/AlertUI.swift:101-133`, `Sources/AlertUI.swift:179-200`, `Sources/AlertUI.swift:305-314`)

- [ ] **Implement common monthly recurrence forms.** Support ordinal `BYDAY` values such as `1MO` and `-1FR`, negative `BYMONTHDAY`, and monthly `BYDAY`. (`Sources/ICS.swift:35-43`, `Sources/ICS.swift:369-375`)

- [ ] **Handle additional RRULE fields explicitly.** Implement or reject `BYMONTH`, `BYSETPOS`, `WKST`, `BYHOUR`, `BYMINUTE`, and `BYSECOND`. (`Sources/ICS.swift:20-47`)

- [ ] **Enforce the exact recurrence window end.** Do not emit an occurrence later than `windowEnd` merely because it is on the same day. (`Sources/ICS.swift:332-341`)

- [ ] **Fast-forward recurrence expansion and cap aggregate work.** Output and per-event iteration are already bounded, but each event can still perform up to 20,000 calendar-day operations and a feed can contain many recurring events. This work runs off the main actor, so the primary risks are CPU, battery, and fetch latency rather than direct UI blocking. Fast-forward old anchors, which also avoids silently losing recurrences anchored more than about 55 years ago, and enforce a feed-level work budget. (`Sources/ICS.swift:319-349`, `Sources/ICS.swift:535-543`)

- [ ] **Support or reject `RDATE` and `RANGE=THISANDFUTURE`.** Do not silently omit additional dates or apply range overrides as one-off changes. (`Sources/ICS.swift:179-222`, `Sources/ICS.swift:548-555`)

- [ ] **Inherit master data in detached recurrence overrides.** Omitted title, location, notes, link, end, and duration values should inherit from the master event. (`Sources/ICS.swift:537-570`)

- [ ] **Resolve duplicate event revisions.** Use `SEQUENCE`, `DTSTAMP`, or an explicit revision policy so stale and current VEVENT revisions are not both emitted. (`Sources/ICS.swift:179-222`, `Sources/ICS.swift:535-555`)

- [ ] **Reject invalid event durations.** Do not turn negative duration, zero duration, or `DTEND <= DTSTART` into a one-minute event. Reject invalid RFC duration syntax such as `P1M`. (`Sources/ICS.swift:226-242`, `Sources/ICS.swift:282-305`)

- [ ] **Implement text unescaping left to right.** Prevent escaped backslashes followed by `n`, comma, or semicolon from being reinterpreted by later replacements. (`Sources/ICS.swift:308-315`)

- [ ] **Define and test recurrence timestamp matching.** RFC recurrence identity is exact, so prefer normalized exact matching. Normalize at parse time, including letting TZID-less EXDATE and RECURRENCE-ID values inherit the master's DTSTART zone, rather than adding match-time slack. Retain a tolerance only if a real compatibility case demonstrates deliberate second-level drift; document and regression-test that case and ensure nearby legitimate occurrences cannot be conflated. (`Sources/ICS.swift:340`, `Sources/ICS.swift:550`)

- [ ] **Improve meeting-link ranking.** Prefer actual join-like URLs over unrelated pages on known providers, and preserve the documented field priority over `ATTACH`. (`Sources/ICS.swift:395-411`)

- [ ] **Consider all conference and attachment properties.** A bad first property must not hide a valid later browser link. (`Sources/ICS.swift:189-193`, `Sources/ICS.swift:216-217`)

- [ ] **Reconcile an open alert with refreshed events.** Close or update cards when meetings are cancelled, removed, disabled, rescheduled, or otherwise changed. (`Sources/AppStore.swift:380-397`, `Sources/AppStore.swift:412-419`)

- [ ] **Deduplicate events by stable identity.** Avoid duplicate reminder cards and duplicate SwiftUI `ForEach` IDs. (`Sources/AppStore.swift:387-396`, `Sources/AppStore.swift:423-437`)

- [ ] **Define and implement pause, snooze, and dismissal persistence.** In particular, decide whether indefinite pause and unexpired snoozes survive relaunch. (`Sources/AppStore.swift:39`, `Sources/AppStore.swift:55-56`, `Sources/AppStore.swift:265-291`)

- [ ] **Calculate tomorrow at 09:00 with calendar arithmetic.** Do not add a fixed 86,400 seconds across daylight-saving transitions. (`Sources/AppStore.swift:274-283`)

- [ ] **Refresh the available native-calendar list on every EventKit store change.** Do not require an enabled native calendar before updating available calendar metadata. (`Sources/AppStore.swift:191-197`)

- [ ] **Measure EventKit query latency and set a UI/reminder budget.** `events(matching:)` is synchronous and potentially slow, but the current main-thread design is deliberate. Before collecting results, document a pass/fail latency budget; then measure representative stores with `--native`, including warm queries and cold-cache queries after launch and wake. Complete the item with recorded measurements if they pass, or move/restructure the query behind a generation guard if they fail. (`Sources/AppStore.swift:174-188`, `Sources/NativeCalendars.swift:89-103`)

- [ ] **Align native and ICS fetch-window semantics.** Explicitly enforce the intended start-time bounds on the EventKit path. (`Sources/NativeCalendars.swift:91-102`)

- [ ] **Distinguish last sync attempt from last successful sync.** Do not label a failed attempt as “Last synced.” (`Sources/AppStore.swift:355-373`, `Sources/SettingsUI.swift:663-664`)

- [ ] **Verify activation policy after Settings closes, then fix if reproduced.** Static ordering suggests `windowWillClose` may run while `isVisible` is still true, but this needs a GUI check on the supported macOS versions. If the Dock icon remains, re-evaluate asynchronously after close; an unconditional idempotent re-evaluation through `syncActivationPolicy()` is also acceptable hardening. (`Sources/App.swift:136-150`)

- [ ] **Route every Quit entry point through the custom quit flow.** The status menu must not bypass the Settings confirmation or active-alert handling. (`Sources/MenuBar.swift:100`, `Sources/MenuBar.swift:191-193`, `Sources/App.swift:82-112`)

- [ ] **Make multi-event alerts scrollable.** Keep later events and footer controls reachable on small displays and with accessibility text sizes. (`Sources/AlertUI.swift:159-173`, `Sources/AlertUI.swift:280-321`)

- [ ] **Correct alert keyboard instructions for no-link events.** Do not claim Return will join when it actually closes the reminder. (`Sources/AlertUI.swift:123-129`, `Sources/AlertUI.swift:201-203`)

- [ ] **Keep user-selected colors contrast-safe.** Use calendar colors decoratively or derive readable text and control colors for light, dark, and low-contrast selections. (`Sources/AlertUI.swift:232-260`, `Sources/SettingsUI.swift:288-298`)

- [ ] **Allow stale native calendars to be forgotten when no current calendars exist.** Render stale rows independently of `nativeCalendarInfos.isEmpty`. (`Sources/SettingsUI.swift:699-715`, `Sources/SettingsUI.swift:786-805`)

- [ ] **Protect private ICS URLs.** Calendar URLs frequently contain bearer-like tokens. Consider Keychain storage and display only a sanitized host or account hint outside the editor. (`Sources/Models.swift:4-14`, `Sources/AppStore.swift:473-488`, `Sources/SettingsUI.swift:349-354`)

- [ ] **Require HTTPS or explicitly warn before accepting HTTP feeds.** Do not silently send private calendar tokens over plaintext connections. (`Sources/AppStore.swift:340-343`, `Sources/SettingsUI.swift:509-510`, `Sources/SettingsUI.swift:568-569`)

- [ ] **Limit downloaded feed size and parser workload.** Prevent a malformed or hostile feed from consuming unbounded memory or CPU. (`Sources/AppStore.swift:315-331`, `Sources/AppStore.swift:340-352`)

- [ ] **Validate decoded settings and color indices.** Normalize or reject unsupported lead times, refresh intervals, late visibility values, sound names, colors, and extreme indices. Avoid `abs(Int.min)`. (`Sources/Models.swift:23-30`, `Sources/Models.swift:50-60`, `Sources/Models.swift:86-94`, `Sources/Helpers.swift:6-8`)

- [ ] **Represent actual launch-at-login state.** Model `.enabled`, `.requiresApproval`, external disablement, and registration failures separately from persisted user intent. (`Sources/AppStore.swift:458-470`, `Sources/SettingsUI.swift:877`)

- [ ] **Require stable signing for releases.** Do not let an arbitrary signing failure silently produce an ad-hoc release that invalidates Calendar grants. Keep ad-hoc fallback limited to explicit development builds. (`build-app.sh:28-36`, `release.sh:155-158`)

- [ ] **Resolve the macOS SDK dynamically.** Use `xcrun --show-sdk-path` or equivalent instead of requiring exactly `MacOSX15.4.sdk`. (`build-app.sh:8`, `build-app.sh:18-22`)

- [ ] **Correct README signing terminology.** Remove the contradiction between “ad-hoc signed” and the stable self-signed release identity. (`README.md:25`, `README.md:56`)

## Can Fix

- [ ] **Use modern EventKit authorization spelling for clarity.** `.authorized` and `.fullAccess` are aliases with raw value 3 in the target SDK, while `.writeOnly` is 4, so current behavior is already correct. An availability branch may still clarify the macOS 14 API and avoid deprecated terminology. (`Sources/NativeCalendars.swift:43-45`, `Sources/SettingsUI.swift:686-693`, `Sources/App.swift:188-205`)

- [ ] **Parse quoted property parameters correctly.** Preserve semicolons inside quoted values and account for escaped quotes. Current behavior is unlikely to affect the `VALUE`, `TZID`, and `ENCODING` parameters the app consumes, but it is parser noncompliance. (`Sources/ICS.swift:130-158`)

- [ ] **Parse component boundaries case-insensitively.** Accept valid mixed-case `BEGIN:VEVENT` and `END:VEVENT` tokens. Real-world producers overwhelmingly emit uppercase, so this is defensive compatibility. (`Sources/ICS.swift:97-105`)

- [ ] **Trim status values before comparison.** RFC producers should not pad values, but trimming prevents malformed whitespace from making a cancelled event appear active. (`Sources/ICS.swift:195-196`, `Sources/ICS.swift:539`, `Sources/ICS.swift:553`)

- [ ] **Make two-consecutive-miss bookkeeping match its documentation.** A second identical missing snapshot currently skips pruning. The stale entries are inert because `tick()` only reads current events, so this is cleanup correctness rather than active reminder behavior. (`Sources/AppStore.swift:387-395`)

- [ ] **Use deterministic event ordering for equal start times.** Add stable tie-breakers such as calendar, title, and ID. (`Sources/ICS.swift:574`, `Sources/AppStore.swift:388`)

- [ ] **Prevent duplicate normalized subscription URLs.** Avoid duplicate fetches and reminders for the same feed. (`Sources/SettingsUI.swift:504-517`, `Sources/SettingsUI.swift:563-575`)

- [ ] **Disable status-menu Refresh while syncing.** Avoid queuing an unnecessary complete refresh. (`Sources/MenuBar.swift:89`)

- [ ] **Add useful status-item accessibility state.** Include the app name, meeting name, start time, paused state, and running/late state as appropriate. (`Sources/MenuBar.swift:26-50`)

- [ ] **Name hidden-label and icon-only Settings controls for accessibility.** Include the affected calendar in toggle, color-picker, edit, delete, and expand labels. (`Sources/SettingsUI.swift:335-380`, `Sources/SettingsUI.swift:412-446`)

- [ ] **Avoid presenting no-link events as unavailable menu items.** Use an informational presentation that does not imply the event itself is disabled. (`Sources/MenuBar.swift:136-154`)

- [ ] **Make the Settings window resizable.** Improve support for small displays, accessibility scaling, and longer text. (`Sources/App.swift:114-121`)

- [ ] **Make `AppStore.start()` idempotent and add lifecycle cleanup.** Invalidate timers and remove observers before replacement and during deinitialization. (`Sources/AppStore.swift:82-98`)

- [ ] **Wrap or truncate long unbroken tooltip tokens.** Prevent URLs and identifiers from creating extremely wide tooltips. (`Sources/Helpers.swift:119-139`)

- [ ] **Recover valid persisted entries individually.** One malformed subscription or native calendar should not discard the entire persisted state. (`Sources/Models.swift:97-113`, `Sources/AppStore.swift:479-490`)

## Must Add Tests

- [ ] Add a regression test confirming that `.authorized`/`.fullAccess` are readable aliases, while `.writeOnly`, `.denied`, `.restricted`, and `.notDetermined` are not readable.

- [ ] After adding an injectable fetch seam, test that a failed full refresh preserves cached events and reminder eligibility.

- [ ] After adding an injectable fetch seam, test that a failed targeted refresh preserves cached events and records its error.

- [ ] After adding an injectable fetch seam, test removal, disabling, and URL editing while requests are in flight.

- [ ] After adding an injectable fetch seam, test out-of-order targeted and full refresh completion.

- [ ] Test `DURATION:PT30M`, `PT1H`, and `P1DT2H`.

- [ ] Test zero, negative, malformed, and unsupported duration values, including `P1M`.

- [ ] Test `DTEND <= DTSTART` handling.

- [ ] Test that unsupported or malformed recurrence frequencies never become daily recurrences.

- [ ] Test unknown `TZID`, common Windows/Outlook mappings, parse-time inheritance for TZID-less recurrence exceptions, and safe rejection of unimplemented `VTIMEZONE` definitions.

- [ ] After adding an injectable clock, test wake, delayed launch, and delayed refresh after the current 45-second cutoff.

- [ ] After extracting reminder scheduling into a clock-driven pure helper, test a newly due meeting while another reminder is already open; use the existing injectable `onAlert` closure to capture delivery.

- [ ] After extracting alert key-event classification into a pure function, test focused Join, Snooze, and Close buttons against global Return handling.

- [ ] After extracting alert key-event classification into a pure function, test plain versus modified Return, Escape, `s`, Command-W, and Command-M.

- [ ] After extracting event commit and pruning decisions into a pure function, test two identical consecutive missing snapshots and bookkeeping pruning without constructing `AppStore` or `EKEventStore`.

- [ ] After extracting event-to-open-alert reconciliation behind a pure decision or alert-controller seam, test cancellation, removal, disabling, and rescheduling while an alert is open.

- [ ] After extracting event normalization from `commitEvents`, test duplicate event IDs without constructing `AppStore` or `EKEventStore`.

- [ ] After extracting the next-morning date calculation into a pure helper, test “tomorrow 09:00” across both daylight-saving transitions.

- [ ] Test persisted-state migration and malformed or out-of-range settings, colors, subscriptions, and native calendars.

- [ ] Enforce actor isolation at compile time and verify the project builds with the chosen strict-concurrency settings; do not add a runtime unit test for actor annotations.

## Should Add Tests

- [ ] Test monthly `BYMONTHDAY`, negative `BYMONTHDAY`, ordinal `BYDAY`, and `BYSETPOS`.

- [ ] Test RRULE `COUNT`, `UNTIL`, `INTERVAL`, and `WKST` semantics.

- [ ] Test yearly recurrences, leap-day events, DST gaps, and DST overlaps.

- [ ] Test exact `windowStart` and `windowEnd` boundaries.

- [ ] Test `RDATE` and `RANGE=THISANDFUTURE` handling.

- [ ] Test detached override inheritance for title, location, notes, link, end, and duration.

- [ ] Test moved and cancelled detached occurrences both into and out of the fetch window.

- [ ] Test duplicate masters and overrides with differing `SEQUENCE` and `DTSTAMP`.

- [ ] Test recurrence workload limits and old recurrence fast-forwarding.

- [ ] Test quoted parameters containing semicolons, colons, and escaped quotes.

- [ ] Test lowercase and mixed-case component boundaries.

- [ ] Test escaped backslash combinations, including a literal `\\n`.

- [ ] Test cancellation status with surrounding whitespace.

- [ ] Test multiple conference and attachment properties.

- [ ] Test known-host non-join URLs against actual join URLs on unknown hosts.

- [ ] Test attachment versus location and description link priority.

- [ ] Test pause, snooze, and dismissal behavior across relaunch.

- [ ] Test identical behavior from every Quit entry point.

- [ ] Test stale native-calendar cleanup after all EventKit calendars disappear.

- [ ] After introducing a login-item abstraction, test enabled, disabled, externally disabled, requires-approval, and failure states.

- [ ] Test duplicate URL normalization and prevention.

- [ ] After introducing an access-request abstraction, test permission-request reentrancy and repeated clicks without invoking TCC.

- [ ] Strengthen the CRLF regression test to compare IDs, timestamps, titles, durations, and links, not only event counts. (`Sources/SelfTest.swift:142-144`)

## Verification For Every Completed Change

- [ ] Add or update focused regression coverage.

- [ ] Run `./build-app.sh`.

- [ ] Run `./outputs/now.app/Contents/MacOS/now --selftest`.

- [ ] For startup, Settings, menu-bar, alert, or lifecycle changes, perform the documented GUI smoke test.

## Targeted Manual Verification

- [ ] Hold the status menu open across a reminder deadline and verify reminder delivery after the timer scheduling change.

- [ ] Open, minimize, reopen, and close Settings with the red button, Command-W, and the Quit dialog's “Close Settings” action; verify `.regular` to `.accessory` transitions and immediate Dock-icon removal.

- [ ] Show a large multi-event alert on a small display and verify all cards and controls remain reachable.

- [ ] Verify alert layout and controls with accessibility text sizing and Full Keyboard Access.

- [ ] Verify status-item and Settings control labels with VoiceOver.

- [ ] Verify focused Join, Snooze, and Close controls plus plain and modified Return in the alert panel.
