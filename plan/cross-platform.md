# Cross-platform support: groundwork record and port roadmap

Status: the groundwork phase is complete and merged into `main` through PR #17, merge commit
`21a8452`. Shared calendar/cache/reminder policy and POSIX storage are implemented and validated on
Linux and macOS, and all macOS acceptance gates passed. No portability prerequisite blocks new macOS
features. This file is the anchor for resuming Windows/Linux port work later: the roadmap below
records what is already portable, which shell-owned gaps remain, and the agreed order of the next
steps. No port work is scheduled yet.

Completed branch: `feat/cross-platform-core`. Starting point: build/test modernization merged
through PR #16, merge commit `d01dbd786159bc63b088dfc1254c880d088eccd9`.

The implementation and validation notes below preserve the sequence and authorization at each
historical checkpoint. Their references to pending commits or merges describe that stage, not the
current repository state.

## Port roadmap: where to resume

### Portable baseline (already done)

Everything under `Sources/NowCore` compiles off the Apple SDK and is validated on the recorded Linux
host, in Swift 5 mode with complete strict concurrency:

- ICS parsing, recurrence expansion, meeting-link policy (`ICS.swift`, `Calendar/`), including the
  Windows/Outlook TZID → IANA mapping for feeds.
- Plain models, tolerant decoding/recovery, filtering (`Models.swift`, `PreferenceDecoding.swift`,
  `TitleFilter.swift`), with decoder-local color policy so native palettes stay injected.
- Cache snapshot policy and the serial POSIX storage adapter for macOS/Linux with directory
  injection (`Storage/CalendarEventCache.swift`).
- Reminder policy: occurrence identity, routing, ledger reconciliation, snooze, catch-up
  (`Reminders/`).
- SHA-256 identities via CryptoKit on macOS and pinned Swift Crypto 4.5.2 on Linux/Windows
  (`Support/StableDigest.swift`); the Windows dependency condition already exists in
  `Package.swift`.

Portable checks that any port branch must keep passing: `./scripts/test-core.sh` (debug and
release), `./scripts/test-headless.sh` (debug and release),
`python3 scripts/analysis-smoke.py --compiler-only`, and
`python3 scripts/module-boundary-smoke.py --parse`, in addition to the macOS gates in `AGENTS.md`.

### Shell-owned gaps without a portable equivalent

| Area                   | macOS owner today                                                                     | Needed for a port                                                                                                               |
| ---------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| App/UI shell           | AppKit/SwiftUI in `Sources/App.swift`, `MenuBar.swift`, `SettingsUI.swift`, …         | UI framework decision (e.g. SwiftCrossUI) after the probes below; tray/menu integration                                         |
| Calendar access        | EventKit in `Sources/NativeCalendars.swift`                                           | Native-account equivalent or an explicit ICS-only first port                                                                    |
| Notification transport | UserNotifications in `Sources/Notifications.swift`                                    | Native transport whose actions survive a cold restart                                                                           |
| Local storage          | POSIX adapter, `#if os(macOS) \|\| os(Linux)` in `Storage/CalendarEventCache.swift`   | A separate Windows filesystem adapter (atomic replacement, permissions, quarantine semantics); Linux already shares the adapter |
| Live preferences       | Combine/OSLog-backed store in `Sources/Preferences.swift`                             | Portable persistence with the same tolerant recovery rules (core decoding already exists)                                       |
| Autostart              | `SMAppService` seam in `Sources/AppStore.swift`                                       | Per-desktop autostart (Linux `~/.config/autostart`, Windows Registry run key, …)                                                |
| Meeting detection      | CoreAudio probe in `Sources/MeetingActivity.swift`                                    | Own probe or drop from first-port scope; debouncing policy is already core                                                      |
| Updates/signing        | Code-signing-based updater in `Sources/Updater.swift`, `Sources/UpdateDownload.swift` | Per-platform packaging and update-trust design                                                                                  |
| Text URL discovery     | `NSDataDetector` adapter in `Sources/ICS.swift`                                       | Portable detector or explicit-link-only parsing (selection policy is core)                                                      |
| Native colors          | macOS palette accessors in `Sources/Models.swift`                                     | Per-platform palette injection (decoder-local color policy already exists)                                                      |

### Resume sequence

