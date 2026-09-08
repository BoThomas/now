# Code Review — 9 September 2026: everything since v1.10.0

> Scope: `v1.10.0..HEAD` (`31aec66`), 6 commits / 2 feature PRs:
> - **PR #11 offline cache** (`d8cbd0b`): `CalendarEventCache`, restore-before-refresh, offline/expired status, quit disk barrier.
> - `41c9f75`: reminder panel resize on display changes.
> - **PR #12 notifications** (`f8d130d`, `d5e855c`): notification delivery + ledger, sync-failure/update notices, feature guides, first-launch assistant, native in-meeting catch-up.
>
> Method: full read of every diff plus the current state of the touched files,
> cross-checked against the invariants recorded in AGENTS.md and
> `docs/plans/notification-reminders.md`. Static review only — nothing was
> built, run, or modified this session (no prebuilt binary in `outputs/`; a
> proper build needs the unsandboxed `--require-identity` signing pass).
> Findings below are ranked by (likelihood × impact). Everything is
> reading-verified; nothing was reproduced at runtime.

> **Follow-up:** The verification and disposition section at the end supersedes
> the original verdicts where noted. Original findings are retained for context.

## Findings — worth fixing or deciding

### P1. A cancelled logout leaves the app permanently inert — medium impact, low likelihood

`applicationShouldTerminate` (`Sources/App.swift:143-151`) now **always**
returns `.terminateLater` and replies `true` once the cache queue is idle.
`AppStore.prepareForTermination` (`Sources/AppStore.swift:254-259`) sets
`shuttingDown = true`, invalidates `tickTimer` and `refreshTimer`, and there
is **no path that ever resets it** (verified: the flag's only writes are the
declarations and line 255).

If a session logout/shutdown is aborted *after* now has begun terminating —
typically because the user cancels another app's save prompt, or another app
vetoed the session — now keeps running with:

- no tick timer → no reminders, no notification `reconcile()`, no sync-problem notices, frozen `displayTime`,
- `refresh`/`resync`/`merge`/`tick` all no-op via the `shuttingDown` guards (AppStore.swift:567, 581, 799, 1013),
- while `MenuBarController.buttonTimer` (owned elsewhere) keeps painting, so the app *looks* alive — the worst kind of failure: silent, until a missed meeting.

The user-initiated paths are safe (quit confirmations run before
`NSApp.terminate`), and `terminateForUpdate` is fine; the hole is
specifically session-wide termination that gets cancelled while our
terminateLater modal loop is pending or just after we replied.

Fix sketch (not applied): after arming the barrier, schedule a watchdog —
e.g. `RunLoop.main.perform` in `.common` after ~2 s — that, if the process is
still alive, clears `shuttingDown`, reschedules the timers, and continues.
Replying from the queue completion should cancel the watchdog. Alternatively
reply immediately and treat the barrier as best-effort, but the watchdog is
the smaller change. Secondary hardening: the reply currently has no timeout
if the serial cache queue were ever to block (writes are size-bounded, so
this is theoretical — mention only).

### P2. A pre-wake in-flight refresh can clear the wake catch-up boundary early — low likelihood, mild impact

`beginNotificationCatchUp` (AppStore.swift:1047) stamps
`catchUpBoundary` at wake; `finishRefresh` (AppStore.swift:884-896) clears it
on the **first** refresh completion and groups catch-up in the tick just
before that. Meetings already known at wake are seeded correctly (from
`events` + `commitEvents` re-insertion while the boundary is set).

But if a refresh that started **before sleep** is still in flight at wake
(its requests typically fail immediately on wake), *its* `finishRefresh`
runs first and clears the boundary. A running meeting that is **first
discovered by the wake fetch** (invite accepted / calendar changed while
asleep) then routes through the ordinary style in a later tick — e.g. a
fullscreen takeover even though the user chose “Use notification” for
launch/wake catch-up.

The plan’s wording (“first refresh completion collects asynchronously
arriving calendars”) suggests the intent is the first completion *after the
boundary was stamped*. Fix sketch: tag the boundary with the request
generation and let only the refresh started after `beginNotificationCatchUp`
clear it (or clear it only when the completing refresh began after the
boundary date).

### P3. Joining from the agenda/menu now permanently suppresses that occurrence's reminder — deliberate, confirm the tradeoff

