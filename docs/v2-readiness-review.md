# now v2 readiness review

Reviewed 2026-09-09 at commit 1166b8b, version 1.10.0. Host: macOS 26.6.2, Apple Silicon.

Status: the implementation and regression-verification pass is complete for confirmed fixes that do not require product decisions. See the implementation section and final verification record; remaining product decisions and real-device checks are listed separately. The initial audit changed no application source. The subsequent authorized implementation pass changed the source and tests described below; the app version remains 1.10.0. The readiness changes and this review are being committed together; no release or tag is published. Local probe artifacts and logs remain under ignored `outputs/v2-review/`.

## Implementation pass — 2026-09-09

The user authorized fixes that do not require product decisions. Implemented: warm-refresh notification actions; recurrence collision identity and original-anchor matching; explicit empty occurrence fields; property-order-independent floating DTEND; warnings/skipping for unsupported DATE exclusions/additions on timed meetings; resilient scalar settings decoding and unique persisted source IDs; durable never-shown guides; updater missing-staging and helper-timeout recovery (including cancellation of delayed quit and stale reply protection); keypad shortcuts; live login checkmarks; documentation cleanup; and a complete mandatory release preflight.

The original findings below are retained as audit evidence, with their original line references. They describe the pre-fix commit, not the current implementation. Final verification results are recorded at the end of this document.

**Still requires product input:** ordinary notification grouping, cache retention after failed writes, and whether modified Escape should dismiss reminders. The legacy location-only fingerprint blind spot lacks historical data to reconstruct; it remains a documented migration limitation. Actual supported-OS/calendar/notification/device acceptance and refreshed screenshots remain release checks.

## Confirmed bugs

### P2 — Moving an occurrence onto another occurrence silently loses a meeting

`Sources/ICS.swift:1373` deduplicates by UID and actual start. Two separate source occurrences can legitimately share a new start after rescheduling. The second one is discarded even though its original recurrence anchor differs. `Sources/Models.swift:287` uses the same identity for agenda IDs, and `Sources/AppStore.swift:1019` deduplicates those IDs again, so fixing only the builder would be insufficient.

Reproduction: a daily series with September 10 and 11 occurrences at 10:00 UTC; move the September 10 occurrence to September 11 at 10:00, with a changed title and 30-minute duration. The production `--parse` command returns one event, titled “Regular meeting,” lasting one hour. The moved occurrence disappears without a warning. Expected: two distinguishable occurrences with their respective metadata.

Fixture: `now-v2-collision.ics`. Fix: use source occurrence anchors for recurrence identity throughout materialization and agenda bookkeeping, with compatibility handling for existing acknowledgement/snooze records. Deduplicate revisions of the same occurrence, rather than distinct occurrences sharing an actual start. Cover both input orders, coincident moved occurrences, and notification/ledger behavior.

### P2 — Explicitly cleared occurrence fields revert to the series values

`Sources/ICS.swift:550` converts empty LOCATION and DESCRIPTION values to nil. `Sources/ICS.swift:1446` then treats nil as an omitted property and inherits the master values. Explicitly clearing these fields is therefore indistinguishable from leaving them unspecified.

Reproduction: master LOCATION is “Old room” and DESCRIPTION is “Old instructions”; a detached occurrence contains explicit empty `LOCATION:` and `DESCRIPTION:`. A probe compiling the unchanged production ICS parser/builder reports “Old room” and “Old instructions” on the edited occurrence. Expected: empty location/notes. This can show obsolete meeting instructions; if inherited notes contain the meeting URL, link extraction can also keep that old destination.

Fixture: `now-v2-empty-override.ics`. Fix: retain property-presence information separately from the value and inherit only omitted fields. Add regression coverage for omitted versus explicitly empty text, including link extraction from cleared notes. The probe uses minimal value-type stubs to compile the production ICS implementation without AppKit or EventKit.

### P1 — Notification actions wait for unrelated full-refresh downloads

Confirmed by tracing `Sources/AppStore.swift:1122`, `:918` and `:856`. After startup has completed, `isRefreshing` still queues meeting Join, body-click, Snooze and dismissal responses. The queue drains only in `finishRefresh`, after every feed completes. An already loaded meeting is therefore blocked by unrelated slow calendars. Four simultaneous downloads, each with a 60-second resource deadline, can produce minutes of waiting across multiple waves; parsing adds further time. Update-notification responses bypass this queue.

