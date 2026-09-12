# Current work target: cross-platform groundwork via core extraction

Status: shared calendar/cache/reminder policy and POSIX storage are implemented and Linux-validated.
Native integration, macOS acceptance and platform shell decisions remain before merge/release or a
shipping port.

Branch: `feat/cross-platform-core`. Starting point: build/test modernization merged through PR #16,
merge commit `d01dbd786159bc63b088dfc1254c880d088eccd9`.

## Objective and sequence

Prepare _now_ for Windows and Linux by extracting shared Swift logic incrementally while preserving
the native macOS experience, Swift 5 language mode, macOS 13 / Apple Silicon support, bundle
identity, and release pipeline. A macOS library build alone does not demonstrate portability.

The sequence is: small shared core → headless Linux checks → expand models and reminder policy →
targeted `AppStore` responsibility extraction → platform shell experiments. Linux validation happens
before a broad controller refactor. Windows gets its own toolchain and integration checks before any
Windows support claim; passing Linux does not establish Windows compatibility.

Read `AGENTS.md`, the AutoWiki topic pages, and engineering notes before changing a subsystem. Small
behavior-preserving file splits, target restructuring, dependency injection at platform seams, and
access-control changes required by those seams are authorized. No release, merge, Swift 6 migration,
behavioral redesign, or weakening of regression safeguards is authorized.

## Boundary inventory and decisions

The pre-extraction package has 21 application source files and allow-listed `NowHarness` runners.
The table inventories that starting layout; completed slices and current evidence are recorded
below. Framework absence is insufficient evidence of portability: inspect referenced types and
Foundation APIs as well as imports.