1. Product decision first: target OS and minimum feature set (proposal: ICS feeds, agenda/tray,
   reminders, Join/Snooze, offline recovery) and whether native calendar accounts are required. This
   choice drives the UI framework and the calendar-access gap. The groundwork-era probes are
   itemized in “Product and shell decisions before a port” below. Decided 2026-09-19: Linux first,
   ICS-only, no meeting detection, plan baseline, Wayland-only, single system sound, AUR packaging —
   see "Product decision — 2026-09-19".
2. Target-platform probes before any UI-framework choice: background reminder visibility/focus,
   notification actions after cold restart, tray/menu support, wake/catch-up, and autostart on the
   actual target desktops (including the relevant Linux desktop environments). Hyprland done
   2026-09-20 in an Omarchy VM — see "Hyprland desktop probes — 2026-09-20"; GNOME and KDE remain.
3. Concrete first technical steps per platform:
   - Linux: a headless shell probe — a new executable target consuming only `NowCore` (ICS-only
     feeds, injected directories, file-based preferences) that runs the fetch → merge → reminder
     loop on a real desktop. This validates timers, wake behavior, and storage before any UI work.
     Started: the probe target exists and its deterministic selftest passes in a headless Debian 12
     container (see "Linux headless shell probe — 2026-09-19"); validation on a real desktop,
     including wake and autostart, remains.
   - Windows: toolchain setup and validation plus the filesystem storage adapter first — the
     documented gap. Passing Linux proves nothing for Windows; Windows gets its own gates.
4. Only then: shell/UI framework, packaging, and update trust per platform.

### Constraints that carry over

From `AGENTS.md`, unchanged by the groundwork merge: never compile core sources into a second
target; keep `package` access and Swift 5 language mode; keep the pinned Swift Crypto dependency
(Swift 6.1+ compiler); Linux validation does not replace macOS signing/GUI/EventKit gates; do not
claim Windows support without Windows toolchain and integration evidence.

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
- [x] Verify the moved POSIX adapter and failed-empty-save behavior on macOS via the existing signed
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

- [x] Signed release/debug builds and debug/optimized selftests pass.
- [x] All notification/startup/focus, reminder, cache, fetch, workload, parser and updater suites
      pass, including a parser digest comparison to the pinned pre-extraction revision.
- [x] Analysis and its failure probes pass across core, shipping, selftest and updater
      configurations; inspect `--report` for relocated flagged functions.
- [x] GUI launch/liveness and permission-prompt behavior are unchanged; signed updater smoke passes
      against the pinned identity.
- [x] Record artifact sizes/build timings as observations only.
- [x] Run `npm ci`, `npm run format-docs`, and `npm run check-docs` after Markdown edits.

Keep selftests deterministic and EventKit-free: never construct `AppStore` or another
`EKEventStore`. Use disposable domains, fake transports and synthetic feeds. Never seed the
installed app's data.

## Product and shell decisions before a port

Decided 2026-09-19 — see "Product decision — 2026-09-19" below for the record. The remaining open
item for this section is the UI framework, which is chosen only after the target-platform probes.

Prototype background reminder visibility/focus, notification actions after cold restart, tray/menu
support, wake/catch-up and autostart on the actual target desktops (including relevant Linux desktop
environments). Packaging/update trust needs a per-platform design. SwiftCrossUI or another toolkit
is chosen after these probes, not assumed by the core extraction. No UI dependency or production
Windows/Linux shell is added in this stage.

### Product decision — 2026-09-19

The first-port product decisions are settled; they drive the probe matrix and the eventual UI
framework choice, and they do not authorize shell work before the probes pass.

- First target OS: **Linux**. Windows keeps its separate toolchain/storage gate order and is not
  part of this port.
- Calendar sources: **ICS-only** (subscription feeds, as validated by `NowCore` and the headless
  probe). Native calendar accounts (Evolution Data Server/CalDAV) are a later slice, not a v1
  requirement.
- Meeting detection: **out of scope** for v1. In-meeting delivery modes degrade gracefully with
  activity `unknown` (verified in core policy); no PipeWire/PulseAudio process-audio probe is built
  for the first port.
- Minimum feature set: the plan baseline — ICS feeds, agenda in a tray, reminders delivered through
  native notifications, Join/Snooze notification actions, offline recovery, and autostart.
  Fullscreen-style reminder windows are not in v1; native notification delivery is the only reminder
  transport (the macOS fullscreen mode stays macOS-only until a port probe justifies more).