Fix: retain the cold-start guards, but execute actions against available live meeting data during ordinary refreshes. Preserve missing-event fallback, stale-action validation, and paused Snooze behavior. Add a held-refresh regression proving that an existing meeting action executes before the batch completes, alongside the existing cold-start deferral coverage. Evidence here is production control-flow inspection, not a newly executed slow-feed GUI Join test.

### P2 — A never-shown update guide is permanently recorded as encountered

Confirmed by the extracted production `FeatureGuideState` probe and the display path. `Sources/Updater.swift:1052` calls `startupHealthAcknowledged` before requesting the installed window. `Sources/FeatureGuides.swift:41` records encountered IDs immediately; `Sources/App.swift:378` may defer the window behind a reminder or setup. Only in-memory `updateIDs` retain the pending guide. Quitting before display loses the guide, and the install marker has already been consumed. The probe serialized the guide history before display; after restart the pending list was empty.

Fix: persist pending guide IDs after the successful startup-health commit, then consume them when actually presented or explicitly dismissed. Resume unpresented guides across launch. Preserve the rule that a displayed guide closed/skipped by the user must not repeat, and never mark an update successful before health acknowledgement. This requires an intentional refinement of the current AGENTS.md guide-history rule, which records introduction history at health acknowledgement.

### P2 — One malformed setting resets unrelated preferences

Confirmed by a production AppSettings decoder probe. A string in `leadSeconds`, with otherwise valid custom settings, rejects the entire AppSettings object. `Sources/Models.swift:238` substitutes defaults; AppStore's initialization immediately persists them (`Sources/AppStore.swift:184`). Probe result: lead 60 → 300, sound false → true, sync notifications true → false.

Correction to the supplied finding: older booleans and strings also use throwing `decodeIfPresent`; a malformed `soundEnabled` reproduces the same reset. Only the newer notification fields consistently use `try?`. This requires malformed/type-incompatible saved data; ordinary missing keys and valid out-of-range numbers already default/clamp. No naturally occurring corruption mechanism was reproduced.

Fix: isolate decoding failure per scalar, retain normalization, and preserve an unreadable original payload for recovery before overwriting it. Test malformed numeric, boolean, string and enum fields without discarding unrelated preferences.

### P2 — Helper timeout leaves the controller holding deleted staging

Confirmed by `Sources/Updater.swift:829` and `:1323`, plus the earlier successful stuck-quit smoke. The helper deletes its staging root if the old PID survives the timeout; the controller has no result callback and retains `stagedVersion`, `stagedRoot`, and persisted `pendingInstallVersion`. A later retry from a surviving/recovered process can pass the in-memory guard despite the staged app no longer existing, then fail the staged-app rename after moving the old app to backup. Rollback protects the installed app, but this is avoidable failure UX.

Fix: verify the staged bundle still exists before installation and re-stage if absent; reconcile the failed/timed-out install attempt and pending marker, ideally with an explicit helper outcome. A file-existence check alone does not clean up the marker. Keep the existing signature gate and rollback ordering intact.

Qualification: a false installed confirmation while still running the old version is **not** established—`justInstalledVersion` requires exact version equality (`Sources/Updater.swift:309`). A stale marker can later attribute a manual installation of that same target version to the old attempt. The timeout-to-retry controller sequence was code-traced, not reproduced by deliberately hanging the user's app.

## Checks completed

All exited successfully:

- `./build-app.sh --require-identity`: stable identity signing and designated-requirement verification passed.
- Built executable `--selftest`.
- `python3 scripts/notification-smoke.py`: notification routing and lifecycle, edits/restoration, submission races, cold actions, feature history, and meeting-detection recovery.
- `python3 scripts/notification-smoke.py --startup-smoke`: fresh profile, close/reopen, completion to Settings, existing and legacy profiles.
- `python3 scripts/reminder-state-smoke.py`: reminder retention, pause/menu actions and quit routing.
- `python3 scripts/calendar-cache-smoke.py`: real isolated process restarts, offline data, invalidation, storage failures, and quit draining.
- `python3 scripts/calendar-fetch-smoke.py`: transport/resource limits, cancellation, and actual 60-second trickle deadline.
- `python3 scripts/feed-workload-smoke.py`: large feeds, deterministic budgets, cache preservation and recovery across processes. The 40-series fixture returned all 571 meetings in about 2.5 seconds; exhausted-feed checks took about 5.6 seconds in this harness.
- `./scripts/update-smoke.sh --app outputs/now.app`: all 13 local signed updater scenarios, including signature rejection, health acknowledgement, rollback and stale environment cleanup.
- `./release.sh 2.0.0 --dry-run`: clean synchronized main, signing and release prerequisites passed; no publication performed.