| Existing source                                                                                                                                 | Boundary decision                                                                                                                                                                                                                                    |
| ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ICS.swift`                                                                                                                                     | Parser, parsed values, recurrence expansion and link classification/selection belong in core. `NSDataDetector` text discovery is an Apple Foundation adapter; feed-to-`MeetingEvent` materialization still depends on shell models/colors.           |
| `TitleFilter.swift`                                                                                                                             | Rules and prepared string matching are candidates; calendar mapping depends on the current app models. Move together with models in a later slice.                                                                                                   |
| `Models.swift`                                                                                                                                  | Mixed: native color properties and `Palette` defaults, `AppStore.soundNames`, preference recovery, native selections and persisted schema. Split deliberately; preserve macOS default colors, sound validation, coding keys and migration semantics. |
| `Helpers.swift`                                                                                                                                 | AppKit palette/image/activation code stays in shell. Formatting helpers need individual API and locale review, including `RelativeDateTimeFormatter`.                                                                                                |
| `MeetingActivity.swift`                                                                                                                         | CoreAudio probe, process metadata, bundle-ID classifiers and polling stay in shell. Activity values and debouncing are later core candidates.                                                                                                        |
| `CalendarEventCache.swift`                                                                                                                      | Snapshot validation/coverage/fingerprints are later core candidates. Default directory uses Application Support and bundle identity; I/O uses POSIX permissions and rename. Path injection alone does not make Windows storage portable.             |
| `Preferences.swift`                                                                                                                             | Move tolerant decoding/recovery rules only with their model consumers. Combine/OSLog status and live preference-domain selection stay in shell.                                                                                                      |
| `Notifications.swift`                                                                                                                           | Routing, occurrence hashing, `ReminderLedger`, catch-up and omission rules are later core candidates. Native transport, permissions, live receipts and UI integration stay in shell initially.                                                       |
| `AppStore.swift`                                                                                                                                | Keep the controller and `commitEvents` ordering. Later delegate existing pure due-reminder, unmute, normalization, source-generation and bookkeeping decisions to core. Do not duplicate them.                                                       |
| `AlertUI.swift`                                                                                                                                 | Later move pure snooze eligibility/scheduling. Panel focus, keyboard handling and preview presentation stay in shell.                                                                                                                                |
| `App.swift`, `MenuBar.swift`, `NativeCalendars.swift`                                                                                           | AppKit lifecycle, menus, EventKit and source mapping stay in shell.                                                                                                                                                                                  |
| `CalendarSettingsUI.swift`, `SettingsUI.swift`, `NotificationSettingsUI.swift`, `SetupAssistant.swift`, `FeatureGuides.swift`, `UpdateUI.swift` | UI/controllers remain shell-owned; setup/feature persistence is not redesigned in this slice.                                                                                                                                                        |
| `Updater.swift`, `UpdateDownload.swift`                                                                                                         | Keep unchanged except imports/build integration forced by the boundary; Foundation-only networking is not automatically core scope.                                                                                                                  |

Use one `NowCore` SwiftPM library target under `Sources/NowCore`, consumed by `NowApp` and all
existing harnesses. Keep shell files directly under `Sources` for this first slice. Exclude the core
directory from shell source discovery so it is never compiled into a second production module. Use
`package` access for necessary same-package consumers, retaining implementation-only members as
internal/private. No external public API or separate package is needed yet. Record widened surfaces
with their consumers; do not expose internals merely to make a future port easier.

Rejected for now: multiple feature modules, a separate package, blanket `public` access, replacing
the macOS UI, and a general platform-service abstraction without a concrete consumer.

## Slice 1: shared parser groundwork

- [x] Extract parsed values, ICS parsing, recurrence expansion and link policy into `NowCore`
      without changing algorithms or output. Inject text URL discovery; macOS keeps
      `NSDataDetector`.
- [x] Keep `ICSBuilder` materialization and existing application models in the shell until the
      color/default-decoding boundary is resolved. This slice is not the complete reminder core.
- [x] Make the app and every macOS harness consume the same `NowCore` target. Preserve entrypoints,
      fixture isolation, signing and bundle assembly.
- [x] Add an allow-listed core-only executable runner that imports the library without compiling
      AppKit, EventKit, UI, network transports or updater code. No live preferences or calendars.
- [x] Make analysis compile/check core and consumers as separate modules with package access;
      recursive file discovery followed by a flattened typecheck is not sufficient.
- [x] Relocate individual lint baseline entries and retain their rationales. Extend analysis smoke
      to detect new core and shell findings and broken cross-module access. Never regenerate debt.
- [x] Keep historical parser comparison usable across the file split, comparing an explicitly pinned
      pre-extraction revision against current full materialization output.
- [x] Update development instructions and affected AutoWiki architecture pages.
- [x] Run available groundwork checks, document unavailable macOS gates, then commit and push as
      requested. A pushed branch is not a verified macOS release or permission to merge.

## Early headless Linux gate

- [x] Install an official Swift Linux toolchain and system dependencies in the devbox; record
      compiler/OS/architecture and reproducible commands. Keep toolchain artifacts ignored or
      outside the repository. Do not use the macOS `xcrun`/arm64 wrapper for Linux.
- [x] Build and run the core-only target in debug and release, in Swift 5 mode, with complete strict
      concurrency checking. Compiler warnings are failures; no unsafe annotations to silence them.
- [x] Exercise complete/truncated envelopes, CRLF/folding, parser limits, timezone mapping, DST gaps
      and overlaps, exact recurrence budget boundaries, raw override identities and link policy with
      synthetic input and explicit clocks/zones. Compare expected results rather than timing claims.
- [x] Record unsupported APIs or platform differences as findings, fix only justified seams, and
      document the actual boundary proven. Native text URL detection and full feed materialization
      are not established by this runner.

## Subsequent slices after the early gate

- [x] Extract plain application models, filters and decoding policy after resolving native color and
      sound defaults without changing persisted output or recovery behavior on macOS.
- [x] Choose a maintained portable SHA-256 strategy (for example Swift Crypto) before moving cache
      and reminder keys. Preserve exact bytes, lowercase hex encoding, identity prefixes and legacy
      aliases; test against known saved-state fixtures. Never substitute Swift `Hasher`.
- [x] Move cache snapshot/coverage/recovery decisions and the serial POSIX adapter with required
      directory injection. Linux permission, replacement, quarantine and restart cases pass.
- [ ] Verify the moved POSIX adapter and failed-empty-save behavior on macOS via the existing signed
      cache/notification regression suites. Windows storage remains a separate unimplemented
      adapter.
- [x] Move `NotificationLogic` routing/identity, `ReminderLedger`, catch-up/omission tracking,
      `AppStore` pure reminder eligibility/unmute/bookkeeping helpers, and `AlertController` pure
      snooze scheduling. Controllers delegate to one implementation; no broad orchestration rewrite.
- [x] Extend the core-only runner with model recovery, filtering, identities, ledger retention,
      receipt-owned rescheduling and cache policy fixtures as those rules become available.
- [x] Evaluate further `AppStore` extraction: materialization and source-generation/merge decisions
      now have shared owners. Keep live `commitEvents`, timers, preferences and accepted receipt
      submission/replacement ownership together until macOS lifecycle validation is available.

## macOS validation and acceptance

Run the commands in `AGENTS.md`: signed build and selftest after changes; analysis and analysis
smoke after Swift/tooling changes. On the signing Mac, build outside the agent sandbox for keychain
access. The Linux devbox cannot replace signing, AppKit, EventKit, notification, or GUI validation.

Before accepting the extraction on macOS:

- [ ] Signed release/debug builds and debug/optimized selftests pass.
- [ ] All notification/startup/focus, reminder, cache, fetch, workload, parser and updater suites
      pass, including a parser digest comparison to the pinned pre-extraction revision.
- [ ] Analysis and its failure probes pass across core, shipping, selftest and updater
      configurations; inspect `--report` for relocated flagged functions.
- [ ] GUI launch/liveness and permission-prompt behavior are unchanged; signed updater smoke passes
      against the pinned identity.
- [ ] Record artifact sizes/build timings as observations only.
- [x] Run `npm ci`, `npm run format-docs`, and `npm run check-docs` after Markdown edits.

Keep selftests deterministic and EventKit-free: never construct `AppStore` or another
`EKEventStore`. Use disposable domains, fake transports and synthetic feeds. Never seed the
installed app's data.

## Product and shell decisions before a port

Proposed first-port scope: ICS feeds, agenda/tray, reminders, Join/Snooze and offline recovery.
Decide the first shipping OS and whether native calendar accounts and meeting detection are required
before selecting a UI framework. These are proposed requirements, not promised parity.

Prototype background reminder visibility/focus, notification actions after cold restart, tray/menu
support, wake/catch-up and autostart on the actual target desktops (including relevant Linux desktop
environments). Packaging/update trust needs a per-platform design. SwiftCrossUI or another toolkit
is chosen after these probes, not assumed by the core extraction. No UI dependency or production
Windows/Linux shell is added in this stage.

## Handoff

Implementation and validation evidence will be recorded here as work proceeds. Commit and push are
authorized by the current request; no merge or release is authorized.

### Groundwork checkpoint

The first slice adds `NowCore`, the core-only runner and module-aware compiler gates. macOS
`ICSBuilder` remains in its original file with its materialization body unchanged; Apple text URL
discovery delegates to the core's existing selection policy. Package visibility changes and seven
relocated lint entries are itemized in `analysis/review.md`.

Before the initial Linux run: pinned npm install, Markdown format/check, Python syntax compilation,
shell syntax check for `test-core.sh`, and `git diff --check` passed. The required signed build,
selftest, analysis report and full analysis smoke were attempted but cannot start on this Debian 12
x86_64 devbox (initially no zsh or Swift; no macOS SDK, AppKit, GUI or signing keychain). No macOS
build, runtime equivalence or lint pass is claimed. Core compilation/execution follows the requested
groundwork commit/push checkpoint.

### First Linux results

Groundwork commit `686b3e9` was pushed to `origin/feat/cross-platform-core` before these runs.

- Host: Debian GNU/Linux 12, x86_64; glibc `2.36-9+deb12u14`, system ICU `72.1-3+deb12u1`, tzdata
  `2026b-0+deb12u1`.
- Compiler: official Swift `6.3.3` (`swift-6.3.3-RELEASE`, Ubuntu 22.04 x86_64 distribution),
  reporting target `x86_64-unknown-linux-gnu`, compiling this package in Swift 5 mode. This records
  the tested Debian/Ubuntu-toolchain combination, not general distribution support.
- Toolchain detached signature verified against Swift's official keys; signing fingerprint
  `52BB7E3DE28A71BE22EC05FFEF80A866B47A981F`. Installed outside the repository at
  `/opt/swift-6.3.3-RELEASE-ubuntu22.04`; `swift` and `swiftc` are available via `/usr/local/bin`.
- `./scripts/test-core.sh`: passed all 53 checks, with complete strict concurrency and warnings as
  errors. `NOW_TEST_CONFIGURATION=release ./scripts/test-core.sh`: also passed all 53.
- `python3 scripts/analysis-smoke.py --compiler-only`: all 12 probes passed, including core/shell
  warning rejection, inaccessible core API rejection, fixture discovery, baseline line shifts and
  report-mode compiler failures.
- `swift package describe --type json` was checked for shipping, core, selftest, notification,
  reminder, cache, fetch, workload, parser and updater selections. All ten have exactly one core
  target/dependency and no core source in their consumer target; the core runner contains only its
  own fixture. No manifest warnings were emitted.
- No Linux-specific algorithm fix, unsafe concurrency annotation or baseline relaxation was needed.
  Apple's text detector remains an explicit adapter; full `ICSBuilder` output, app models,
  notifications and disk recovery are still outside the proven Linux boundary.
- With zsh installed, required macOS checks were attempted again: the signed build stops at missing
  `xcrun`; the selftest wrapper also needs `xcrun` and the Apple arm64 toolchain; analysis stops at
  missing pinned SwiftLint. macOS SDK/GUI/signing, full lint smoke, and historical materialization
  digest comparison remain unverified. Installing Linux tools cannot provide those gates.

### Models/filtering slice

Implemented shared `CalendarSubscription`, `AppSettings`, `NativeCalendar`, `Persisted`,
`MeetingEvent`, title filtering and the existing tolerant decoding/audit helpers. Native calendar
IDs and sound identifiers are retained as opaque/compatibility data rather than renamed or migrated.
`Sources/Models.swift` keeps native color properties and the existing convenience initializer APIs.

`AppModelCoding.decoder()` supplies the current macOS palette through a per-decoder `@Sendable`
callback; `StoredPreferences` and macOS profile/subscription fixtures use it. Missing/null colors
retain their legacy defaulting behavior; explicit empty and saved colors are preserved. Core callers
provide explicit constructor colors and can configure their own decoder palette. An unconfigured
core decoder leaves the color unresolved (`""`) rather than inventing platform colors. No mutable
global palette is added. The live persistence/backup/recovery controller remains in the shell.

Verification on the recorded Swift 6.3.3/Linux host:

- `./scripts/test-core.sh` and `NOW_TEST_CONFIGURATION=release ./scripts/test-core.sh`: all 107
  checks passed, including 54 new model/filter checks. Complete strict concurrency and
  warnings-as-errors remain enabled.
- New checks cover exact saved-profile fields/values, all existing sound choices and fallback,
  extreme timing inputs, partial recovery, duplicate source UUIDs, decoder-local recovery/color
  policy, exact/regex filtering, and reschedule/coincident occurrence identities.
- Portable analysis compiler smoke: all 12 probes passed. SwiftPM source isolation and a syntax-only
  parse passed for all ten shipping/harness configurations, including discovery of the new fixtures.
  Syntax parsing is not a macOS typecheck or runtime test.
- Added macOS adapter fixtures for native palette defaulting and optional/explicit colors, plus a
  live preference-recovery assertion. Signed build, macOS selftest and notification/recovery smoke
  were attempted but are blocked by the unavailable Apple SDK/toolchain; analysis is blocked by
  unavailable pinned SwiftLint. These gates remain open.
- Visibility and concurrency ownership changes are recorded in `analysis/review.md`. No baseline
  entries were added, removed or relaxed in this slice.

### Calendar/cache/reminder policy slice

Implemented focused owners under `Sources/NowCore`:

- `Calendar/`: materialization with injected color/link adapters, cache snapshot validation and
  coverage, request generations and source merge. The macOS builder/merge overloads preserve native
  palette and `NSDataDetector` behavior while delegating one algorithm.
- `Reminders/`: stable occurrence identity/fingerprints, routing/grouping, ledger reconciliation,
  source-owned omission/catch-up/sync episodes, due/Join eligibility, unmute/pruning and snooze
  rules. Existing controller methods delegate; no duplicate policy implementation or replacement
  live store.
- `Activity/`: activity values and debouncing; CoreAudio probing/classification stays native.
- `Storage/`: existing serial POSIX disk adapter for macOS/Linux, with explicit directory injection.
  Default application paths stay in the macOS extension. Windows filesystem support is not supplied.
- `Support/`: SHA-256, using CryptoKit on macOS and pinned Swift Crypto 4.5.2 on Linux/Windows.
  `Package.resolved` deliberately pins Swift ASN.1 1.7.2 transitively. Dependency manifests require
  compiler 6.1+; root manifest/package APIs and app/core language mode remain Swift 5 compatible.

Validation on the previously recorded Swift 6.3.3/Debian 12 host:

- Debug and release core runners each pass **217 checks**, with strict concurrency and warnings as
  errors. Known SHA-256 vectors and independently calculated cache/current/legacy reminder hashes
  verify exact existing key bytes. A resource-limit fixture was corrected to actually exceed the
  unchanged recurrence budget; no production limit or algorithm was weakened.
- Real subprocesses write and reopen cache plus ledger, proving handled reminders remain handled
  across a process restart. Storage fixtures verify 0700/0600, corruption preservation/retirement,
  symlink rejection, queued removal, failed accepted-empty quarantine and no stale restoration.
- Materialization/merge fixtures cover coincident overrides, explicit-empty inheritance, RDATE/
  EXDATE, lazy link resolution, incomplete feeds/expansions, stale generations, URL edits, disable/
  invalidation and successful-source omission ownership. Reminder fixtures cover rescheduling,
  legacy alias ambiguity, receipt/snooze ownership, timing boundaries, suppression and safe snoozes.
- All 12 portable compiler-gate probes pass. The durable
  `python3 scripts/module-boundary-smoke.py --parse` passes all ten target configurations, verifies
  shared source ownership and syntax-parses consumer files without claiming an SDK typecheck.
- Required signed build/selftest, macOS analysis report and full analysis smoke were attempted and
  remain unavailable (no `xcrun`/`xcode-select`, macOS SDK or signing environment). The SDK wrapper
  now stops at failed discovery instead of accidentally starting a wrong-host build. Its syntax is
  checked. Core tests bound dependency build parallelism to four jobs, overridable via
  `NOW_BUILD_JOBS`.
- Pinned SwiftLint 0.65.1 strict mode passes, and an unfiltered report confirms the existing 16
  reviewed findings. Two materialization entries are relocated with exact signatures; its length
  decreases from 116 to 115 and the existing baseline reason records that measured reduction. Four
  portable lint probes pass via `python3 scripts/analysis-smoke.py --lint-only`. No threshold is
  relaxed or new exception accepted. New value types use checked `Sendable`; the cache retains its
  original serial-queue-protected unchecked conformance.

The official Linux linter archive was checksum-verified but cannot run on Debian 12's older glibc/
libstdc++. The unmodified SwiftLint 0.65.1 source tag was instead built with the installed compiler;
`.tools/swiftlint/swiftlint version` reports 0.65.1. Source/intermediate artifacts stay outside the
repo; only the executable is copied into ignored `.tools`. The installer now selects pinned platform
archives, preserving its original macOS path; incompatible runtime/version checks fail before
replacing an installed tool. No host libc was replaced.

### Next gates

The Foundation-only cache directory-selection extension and transport result type also pass host
typechecking against the actual built `NowCore` module with complete concurrency and warnings as
errors. This verifies the extracted cache API/convenience initializer boundary without pretending to
typecheck AppKit/EventKit code on Linux.

The Linux-verifiable shared-policy groundwork is complete for this plan. Before another live-state
ownership refactor or merge, run the macOS acceptance checklist, including old/new full parser
digests, cache recovery, notification lifecycle, focus/liveness and signed updater smoke. Those
tests guard platform ordering that a Linux-only model cannot prove.

After that, decide the first port's minimum feature set and run actual target-platform spikes:
native text URL discovery, tray/menu, background reminder focus, notification actions after restart,
wake/autostart and packaging/update trust. Windows needs its own toolchain and filesystem
validation. These remain explicit next-stage work, not a claimed shipping Linux/Windows app.