- Display server: **Wayland-only**. All target desktops default to Wayland; X11 support is not in
  v1.
- Reminder sound: one built-in sound played through the system audio server (PipeWire/Pulse
  compatible); no sound picker and no custom sounds in v1.
- Probe desktops: **GNOME, KDE, and Hyprland** — Omarchy, verified at omarchy.org on 2026-09-19, is
  Arch + Hyprland (Wayland) with Quickshell as its shell. All three differ materially in tray (GNOME
  extension vs KDE StatusNotifierItem vs Quickshell-hosted), so the tray probe must cover each.
- Packaging: **AUR first** (PKGBUILD), updated through pacman. No in-app updater on Linux; the
  update-check UI is suppressed there. Other formats (`.deb`, Flatpak) are not in v1 — Flatpak's
  portals would change the notification/autostart probe matrix.

Consequences for the next steps: the step-3 probes run on GNOME, KDE and Hyprland under Wayland
only, covering notification actions surviving cold restart, tray/menu support per desktop,
wake/catch-up, autostart via `~/.config/autostart`, and single-sound playback. Only after those
probes is a UI framework (e.g. SwiftCrossUI or a Qt/Quickshell-aligned alternative) chosen.

## Handoff

Groundwork and macOS acceptance are complete and merged. Continue macOS feature development with
shared policy in `NowCore` and native integration in the macOS shell, following the required checks
in `AGENTS.md`. Core changes also require debug/release core tests and module-boundary validation.
Windows toolchain/storage validation and Linux/Windows shell, notification, packaging and update
work remain future port tasks; they do not block macOS features. No release is part of this status
update.

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

The Linux-verifiable shared-policy groundwork is complete for this plan. The macOS acceptance
checklist was subsequently completed as recorded below, including old/new full parser digests, cache
recovery, notification lifecycle, focus/liveness and signed updater smoke. Future live-state
ownership refactors must retain the relevant checks: they guard platform ordering that a Linux-only
model cannot prove.

After that, decide the first port's minimum feature set and run actual target-platform spikes:
native text URL discovery, tray/menu, background reminder focus, notification actions after restart,
wake/autostart and packaging/update trust. Windows needs its own toolchain and filesystem
validation. These remain explicit next-stage work, not a claimed shipping Linux/Windows app.

### macOS acceptance results — 2026-09-13