Loopback tests initially could not bind under the sandbox; they were rerun successfully with the required access. Updater smoke temporarily stopped the running app and reopened it through the script's cleanup. Logs are saved alongside this report.

## Remaining release decisions and checks

1. **Make the new regression suites release gates.** `release.sh:246` runs selftest, and line 253 runs updater smoke. Notification lifecycle, onboarding, cache restart and reminder-state smoke tests are currently outside the mandatory pipeline. No `.github` workflow directory exists in this checkout. Add a single preflight command or an explicit release checklist covering these suites.

2. **Test real macOS integration on supported OS versions.** This review ran on macOS 26.6.2 only. The binary advertises macOS 13+, and meeting detection has a separate availability boundary. Before shipping, verify fresh install and upgrade on the oldest supported version and the newer permission path. The automated notification suites use fake transport and stub native calendar fetching; they do not establish actual banner/action behavior or EventKit permissions on those systems.

3. **Run a real v1 → v2 upgrade acceptance test.** The updater smoke forges a newer version from today's binary. Also test a previously released v1 installation with real saved preferences: Calendar permission survives, existing reminder/suppression choices remain, first-run setup stays hidden, feature guidance appears as intended, and handled/snoozed reminders remain correct. Do this in an isolated account or test machine.

4. **Finish notification/fullscreen manual acceptance.** Check actual notification Join/Snooze/click/dismiss, cold launch, permission denial and recovery, Focus and screen sharing, and sleep/wake. Check fullscreen on multiple monitors/Spaces, keyboard navigation and VoiceOver. These are remaining integration checks, not failures found by this review.

5. **Decide the v2 distribution promise.** Current output is arm64-only and signed with the existing self-signed identity, without notarization, as documented in README. Make Apple Silicon/macOS requirements obvious in the Download section. If signing identity changes for distribution, coordinate updater certificate pins and Calendar-permission continuity before switching; do not change it casually at release time.

6. **Refresh release-facing material.** The README introduction still describes fullscreen as the sole behavior; the notification feature is described farther down. Bring the v2 overview and screenshots into line with the shipped setup/settings. The README also has an unmatched `</details>`. These are polish items, not blockers.

## Reproducing the additional probes

From the repository root:

```sh
swiftc -module-cache-path /tmp/now-v2-probe-modules Sources/ICS.swift outputs/v2-review/now-v2-review-probe.swift -o /tmp/now-v2-review-probe
/tmp/now-v2-review-probe outputs/v2-review/now-v2-collision.ics
/tmp/now-v2-review-probe outputs/v2-review/now-v2-empty-override.ics
```

The probe clock is fixed at September 9, 2026, so the fixtures stay reproducible. The collision fixture was additionally confirmed through the built app's production `--parse` command during this review.

This is a broad review and automated verification pass, not exhaustive proof of correctness. No fresh real-calendar grants or real notification deliveries were exercised.

## Verification of the other agent's remaining findings

Checked against the same commit on 2026-09-09. “Confirmed” below distinguishes observed behavior from whether we should change that behavior.