`joinedMeeting` → `acknowledge` (AppStore.swift:1135-1141) is called from the
menu join action (`Sources/MenuBar.swift:502`), the Settings agenda join
(`Sources/SettingsUI.swift:434`), and the details-popover join
(`Sources/MenuBar.swift:530`). Joining at **any** point before the lead
window puts the occurrence into `alerted` + `ReminderLedger` — the upcoming
reminder never fires, and this now survives restart.

The code comment states this is intended (“An explicit join from the
menu/agenda also handles its reminder”), and joining a meeting you're in
makes its reminder pointless. The behavior change vs v1.10.0 (join used to
leave reminder state untouched) is worth being aware of in two cases:

- a **mistaken** join (wrong row clicked) silently eats the reminder;
- joining a link **well ahead of time** (opening tomorrow's meeting URL to
  paste the link into a chat) also suppresses tomorrow's reminder.

If that's too aggressive, the fix would be to only acknowledge when the join
happens inside the lead window (`now >= start - leadSeconds`). Flagging for a
product decision, not necessarily a change.

### P4. Notification “Snooze” clicked while reminders are paused acknowledges permanently — accidental-looking fallback

`handleNotificationResponse` (AppStore.swift:1154-1171): the snooze branch is
`if action == "snooze", !isPaused`; a snooze click while paused falls into the
`else`, which `acknowledge(current)`s — the reminder is then never
redelivered even after Pause ends. Compare the fullscreen alert, whose
snooze path (`AlertController.applySnooze` → `store.snooze`) has no pause
guard and snoozes normally.

In practice this is nearly unreachable: `validNotification` returns false
while paused and `reconcile()` (every tick) discards delivered meeting
notifications, so the banner is usually gone before it can be clicked. But
that's exactly why the branch reads like an accident rather than a decision —
it only fires in the sub-second race where the user clicks as pause lands. If
the intent is “paused snooze = handled”, a comment saying so would help;
otherwise let it snooze (or open details without acknowledging).

### P5. A transient probe failure at launch wipes a persisted delivery choice — pre-existing pattern, wider blast radius now