Validated branch checkpoint `cbd9f89` plus the local fixes below on macOS 26.6.2 (25G83), Apple
Silicon, Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`), Swift 5 language mode and the arm64/macOS 13
build target. This host run does not establish runtime testing on macOS 13 or Windows compatibility.

Fixes required by actual macOS failures:

- `Sources/AppStore.swift`: qualify `NowCore.FetchRequest` to resolve the name collision with
  SwiftUI's imported `FetchRequest`. Request ownership and fetch behavior are unchanged.
- `Sources/NativeCalendars.swift`: compute the existing occurrence string and notification identity
  before the `MeetingEvent` initializer to avoid the compiler's expression-checking timeout.
  Identity bytes and EventKit mapping are unchanged.
- `scripts/analysis-smoke.py`: in standalone lint mode, discover the Command Line Tools SourceKit
  framework on macOS, matching the existing analyzer setup and preserving any existing framework
  search path. Linux behavior is unchanged. The initial clean-source probe crashed without this
  lookup; all four lint probes now pass.

Acceptance evidence:

| Gate                     | Commands and outcome                                                                                                                                                                                                                                                                                   |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Signed builds            | `./scripts/build-app.sh --require-identity` and `./scripts/build-app.sh --require-identity --debug`: pass; both bundles satisfy their designated requirement with the pinned identity. CryptoKit and native adapter code compile.                                                                      |
| Selftest                 | `./scripts/test.sh` and `NOW_TEST_CONFIGURATION=release ./scripts/test.sh`: pass, all suites green, including native model/color boundary fixtures.                                                                                                                                                    |
| Core parity              | `./scripts/test-core.sh` and `NOW_TEST_CONFIGURATION=release ./scripts/test-core.sh`: **217 checks each**, with strict concurrency and warnings as errors.                                                                                                                                             |
| Analysis                 | `./scripts/setup-analysis.sh`, `./scripts/analyze.sh`, and `./scripts/analyze.sh --report`: pass; five compiler configurations have zero warnings; the report contains exactly the 16 reviewed lint findings, including builder complexity 24 / length 115. No baseline or threshold changes.          |
| Failure probes           | `python3 scripts/analysis-smoke.py`: all 17 probes pass. `python3 scripts/analysis-smoke.py --lint-only`: all four probes pass after the SourceKit lookup fix.                                                                                                                                         |
| Module ownership         | `python3 scripts/module-boundary-smoke.py --parse`: all ten configurations pass.                                                                                                                                                                                                                       |
| Historical parser        | `python3 scripts/parser-performance-smoke.py --compare-revision d01dbd7`: pass; both full materialization digests match exactly.                                                                                                                                                                       |
| Notification and startup | `python3 scripts/notification-smoke.py --all-smokes`: pass, including recovery, lifecycle/races, fresh/existing/legacy startup, background key focus and restored accessory policy.                                                                                                                    |
| Reminder/menu            | `python3 scripts/reminder-state-smoke.py`: pass, including paused agenda, menu tracking, timer lifetime and quit/settings dialog checks.                                                                                                                                                               |
| Cache                    | `python3 scripts/calendar-cache-smoke.py`: pass across all twelve phases, including real restarts, accepted-empty recovery, failed replacement quarantine, private permissions and AppKit quit draining writes.                                                                                        |
| Transport/workload       | `python3 scripts/calendar-fetch-smoke.py` and `python3 scripts/feed-workload-smoke.py`: pass, including the real 60-second resource deadline, streaming limits/cancellation and deterministic cross-process diagnostics.                                                                               |
| Signed updater           | `./scripts/update-smoke.sh --app outputs/now.app`: pass, all thirteen scenarios plus post-staging signature/version rejection.                                                                                                                                                                         |
| GUI                      | Launched `outputs/now.app`; confirmed the release executable remains running, Settings responds, fullscreen preview opens/dismisses, and no permission prompt appeared during interaction. Quiet startup and native-menu/focus behavior are additionally verified by the isolated hosted suites above. |
| Documentation            | `npm ci`, `npm run format-docs`, and `npm run check-docs`: pass after this evidence update.                                                                                                                                                                                                            |

Observed artifacts: release executable **2,700,672 bytes**, release ZIP **2,043,602 bytes**, debug
executable **9,964,912 bytes**. The successful incremental SwiftPM release/debug build steps
reported **12.23 s / 4.57 s**, excluding icon generation, signing and ZIP assembly. These are host
observations, not performance guarantees or clean-build comparisons.

Historical and working parser digests:

- 7,000 long-description events: `560605def0f8c9ae7791aefaca660eacc830be53a7cec48b970b553ad21f9b94`.
- 5,000 coincident overrides: `3140f24598e0197abf36154a16a1a326eae74897b216e5f5f9205840274c032d`.

Observed historical/current fixture times were 6.264/6.990 s and 0.464/0.376 s respectively;
concurrent validation workloads make these unsuitable for a performance conclusion.

Signed builds and signed/loopback fixtures ran outside the agent sandbox as required. The portable
SwiftPM core/module commands also required unsandboxed execution because nested manifest sandboxing
and user caches were blocked; their unchanged commands passed there. An initial SDK mismatch message
was secondary to denied module-cache writes, not an incompatible compiler. GUI automation initially
timed out, then successfully attached to the running release bundle. Synthetic suites used
disposable data; no installed calendar or preference data was seeded. The GUI check used the
existing profile without editing its settings or calendars.

All requested macOS acceptance gates passed. At this validation checkpoint, changes were local on
the feature branch and no commit, push, PR, merge or release had been performed in that stage. The
fixes and acceptance record were subsequently committed as `80e932e` and merged through PR #17
(`21a8452`). Product/shell decisions above remain next steps when port development resumes.

### Linux headless shell probe — 2026-09-19

Implemented the resume sequence's first Linux technical step on the recorded Debian 12 x86_64 host
(Swift 6.3.3, Swift 5 mode, complete strict concurrency, warnings as errors), in a headless
container. New executable target `NowHeadless` (`Sources/Headless`, selected by
`NOW_TEST_SUITE=headless`, product `now-headless`) consumes only the `NowCore` library — the module
boundary smoke now covers eleven configurations — and owns, per the shell-owned gaps table:

- File-based preferences and reminder history (`preferences.json`, `ledger.json`) with atomic
  0700/0600 POSIX writes and the core tolerant-decoding/audit rules; core `Persisted`/`AppSettings`
  recovery is exercised verbatim (damaged fields snap back, siblings survive, corrupt ledger
  resets).
- ICS-only feeds through a bounded transport: `file://` for offline fixtures and `http(s)` via
  `URLSession` (5 MB cap mirroring the shell transport); a localhost HTTP feed fetch was exercised
  manually.