| Supplied finding | Result and disposition |
| --- | --- |
| Settings opens on each launch without sources | **Behavior confirmed, claimed regression rejected.** `Sources/App.swift:116` includes this branch, but identical source-less behavior is present in the actual `v1.9.0` and `v1.10.0` tags. It also triggers if native calendars exist but none is enabled. **Decision implemented:** completed profiles now launch quietly; unfinished new-profile setup remains resumable, and completing it opens Settings. |
| No Skip This Version | **Confirmed product gap.** `skippedUpdateVersion` is decoded and honored, but no production UI writes it. `Sources/MenuBar.swift:321` replaces Check for Updates while an update is known. **Decision implemented:** Skip This Version now persists the choice, removes the offer and staging, and leaves manual checks available. “Permanently” is too strong: the offer can change or be withdrawn on later checks. |
| Stacked meetings create separate notifications | **Confirmed, currently intentional.** `Sources/AppStore.swift:1079` offers each ordinary notification separately; catch-up and fullscreen collect groups. AGENTS.md explicitly states ordinary notifications stay separate. Decide whether v2 retains that policy; macOS ultimately controls banner presentation/grouping. |
| Manual ZIP upgraders miss the feature guide | **Confirmed in the initial audit; now fixed by the approved manual-upgrade discovery change below.** Without the updater marker, ordinary startup recorded guide IDs but returned no guides (`Sources/FeatureGuides.swift:40`, `Sources/Updater.swift:1051`). This is distinct from losing a deferred guide after an automatic upgrade. Consider recording the last running version or a discoverable What's New surface if manual-upgrade discovery matters. |
| No downgrade channel | **Confirmed design constraint.** `UpdateLogic.decide` accepts only versions newer than the running version. Removing v2 or publishing a v1 hotfix cannot downgrade existing v2 installs. Recovery code must ship under a higher version (2.0.1 is the next patch after 2.0.0), or users must manually replace the app. This is separate from the helper's automatic rollback of a failed installation. |
| Dead setup notifySyncErrors assignment | **Confirmed harmless dead path.** `SetupAssistantState.withoutNotifications` clears the draft flag, but `applying` never copies it. Sync notifications are not exposed in initial setup, new profiles default false, and existing profiles bypass setup. Remove the misleading assignment/comment or document the intended scope; no active user-visible bug shown. |
| Stale Launch-at-Login checkmark in an open menu | **Confirmed by code inspection.** Rendering uses `loginItemState` (`Sources/MenuBar.swift:337`), but `menuStructureSignature` (`:229`) omits it and the incremental refresh updates event rows only. A state change while tracking can remain stale until another structural change or reopening. Add the state to the signature and cover with the menu smoke harness. |
| DTEND before DTSTART gets a different timezone | **Confirmed with a narrower trigger.** With process TZ=UTC, a Berlin DTSTART and timezone-less DTEND produce a one-hour event when DTSTART is first and a three-hour event when DTEND is first. Explicitly zoned/UTC DTEND values are not affected. The parser consumes DTEND immediately with whatever DTSTART zone is known (`Sources/ICS.swift:489`). Resolve raw dates independently of property order and decide the floating-time policy explicitly; do not blindly inherit DTSTART's zone. |
| Date-only EXDATE/RDATE silently no-op on timed events | **Partly wrong; reproduced behavior is more specific.** A date-only EXDATE becomes midnight UTC and does not exclude a 10:00 occurrence; date-only RDATE adds an extra midnight UTC meeting. Both have no warning in the probe (`Sources/ICS.swift:582`, `:1416`). Treat as recurrence value-type/diagnostic hardening; define supported semantics or warn/reject rather than assuming a date means “the master's time” or “the whole day.” |
| Failed cache save deletes the last good copy | **Confirmed intentional resilience tradeoff.** `Sources/CalendarEventCache.swift:151` removes the old snapshot for every save error, including I/O errors, to prevent stale data surviving a successful newer feed. It reports the problem and preserves live events. Retaining the old copy could improve offline resilience but can resurrect cancelled/changed meetings; do not change this without deciding how stale data and successful-empty results are represented. No new transient-I/O fault injection was run. |
| Legacy fingerprint misses a location-only edit | **Confirmed migration blind spot.** The legacy hash omitted location; `Sources/AppStore.swift:1190` accepts a matching legacy hash and upgrades it to the current one without an update notice. This affects the first reconciliation of an old-format receipt; subsequent edits are detected. Live actions resolve current data, and old banners did not display location. Low impact; no historical location exists from which to reconstruct the change. |
| Two duplicate-key dictionary crash paths | **Underlying hardening issue confirmed; “two” is not a reliable count.** Persisted source arrays accept duplicate IDs (`Sources/Models.swift:237`), while native recoloring (`Sources/AppStore.swift:539`), ICS merge (`:630`), URL reconciliation (`:1033`) and launch catch-up (`:1094`) assume uniqueness. Duplicate persisted IDs can trap. Normal UI creation uses new UUIDs; no ordinary-user path producing duplicates was found. Normalize/deduplicate source IDs at decode. Do not replace every unique-key initializer indiscriminately: event arrays are normally normalized, and restored receipt keys already have uniqueness checks. |
| Cmd-Escape closes fullscreen | **Confirmed by the exact key classifier probe.** Key code 53 closes regardless of modifiers (`Sources/AlertUI.swift:345`). Classify as a keyboard-policy decision; change if only plain Escape should dismiss. |
| Numpad digits cannot join cards | **Confirmed by the exact key classifier probe.** `.numericPad` remains in the modifier set, so keypad “1” bypasses the plain-digit join branch (`Sources/AlertUI.swift:338`). Normalize non-command keypad metadata for numeric shortcuts while retaining real modifier guards. The same mask warrants checking keypad Enter. No physical external-keyboard test was run. |
| AGENTS.md references deleted plans | **Confirmed hygiene issue.** The three `docs/plans` references remain at lines 96, 116 and 141, but the files are absent. Update references to maintained documentation. |
| Release headers/build 77/changelog prepend | **Headers and prepend confirmed; build 77 rejected.** `release.sh:147` derives build from commit count + 1. At this commit that is **87**, confirmed by the earlier dry run; it will change as work is committed. Categorized `###` headers are already enforced. |
| README screenshots may predate v2 | **Unverified freshness claim; retained as a visual review task.** Current README does not demonstrate the new setup/notification UI. No side-by-side screenshot audit was performed. |
| Everything else audited clean | **Not adopted as a blanket guarantee.** Existing tests passing remains useful evidence, with the limitations recorded above; neither review establishes exhaustive correctness. |