`start()` → `setInMeetingDelivery(settings.inMeetingDelivery)`
(AppStore.swift:223, 725-767): when meeting detection is configured
(suppress **or** notify-during-meeting) the launch-time capability probe
runs, and on **any** failure `settings.inMeetingDelivery` is reset to
`.normal`. A one-off CoreAudio hiccup at boot silently turns the user's
in-meeting behavior off until they notice and re-enable. v1.10.0 had the
same reset for the suppression toggle, so this is not a regression — but the
new `.notification` mode means the same failure now also silently downgrades
an explicit notification choice. Consider keeping the persisted choice,
leaving detection stopped + error shown (it's already retryable), and
re-probing on next launch instead of rewriting settings.

### P6. Dead/misleading machinery in `FeatureGuideState` — cleanup

`Sources/FeatureGuides.swift:26-37`: `hasCalendar` is unused (the inline
Settings-guide path it fed was removed), `pendingSettings.removeAll()`
followed by `pendingSettings.subtract(ids)` is a provable no-op, and
`settingsIDs`/`finish(_:)`/`pendingSettings` now manipulate an always-empty
set. Harmless, but the next contributor may “re-enable” inline cards against
machinery that no longer does anything, or wonder why `hasCalendar` exists.
Either delete the leftovers or leave a comment that inline guides were
retired in favor of the setup assistant.

### P7. `onPermissionChange` is never wired — dead code

`Sources/Notifications.swift:216` — invoked at lines 239/249/271 but no
owner ever assigns it (`AppStore.connectNotifications` sets validate/
onSubmitted/onResponse/onMeetingPreview only). Delete it or wire it (e.g. to
`menuNeedsUpdate` signature changes) — as-is it's a trap for readers
assuming permission changes propagate somewhere.

### P8. Two parallel encodings of suppression semantics can drift

Production routing now goes through `NotificationLogic.route`
(`Sources/Notifications.swift:13-30`, keyed on `inMeetingDelivery`), while
`AppStore.meetingReminderDecision` (AppStore.swift:~1218, keyed on
`suppressRemindersDuringMeetings: Bool`) survives only as a SelfTest fixture
(verified: no production call sites). Both encode “defer before start /
dismiss after start / fail-open on unknown”. Nothing is wrong today, but a
future edit to one and not the other passes the selftest while production
behaves differently. Consider porting the selftest fixtures to
`NotificationLogic.route` and deleting the old helper, or adding a
cross-check that both agree on the legacy matrix.

### P9. Cache total-budget overflow deletes that source's previous good snapshot — sharp but intentional edge

`CalendarEventCache.save` (`Sources/CalendarEventCache.swift:145-152`): when
the newly encoded snapshot would exceed 64 MB total (or 16 MB per source),
the catch **removes the existing file for that same source** before
reporting the storage issue. This is the documented staleness rule (“a
successful new feed must not leave an older disk snapshot behind”), and the
failure is surfaced per-source in Settings — but note the cumulative effect:
adding a large new calendar can strip offline copies one source at a time as
each later sync busts the budget. Acceptable; just be aware the offline
guarantee silently degrades near the 64 MB ceiling rather than evicting
oldest-first.

### P10. Simultaneous ordinary reminders produce one banner per meeting; only catch-up groups — confirm intended

`tick()` (AppStore.swift:1028-1034) offers `offerNotification([event])`
per due event, so two meetings becoming due in the same second with delivery
= notification yield **two** notifications (each independently Join-able),
while catch-up groups into one generic notification with a meeting picker
(`NotificationLogic.content(events:)`'s `count != 1` branch exists only for
that path). Per-event banners are arguably *better* here (independent Join),
but the asymmetry looks unintentional given the grouped-content helper
exists. Confirm it's a decision, not an oversight.

## Behavior notes (probably intended — recorded so they're conscious)

- **Pause removes delivered meeting notifications** (`validNotification`
  `guard !isPaused`, AppStore.swift:1099 → `reconcile()` →
  `removeDeliveredNotifications` every tick). Sync-failure notifications are
  deliberately exempt (plan says diagnostics are pause-independent) and
  update notices too (`item.sync`/`updateVersion` are filtered out of the
  pause-sensitive validation).
- **Every Settings entry point is diverted to the setup assistant while
  setup is pending** (`App.swift:281`), including the sync-error
  notification's Details action and the menu problem rows. First-run only;
  fine, but the sync-error “Details…” lands on the assistant rather than
  calendar settings in that window.
- **`notificationInteraction`'s 1 s/0.25 s reopen heuristic**
  (`App.swift:28-38, 164-177`) uses real `Date()` (not the injected store
  clock) and swallows a Finder double-click that lands within 1 s after a
  notification click. Acceptable for a UX race guard.
- **Meeting moves invalidate delivered notifications correctly**: since
  `MeetingEvent.id` embeds the start timestamp (`Models.swift:284`), a
  rescheduled occurrence no longer matches the receipt key and the banner is
  removed by `reconcile()`. No stale “Starts at …” content risk. (Checked
  explicitly because the receipt `fingerprint` omits `start` — the id makes
  that moot.)
- **Launch-time detection probe failure semantics** are the documented
  “toggle stays off” design (see P5 for the widening concern).
- **`calendarSyncProblemTitle` wording** (“Offline · Using saved calendars ·
  Details…”) only treats `NSURLErrorNotConnectedToInternet` as offline —
  intentional per AGENTS; DNS/timeout failures surface via the generic
  failed-to-sync row instead.
- **`emptyAgendaText` override**: a single source with expired saved
  coverage flips the whole empty-agenda row to “Saved calendar coverage
  expired. Refresh needed.” even when the emptiness is really about other,
  healthy sources. Mildly overreaching copy; low priority.
- **The setup assistant's welcome screen can be finished with notifications
  still not granted** (choices are gated via `effective`), which commits
  fullscreen/normal routes — validated as intentional by the plan
  (“Completion without notification permission is valid”).

## Nits

- `notifySyncProblems` (AppStore.swift:1190) force-unwraps
  `syncNotificationTracker.firstFailure[UUID(uuidString: $0)!]!` while
  building fingerprints — safe today only because `candidates()` mutates
  synchronously just above; one refactor away from a crash.
- `AlertController.observeDisplayChanges` registers two observers that can
  both fire for one screen change; the handler is idempotent, so harmless.
- `ReminderNotificationController.persist()` rewrites the receipts plist on
  every discard (a few per session) — negligible, but `persistReminderLedger`
  already does change-detection; receipts could too.
- `AppStore.snooze` (AppStore.swift:681) silently drops snooze entries whose
  event vanished/was muted/ended between menu click and application — the
  intended “stale clicks leave the reminder open” behavior, just noting the
  guard lives in the store *and* in `AlertController.snoozeSchedule`.
- `CalendarDownload`/`fetchTransport` cancellation message (“Calendar fetch
  cancelled”) is indistinguishable from a hard error in the UI; unchanged
  from v1.10.0.

## What's notably good (keep)

- **The at-most-once notification bookkeeping is genuinely careful**:
  unique per-attempt tokens so a late-cancelled submission can't delete its
  replacement, receipts persisted *before* `add()` (actions can beat
  submission or survive a crash), text stripped from disk, ledger storing
  only hashes with source-scoped two-snapshot omission retention mirroring
  `ReminderSnapshotTracker`.
- **The cache design gets the hard invariants right**: URL fingerprints
  instead of copied feed tokens, live color/name/filters re-applied on
  restore, restore gated on `matches(isEnabled && id && fingerprint)`,
  ended/coverage-expired occurrences never resurrected, serial queue for
  write ordering, request-generation-guarded issue reporting, and a quit
  barrier that replies in `.common` modes (the terminateLater modal-loop
  stall is documented *and* handled).
- **`shuttingDown` gating of merge/refresh/tick** is the right shape for a
  clean quit (only missing the recovery path — P1).
- **Migration discipline**: every new persisted shape decodes with
  `decodeIfPresent`/failable reads; the legacy suppression toggle, the
  old catch-up checkbox, five-screen setup drafts, and old update-state
  payloads all carry forward, and mutual-exclusivity invariants
  (`notifyDuringMeetings` vs `suppressRemindersDuringMeetings`) are enforced
  at decode.
- **Selftest extension stays EventKit-free** and covers routing, content
  privacy, ledger lifecycle, sync-episode timing boundaries, and the update
  gate matrix including the age-gate edge; smoke scripts use disposable
  bundle IDs/domains and loopback feeds throughout (verified in
  `notification-smoke.py` / `calendar-cache-smoke.py` headers).

## Test-coverage observations

Covered by selftest/smoke per the plan and AGENTS: routing matrix, catch-up
grouping, ledger two-snapshot/expiry/invalidation, sync episode boundaries,
update-notice eligibility, cache restore/invalidation/corruption/restart,
startup assistant flows, and the quit barrier.

Not covered anywhere I could find (matches the findings above):

1. **cancelled-session-termination recovery** (P1) — no test can easily do
   this; a watchdog would at least be self-healing.
2. **wake with a refresh already in flight** (P2) — the cache/notification
   smokes restart processes but don't interleave sleep with an in-flight
   fetch.
3. **join-before-lead-window reminder suppression** (P3) — pure and easily
   testable if the behavior is kept.
4. **the paused-snooze notification race** (P4) — pure function of
   `handleNotificationResponse` if extracted.

---

*No code was modified for this review. Re-run
`./build-app.sh --require-identity` (unsandboxed) + `--selftest` before
acting on any finding.*


## Verification and disposition — 9 September 2026

Verified against **`55aa1e0`**, rather than the original review's `31aec66`.
The intervening commit reorganizes notification settings and adds a selftest;
it does not remove the findings discussed here. This follow-up records what
we should do; it does **not** implement application changes.

The review is useful, but its ten P-labels should be treated as finding IDs,
not ten established bugs or standard severity levels. P2 is a concrete routing
bug; P4 is an inconsistent action handler; P3/P5/P10 involve product choices;
P6–P8 are cleanup; P9 is an existing explicit cache policy. P1's claimed OS
scenario remains unproven and its proposed fix is unsound.

### Disposition of each finding

| Finding | Verification / correction | What we do |
| --- | --- | --- |
| **P1 — cancelled logout** | `AppDelegate.applicationShouldTerminate` and `AppStore.prepareForTermination` do stop timers and permanently set `shuttingDown`. That proves the state transition, **not** that another app cancelling logout leaves this process alive after its affirmative reply. Apple's documented flow completes termination after that reply; a session-wide cancellation scenario needs a separate reproduction. The proposed watchdog cancels on the reply, so cannot repair the claimed post-reply survival. Before the reply, merely resetting state neither exits AppKit's termination loop nor prevents a late affirmative reply. `RunLoop.perform` also has no delay argument. | **Investigate, not an accepted P1 bug. Do not add the suggested watchdog.** Preserve the disk barrier. If a disposable AppKit reproduction demonstrates survival, design a termination-attempt state machine that coordinates cancellation, late replies and timer recovery. A timeout for genuinely stalled disk I/O is a separate policy question, not a demonstrated regression. Do not test by logging out the user's working session. |
| **P2 — old refresh ends wake catch-up** | Confirmed control flow: wake stamps the cutoff, `refresh()` finds an existing full batch and queues another, then the old `finishRefresh()` clears the cutoff before the queued batch's ICS results arrive. The native query occurs synchronously before the `isRefreshing` guard, so the example specifically concerns newly discovered ICS events. Existing `catchUpIDs` survive; newly discovered occurrences lose classification. `.skip` is affected as well as `.notification`. | **Fix first.** Give each launch/wake catch-up session an identity, bind its completion to a full batch actually started for that session, and ignore old completions for cutoff clearing. Keep classification through the queued wake batch, including repeated wakes; decide grouping readiness using that session too. Add deterministic old-batch → wake → old completion → new discovery tests for notification and skip, plus ordinary post-cutoff discoveries. |
| **P3 — early join handles reminder** | Confirmed: menu, agenda and details Join call `joinedMeeting`, which writes the acknowledgement before opening the URL. It applies even a day early and survives restart through the ledger. A wrong click *inside* the lead window would still handle the reminder under the proposed restriction. | **User decision: change this.** Acknowledge agenda/menu joins only from `start − leadSeconds` until event end; preserve reminders for earlier link opening. Add before/exactly-at-lead/running tests and a restart assertion for the chosen rule. **Approved for the implementation plan; not implemented in this review pass.** |
| **P4 — Snooze during pause** | Confirmed branch mismatch: a paused Snooze takes the acknowledgement/details branch. Important qualification: successful notification submission already acknowledges the occurrence; the bug is losing the explicit request to re-arm it, not creating the first acknowledgement. Pause removes receipts on reconcile, but queued responses can also be processed after refresh, so this is not limited to a literal sub-second click race. | **Fix.** Honor an explicit valid Snooze even while paused, using the existing safe schedule; pause continues to prevent delivery. After resume, an overdue snooze may fire only while its meeting remains active. Preserve the existing no-safe-duration details fallback. Test both direct and deferred responses. No separate product choice is needed to make Snooze consistent with fullscreen. |
| **P5 — launch probe erases preference** | Confirmed: startup calls the same enable path as a settings change; capability failure assigns `.normal`, and settings persistence saves that change. The legacy suppression path already did this. An error is exposed, so “silently” overstates the lack of diagnostics, but the saved choice really is lost. | **User decision: preserve and automatically retry.** Preserve an already-saved choice on transient startup failure, show the error, and retry with bounded backoff plus activation/wake opportunities. While activity is unknown, use the existing normal routing behavior. Keep fresh opt-in transactional: failed first-time enablement must not turn the setting on. Unsupported platforms need a clear unavailable state, not endless retries. **Approved for the implementation plan; not implemented in this review pass.** |
| **P6 — retired guide machinery** | Confirmed unused `hasCalendar`, unused `settingsIDs`, and subtract-after-clear no-op. Qualification: `pendingSettings` may decode nonempty legacy data before startup acknowledgement; it is not literally always empty. `finish` is called by the guide UI, although its set operation is redundant after acknowledgement. There is already a retirement comment. | **Cleanup when touching guides.** Remove the retired API/state and redundant persistence while retaining `encountered` history and the UI's finish callback. Verify legacy JSON still decodes without re-showing old guides. No feature change or restoration of inline cards. |
| **P7 — unassigned permission callback** | Confirmed no assignment to `onPermissionChange`. This does **not** mean permission changes fail to propagate: `permission` is published, and the menu's refresh signature includes the derived notification problem title. | **Remove the unused callback and calls.** Do not add a new owner just to justify unused machinery. Preserve published permission updates and existing menu refresh behavior. |
| **P8 — duplicate suppression policy** | Confirmed `meetingReminderDecision` is used only by older selftests. However `NotificationTests` already exercises the production `NotificationLogic.route` suppression/defer/handled paths, so the review overstates how easily every production regression could pass. | **Consolidate tests onto production routing.** Port remaining legacy matrix cases, including inactive/unknown/disabled and mixed due events, then remove the helper and unused decision type. Prefer one implementation over permanently cross-checking duplicates. |
| **P9 — cache budget failure removes old snapshot** | Confirmed `save` deletes that source's file on **any** save failure, not only a budget failure. Other sources are not evicted by that operation. Sequential failures can affect multiple sources, but losing one file also frees capacity; a cascading wipe is not inevitable. The issue is surfaced in Settings, so degradation is not silent. | **Keep the explicit stale-snapshot policy and current limits.** An older successful snapshot must not resurrect meetings removed by a newer successful fetch. Oldest-first eviction would trade away another source's offline data and is not a required fix. Existing cache smoke verifies oversized replacement removes the old file. Add aggregate 64 MB boundary coverage when cache tests next change; retain visible storage diagnostics. |
| **P10 — ordinary banners are separate** | Confirmed: `.notification` offers each event independently; `.catchUp` batches. The grouped content copy says meetings “are in progress,” so it cannot be reused unchanged for ordinary upcoming meetings. Each ordinary banner can retain its own Join/Snooze. During-meeting notification routing also takes precedence over catch-up grouping. | **User decision: keep separate ordinary notifications and grouped catch-up.** Document and test that intentional behavior. No delivery behavior change required. |

Apple references for P1: [terminate(_:)](https://developer.apple.com/documentation/appkit/nsapplication/terminate(_:))
and [applicationShouldTerminate(_:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)).
These support the ordinary AppKit termination contract; they do not establish
what happens in the claimed cancelled-session interleaving.

### Disposition of all behavior notes

| Original note | Verified disposition |
| --- | --- |
| Pause removes meeting notifications but not diagnostics/updates | **Keep.** `validNotification` handles sync/update items before the pause guard. Already-accepted meeting notifications remain acknowledged after removal; resume is not a general replay of delivered banners. Explicit Snooze is addressed in P4. |
| Settings redirects to pending setup | **Keep for first run.** `openSettings` diverts every caller, including diagnostic Details, while setup is pending. The setup completion opens Settings. This is a confirmed navigation consequence, not a general inability to reach Settings. |
| Notification/Finder reopen timing heuristic | **Keep.** Real-time one-second suppression and 0.25-second delayed reopen are present. A Finder action within that interval can be swallowed. No need to expand the injected reminder clock into AppKit interaction timing. |
| Rescheduling invalidates notifications | **Keep, qualify the claim.** IDs include the start in integer Unix seconds, so normal minute/second reschedules change receipt keys. The original absolute “no stale risk” claim does not cover a hypothetical sub-second move within the same second; no new sub-second identity work is proposed here. |
| Probe failure follows documented toggle-off design | **Consolidate into P5.** Distinguish failed fresh opt-in from restoring a preference that previously worked. |
| Offline title only recognizes not-connected error | **Keep.** `isOffline` is derived from the transport classification; DNS/timeout/HTTP failure is not proof of an offline machine. |
| Expired cache overrides empty agenda text | **Small copy fix recommended.** The override runs before normal empty-state selection and may obscure “Checking calendars.” Use a qualified message such as “No upcoming meetings. Some saved calendars need refreshing,” while preserving the refreshing state and per-source details. This is a copy/precedence improvement, not evidence of dropped events. |
| Setup can complete without notification permission | **Keep.** `SetupAssistantState.effective` and completion tests deliberately allow fullscreen/normal settings without authorization. |

### Disposition of all nits

| Nit | Verified disposition |
| --- | --- |
| Forced UUID/date unwraps in sync fingerprints | **Safe under current invariants; optional cleanup.** Candidate IDs originate as UUIDs and the synchronous tracker initializes their dates. Build ordered `(UUID, failureDate)` pairs directly to remove the stringify/parse round trip and maintain matching keys/fingerprints. No current crash reproduction. |
| Two display observers | **Keep both.** Window screen migration and display-configuration changes are distinct triggers. Duplicate delivery is harmless because the handler checks panel identity and only changes a differing frame. |
| Receipt persistence on every discard | **Defer optimization.** It JSON-encodes sanitized receipts into UserDefaults (not a direct synchronous plist rewrite). Frequency/write amplification was not measured. Do not change save-before-submission ordering merely to reduce writes. |
| Store drops stale snooze entries | **Correct the explanation; keep current validation.** The store checks live membership, mute and `fireAt < end`; it does not itself explicitly check `now < end` or keep a panel open. The caller's synchronous `snoozeSchedule` validates active events and leaves the panel open on failure; after calling the store, `applySnooze` closes it. There is no async suspension between those calls. The stated guaranteed open-panel behavior does not come from the store guard. |
| Cancellation looks like a fetch error | **Keep for now.** Cancellation is represented as a fetch error. The claim that this is user-visible is conditional on the result being accepted; generation checks discard stale results. No newly introduced cancellation UX bug was demonstrated. |

### Positive findings and coverage qualification

- **Keep notification submission safeguards.** Unique attempt IDs, receipt persistence before `add`, post-await validation, text sanitization and hashed ledger keys are present. “At most once” describes accepted-submission bookkeeping, not proof of visible presentation or a transactional guarantee across every possible process-crash instant.
- **Keep cache invariants.** Source fingerprint binding, live presentation/filter reapplication, occurrence/coverage bounds, serial disk ordering and stale-result checks are present. The cache smoke exercises restart and ordinary AppKit quit; it does not prove cancelled-logout behavior.
- **Keep termination gating**, without assuming the unproven P1 scenario or applying its watchdog sketch.
- **Keep migrations.** New notification/setup/update state has compatibility handling; the retired feature-guide state needs the legacy-data care called out in P6. “Every new persisted shape uses decodeIfPresent” is too broad: some use whole-object fallible decoding and defaults instead.
- **Keep the EventKit-free selftest.** The notification/cache integration harnesses use temporary bundles, disposable preferences and synthetic data. They replace native fetch behavior, but AppStore still constructs its production native source; they are not proof of real Calendar authorization/query behavior. They also do not establish what macOS actually displays under Focus.
- **Coverage gaps are substantially right.** Existing tests cover ordinary wake grouping and production routing, not the old-full-refresh/wake interleaving. The early-join rule and paused-Snooze race need permanent regression tests when fixed. Cancelled logout needs an isolated AppKit reproduction before becoming an implementation task.

### Validation performed in this follow-up

The application source is unchanged; review reproductions use temporary copies of the existing
notification smoke harness, exposing the same production methods that its
normal harness exposes. Native fetching is stubbed as in that harness. No
live calendar data, real notification delivery or user-session logout is
used for these checks.


| Check | Result |
| --- | --- |
| `./build-app.sh --require-identity` outside sandbox | **PASS** — stable-identity signature and designated requirement verified. |
| `./outputs/now.app/Contents/MacOS/now --selftest` | **PASS** — all suites green. |
| Existing notification smoke assertions plus temporary review reproductions | **PASS** — original assertions passed; additional cases reproduced P2, P3 and P4 and verified separate ordinary submissions for P10. |
| `python3 scripts/calendar-cache-smoke.py` outside sandbox | **PASS** — restart/offline/recovery/empty/corrupt/storage cases, four-second real AppDelegate startup, and ordinary quit draining the final accepted snapshot. Initial sandbox run could not bind its loopback server; the authorized outside-sandbox rerun passed. |
| Application source changes | **None.** Only this local review document was edited. `docs/local` is gitignored, so its edit does not appear in `git status`. |

The temporary notification reproduction explicitly drove the old-refresh/wake
completion ordering through production AppStore methods; it did not put the
machine to sleep. Its first P10 fixture accidentally used future meetings
outside the lead window. Correcting those meetings to be due made the check
pass; this was a fixture issue, not an additional application failure.
Temporary harness files: `/tmp/now-review-notification-smoke.py` and
`/tmp/now-review-notification-smoke.swift` (not permanent regression coverage).

The notification smoke compilation emitted existing actor-isolation warnings
for `settingsVisible()` in `scripts/notification-preview.swift:119`. The Swift
5 build completed. Small additional maintenance recommendation: annotate that
local helper `@MainActor` when next editing the harness.

P1 remains **unreproduced**; P5's failure path was verified statically, without
inducing a real CoreAudio outage. No new real Notification Center, Focus,
Calendar permission, display-reconfiguration or updater installation testing
was performed. Earlier coverage claims about those surfaces are not new
runtime verification from this pass.

### Agreed implementation order

1. Fix P2 catch-up ownership and P4 paused Snooze, with regression cases.
2. Implement the approved P3 lead-window join rule and P5 saved-choice retry behavior.
3. Preserve P9 cache policy and P10 separate ordinary notifications; keep their intent explicit.
4. Consolidate P8 tests and remove P6/P7 dead machinery during a focused cleanup; improve expired-cache empty-state copy and optionally remove the sync-fingerprint unwraps.
5. Leave P1 as an investigation until an isolated OS-level reproduction establishes the failure. Do not implement its proposed watchdog.

All requested product decisions have been answered and recorded above.


### Reviewer agreement and implementation constraints

The original reviewer accepted the corrected dispositions. Follow-up checks
confirmed that `v1.10.0` had no `applicationShouldTerminate` override, and that
only full refreshes call `finishRefresh`; targeted resyncs do not.

- **P1:** Quitting during an ultimately cancelled logout is not, by itself,
  evidence of a new regression: the old app already accepted termination
  immediately. This supports leaving P1 outside the release blockers. It does
  not prove every delayed-termination interleaving safe; the claim of an inert
  surviving process remains unverified. A cache-queue timeout remains a separate
  policy task, not part of the agreed fixes.
- **P2:** Carry the generation returned by `fetchTracker.beginFull` through
  completion and associate the responsible full batch with the catch-up session.
  A full-batch token alone is not the entire solution: repeated wakes can replace
  the session while that batch runs, and `pendingRefresh` must carry responsibility
  forward to the next batch. Test repeated wakes across queued full refreshes,
  with an intervening targeted resync that neither finalizes nor clears catch-up.
- **P4:** Preserve live-event, mute, end-time and safe-duration validation, plus
  the existing details fallback. Exercise both immediate and refresh-deferred
  responses using the fake transport; real Notification Center is unnecessary.
- **Release scope:** Treat P2/P4 as the confirmed correctness fixes. P3/P5 are
  approved behavior improvements with regression coverage; cleanup is secondary.
  No additional user decision is needed before implementing the agreed points.


## Implementation — 9 September 2026

This section supersedes the earlier “not implemented” status. Application changes
are now in the working tree; nothing has been released or installed over the live app.

| Item | Implementation status |
| --- | --- |
| P1 | Kept as an investigation, as agreed. No termination watchdog or timeout added. |
| P2 | Implemented full-batch ownership with `CatchUpRefreshTracker`; each wake revokes the old owner. Old completion cannot clear the latest cutoff or release its grouped notification. Targeted generations do not own completion. |
| P3 | Implemented live-event resolution and lead-window/end-boundary checks before an agenda/menu join acknowledges. Earlier joins preserve the future reminder. |
| P4 | Removed the pause guard from explicit Snooze handling. Existing safe scheduling and details fallback remain; delivery still waits for resume and stops at event end. |
| P5 | Preserves saved delivery intent on failure. Transient failures retry after 5 seconds, doubling to a five-minute cap, with earlier activation/wake retries. Fresh opt-in remains transactional; unsupported capability does not auto-retry. Generation checks reject stale success after disabling. The probe is injectable for isolated tests. |
| P6 | Removed retired guide state/API and `hasCalendar`. Encodes an empty legacy `pendingSettings` key solely so older releases can still decode encountered history after downgrade. |
| P7 | Removed the unused permission callback and invocations; published permission updates remain. |
| P8 | Removed the duplicate decision helper/type and moved remaining legacy matrix assertions onto production `NotificationLogic.route`. |
| P9 | Preserved cache behavior; added aggregate-limit tests for exact 64 MB fit, one-byte overflow, own-file removal and preservation of the other source. |
| P10 | Preserved separate ordinary notifications and grouped catch-up, with an integration assertion for independent ordinary submissions. |
| Empty agenda | Qualified the expired-cache message and retained higher-priority refreshing/error/access states. |
| Sync fingerprints | Removed UUID-string round trips and force unwraps; keys/fingerprints are built from ordered failure pairs. |
| Preview harness warning | Marked its local AppKit visibility helper `@MainActor`. |
| Remaining notes/nits | Preserved as agreed: display observers, receipt persistence, cancellation handling, pause/diagnostic distinction, setup routing and permission behavior. |

README, notification design notes and AGENTS.md now describe the selected behavior.

Final validation:

- **PASS** `./build-app.sh --require-identity` — stable signing identity and designated requirement verified.
- **PASS** `./outputs/now.app/Contents/MacOS/now --selftest` — all suites green, including legacy guide decode/downgrade, catch-up ownership, production suppression matrix, join boundaries and empty-state precedence.
- **PASS** `python3 scripts/notification-smoke.py` — existing transport/action/update/setup cases plus repeated wakes, notification/skip routing, queued full-refresh handoff, post-cutoff normal reminders, join persistence across reload, direct/deferred paused Snooze, no-safe-duration fallback, expired snooze, separate ordinary submissions, startup preference persistence, retry deadlines/cap, wake/activation recovery, failed fresh opt-in, unsupported capability and stale probe completion after disable.
- **PASS** `python3 scripts/calendar-cache-smoke.py` outside sandbox — restart/offline/recovery/storage cases, exact aggregate budget boundaries, real four-second AppDelegate startup and ordinary quit draining accepted cache writes.
- **PASS** `git diff --check`.

The first notification test compilation caught two stale harness references after
API cleanup; those were corrected. Its subsequent run caught synthetic fetches
without the request generations now created by the harness's real full-batch setup.
Those fixtures now supply their actual generations, and the final full run passed.
No validation failure remains. No real Notification Center delivery, user logout,
CoreAudio outage, or updater installation was needed or performed for these checks.
The application is built in `outputs/now.app`; deployment/release is not part of this task.