- A portable text URL discovery adapter (`PortableLinkDetector`): explicit http(s) token scanning
  with sentence-punctuation trimming, parenthesized links, and entity-decoded variants, feeding
  core's `LinkExtractor` selection policy. It is a deliberate first-port adapter; no
  `NSDataDetector` parity is claimed, and macOS keeps its native adapter.
- The fetch → merge → commit → tick loop mirroring `AppStore` ordering through core owners: fetch
  generations, `CalendarSnapshotMerge` (failed/stale feeds retain accepted snapshots; failures never
  become successful empty results), `commitEvents` reconciliation (handled-lead retention,
  reschedule re-arm for fullscreen, mute ratchet), cache snapshot save/restore with injected
  directories, launch catch-up boundary, and routing through `NotificationLogic`/`SnoozePolicy`.
  Delivery is a logged line — the native notification transport gap stays open.
- Join/Snooze/Pause agenda actions through `SnoozePolicy` and the shared ledger.

Validation on this host:

- `./scripts/test-headless.sh`: **51 checks** (debug and release), covering: portable link discovery
  and core selection integration; preferences/ledger round-trip, recovery and file permissions; feed
  materialization (window filtering, muted-by-filter, decoder-local palette); reminder lifecycle
  (lead firing, no refire, snooze quiet/expiry, join suppression, pause blocking with usable
  agenda); reschedule re-arm; failed-feed retention and disabled-calendar pruning; offline cache
  restore; real cross-process restarts (children re-run the binary against the same state directory:
  handled and snoozed state survives, catch-up delivery handled once, private file modes); and a
  bounded live one-second tick loop delivering a reminder in real time.
- Re-ran the portable gates after the target changes: core 251 checks (debug/release),
  `python3 scripts/analysis-smoke.py --compiler-only`, and
  `python3 scripts/module-boundary-smoke.py --parse` (now including `headless`) all pass. SwiftLint
  0.65.1 (focused rule set) reports 0 violations for the new files.
- macOS gates (signed build, selftest, full analysis, GUI) were not run here: no Apple SDK, keychain
  or desktop exists in this container. No tray/menu, native notification actions, wake-from-sleep or
  autostart behavior is validated — those remain real-desktop probes per the resume sequence. No
  Windows work is claimed.

### Hyprland desktop probes — 2026-09-20

First row of the probe matrix, run in an Omarchy VM (try-omarchy) on an Apple Silicon Mac: Arch
Linux ARM aarch64, kernel 7.2.6, Hyprland 0.56.1 (Wayland), Quickshell as the shell — it owns both
`org.freedesktop.Notifications` and `org.kde.StatusNotifierWatcher`; PipeWire 1.6.8 audio. Probe
scripts and state stayed in `~/now-probes/` outside the repo; nothing was committed from the VM.
macOS gates were unavailable there and are recorded as such.

New validated host class: official Swift 6.4 Ubuntu 24.04 aarch64 toolchain (no Swift ≥ 6.1 exists
in the Arch ARM repos). It runs on Arch glibc 2.43 only with soname-compat symlinks
(ncursesw/form/panel, libedit, libxml2, libpython) installed in `/usr/lib` — a dependency note for
the planned AUR PKGBUILD. All portable gates pass unchanged on aarch64/Arch: core 251 checks (debug
and release), headless 51, module-boundary 11 configurations, compiler smoke. This is the first
non-x86_64, non-Debian validation of the portable baseline.

Probe results:

1. Notification actions: **partial**. `GetCapabilities` advertises `actions`, but Quickshell's
   notification service renders no per-action buttons; exactly one implicit `default` action fires
   on toast-body click, and named actions (Join/Snooze/Dismiss) are silently dropped. Design
   consequence (pending the GNOME/KDE rows before deciding): the portable common denominator is a
   default-action-only toast; multi-action Join/Snooze needs either per-desktop capability detection
   or an app-owned alert window, which mirrors the macOS fullscreen-alert path.
2. Notification daemon restart: **works**. Killing the shell respawns it through an exit-code
   watchdog (~4 s, ≤5 relaunches/min, then gives up; supervision is the shell launcher, not
   systemd), and notifications plus the default action keep working. During the gap `Notify` calls
   fail — the Linux transport must watch the bus name and retry/re-register.
3. Tray: **infrastructure works**. StatusNotifierWatcher and a host are present and owned by the
   shell, with zero items registered on the box. Registering a real item (and menu/icon rendering)
   stays unverified until the tray prototype runs; re-registration must tolerate watcher restarts.
4. Autostart: **honored via systemd** — `xdg-autostart-generator` materializes
   `~/.config/autostart/*.desktop` as user units at login; entries created mid-session apply at next
   login. The "start at login" toggle must set that expectation. The marker-file verification after
   an actual re-login is still pending.
5. Sound: **works** through PipeWire's host-forwarded path (audible beep confirmed). The install
   ships an empty `/usr/share/sounds`, so the port must bundle its single reminder sound rather than
   assume a freedesktop sound theme.
6. Freeze catch-up: **works**. A live probe run was SIGSTOP-frozen for 232 s across the reminder's
   due instant; the first post-resume tick delivered the reminder. NowCore's tick/ledger model needs
   no wake-specific handling — the remaining gap is only the native notification transport.

Open small items: confirm the autostart marker after the next re-login; render-test a real
StatusNotifierItem with the eventual tray prototype. GNOME and KDE probe rows remain (separate VMs)
before the UI-framework choice. Both open items were closed by the second Hyprland probe round
below.

### Hyprland probe round 2 — tray item and notification behavior — 2026-09-21

Same Omarchy VM, same rules (probe scripts under `~/now-probes/`, nothing committed). Ran at repo
commit `a3c973a`; Swift 6.4 re-verified.

Closed leftovers:

- Autostart marker: **works** — created ~4 s after the first post-creation login, exactly the
  next-login semantics the generator predicts.
- Real StatusNotifierItem: **works end to end** — icon rendered in the Quickshell bar, left-click
  delivered `Activate` (coordinates always 0,0 — no positional info), property updates reached the
  bar, and a watcher restart (kill → new owner ~1.2 s) was survived by idempotent re-registration
  (~1.5 s; the watcher dedupes duplicate registrations). A real `com.canonical.dbusmenu` export at
  the item's Menu path renders a working menu — but only with `ItemIsMenu=true`, which makes the
  item menu-only: left and right click both open the menu, and no left-click-Activate plus
  right-click-menu combination exists. A misconfigured dbusmenu fails silently (empty popup, no bus
  calls, no errors).

Notification behavior (as reported; the per-row table was partially lost in transit, findings are
verbatim):

1. `expire_timeout` is decorative on Omarchy — only `urgency=critical` persists; every other
   notification dies within ~30 s regardless of the requested timeout.
2. `replaces_id` in-place update fails in practice despite source-level support — each call produces
   a new toast.
3. Critical urgency is the single reliable "stay until seen" mechanism, and its do-not-disturb
   bypass is `app_name`-gated and therefore unusable by this app's name.
4. The daemon never plays notification sounds — the only audio path is the app playing through
   PipeWire itself.

Design consequences recorded for the port (still Omarchy-specific; lock nothing until the GNOME and
KDE rows are probed):

- The primary reminder alert should be an app-owned surface (mirroring the macOS fullscreen alert
  path), with toasts as the ambient/secondary channel at best: no persistence, no in-place update,
  no toast action buttons on this desktop.
- Join/Snooze/Pause actions live in the tray's dbusmenu and/or the app window — the tray menu is
  proven viable (`ItemIsMenu=true`, real dbusmenu at the menu object path, idempotent one-shot
  re-registration on watcher owner changes).
- Bundle and play the reminder sound directly through PipeWire; do not rely on the notification
  daemon for audio.
- Autostart copy must say "applies at next login".