For the timezone finding, RFC 5545 defines timezone-less DATE-TIME values as floating; inheriting another property's TZID is not the general rule. This is why the fix must settle semantics as well as ordering. [RFC 5545 §3.2.19](https://www.rfc-editor.org/rfc/rfc5545.html#section-3.2.19).

### Follow-up evidence

`python3 outputs/v2-review/verify-additional.py` compiles unchanged extracted AppSettings, FeatureGuideState and alert-key classification code, plus the unchanged production ICS parser/builder, with minimal dependency stubs. It uses a fixed clock and a UTC process timezone. Results are saved in `additional-probe.log` alongside generated `additional-probe.swift`. It reproduces scalar-decode rejection, lost pending guide history, keyboard classification, DTEND ordering, and date-only recurrence behavior. It does not construct AppStore, access real calendars, or submit notifications.

This follow-up changed only review artifacts. The earlier full build/smoke results still apply to the unchanged application sources; no full-suite rerun was necessary for the document update.

## Work order and current disposition

1. **Implemented:** warm-refresh notification action latency, with real Join dispatch interception, body-click, cold-start and Snooze regressions.
2. **Implemented:** recurrence occurrence identity, safe legacy migration, explicitly cleared fields, DTEND ordering and recurrence value-type diagnostics.
3. **Implemented:** durable never-shown feature guides and missing-staging/timeout recovery, including safe cancellation of a delayed quit.
4. **Implemented:** scalar settings/source-ID decoding, live login checkmarks, keypad digits/Enter, and removal of the dead setup assignment.
5. **Needs product input:** notification grouping, cache failure policy and modified Escape behavior. Preserve the current behavior until decided.
6. **Release gates and documentation implemented.** Real v1-to-v2/OS integration acceptance checks and screenshot review remain outstanding. The legacy location-only fingerprint blind spot remains a migration limitation, not a reconstructable edit history.


## Final implementation verification — passed

`./scripts/preflight.sh` exited **0** on the final working tree. The complete output is saved in `final-preflight.log` in this directory. It rebuilt and verified the app with the stable signing identity, then passed selftest, notification/lifecycle smoke, all three setup startup cases, reminder/menu/quit smoke, real cache process restarts, fetch cancellation/limits and the real 60-second deadline, workload tests across processes, and all 13 signed updater scenarios. `git diff --check` and shell syntax checks also passed. A pre-existing weak-variable warning in the reminder smoke harness is non-fatal; the app build had no reported warnings.

New regression coverage lives in `Sources/SelfTestReadiness.swift`, `scripts/notification-lifecycle-smoke.swift`, `scripts/notification-smoke.swift` and `scripts/reminder-state-smoke.swift`. It covers:

- Join and body clicks while a warm full refresh is still outstanding, intercepting URL opening without launching a real meeting; cold callbacks retain initial-load deferral.
- Two same-time recurring siblings, either feed order, distinct agenda/notification identities, and original-anchor override matching with exclusions.
- Explicitly empty versus omitted title/location/notes, including removal of a Join URL sourced from cleared notes.
- Legacy snooze migration, refusal to assign ambiguous legacy acknowledgements (even after a sibling disappears), and migration of old recurring notification receipts without a false update banner.
- DTEND property ordering and warnings for unsupported DATE-valued EXDATE/RDATE on timed meetings.
- Malformed scalar settings without unrelated resets, and duplicate source UUIDs across ICS/native arrays.
- Pending guide persistence across restart, consumption only on visible presentation, and preserving an active error window.
- Missing staging recovery, an actual helper poll timeout, clearing the durable install marker, cancellation callback delivery, and rejecting stale quit/helper completions.
- Keypad digits/Enter with real modifier guards, and the login checkmark changing in an already open menu.

At that verification checkpoint the changes were local and uncommitted. Info.plist remained version 1.10.0; no tag, push or release had been performed. Current macOS notification banners, real EventKit grants, older supported OS versions, multi-monitor accessibility and a released-v1-to-v2 user-profile upgrade remain manual acceptance checks. The product decisions above were deliberately left unchanged.

## Product decision: quiet launches after setup

Approved: automatically open Settings only when the initial setup wizard completes. `AppDelegate` now automatically presents only pending setup at launch; existing source-less profiles stay quiet. Explicit Settings and Finder reopen remain available, and unfinished setup remains resumable. The startup smoke assertions now require quiet existing/legacy profiles and retain the fresh-wizard completion-to-Settings check.

Verification passed: stable-identity signed build, all selftests, and all three isolated AppKit startup scenarios (fresh setup, existing empty profile, legacy empty profile). The first sandboxed GUI attempt aborted; the normal-desktop rerun passed. `git diff --check` passed.

## Product decision: Skip This Version

Approved and implemented: the available-update window offers Skip This Version. It persists the version, clears the current offer/staging, reconciles update notifications and closes the window. Automatic checks honor the skip; manual checks bypass it without clearing the preference. A newer version is still offered. Delayed staging completion also respects skipped-version popup suppression.

Verification passed on the finalized sources: stable-identity signed build, all selftests, notification/lifecycle smoke (including persisted skip, cleared offer/staging/receipts, manual reopening with skip retained, and a newer release remaining eligible), and `git diff --check`. README documents the behavior. No release was published.

## Product decision: manual ZIP upgrade guides

Approved and implemented: after successful startup health acknowledgement, existing current/legacy profiles discover catalog IDs they have not encountered, independent of updater markers. Fresh profiles use initial setup and silently record the current catalog. Manual upgrades show What’s New without claiming signature verification or a successful updater installation. Pending guides survive deferred presentation/restart; visible guides do not repeat.

## Final pre-commit verification

The complete `./scripts/preflight.sh` passed after the approved quiet-launch, Skip This Version and manual-ZIP guide changes: signed build, all selftests, notification/lifecycle tests, fresh/existing/legacy GUI startup, reminder/menu/quit tests, cache and transport tests, workload checks, and all 13 signed updater scenarios. The existing and legacy GUI scenarios explicitly verify What’s New without an install marker. Local full output: `outputs/v2-review/manual-upgrade-preflight.log`. Shell syntax and `git diff --check` passed. These readiness changes are committed together; the app remains 1.10.0 and no release/tag is created.

## Product decision: faster release discovery

Automatic checks now run every six hours, with the same minimum interval on launch/wake and after failures. Newly published releases are eligible immediately. Update notifications inform on discovery when enabled; otherwise the prepared update window waits 18 hours from first discovery and still defers for reminders. Manual checks remain immediate, and Skip This Version remains respected.

Timing verification passed: stable-identity signed build, all selftests (six-hour throttling, immediate release eligibility, 24-hour escalation boundary and once-only behavior), notification/lifecycle smoke, all three isolated startup GUI cases, and `git diff --check`. A local minute timer checks eligibility without network traffic; only the six-hour throttle permits automatic GitHub requests.

Timing refinement: the fallback window delay is now 18 hours from discovery, allowing for up to six hours before discovery. The six-hour API cadence is unchanged. Sleep, network failure, preparation and reminder-window deferral can extend actual presentation time.

18-hour refinement verification: stable-identity signed build, all selftests (including the exact 18-hour boundary and once-only suppression), and `git diff --check` passed.
