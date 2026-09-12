# Current work target: cross-platform groundwork via core extraction

Status: planned; implementation has not started.

Branch: `feat/cross-platform-core`.

Starting point: build/test modernization merged through PR #16, merge commit
`d01dbd786159bc63b088dfc1254c880d088eccd9`.

## Objective

Prepare _now_ for future Windows and Linux ports by extracting the platform-neutral core (ICS
parsing, recurrence, models, filtering, activity policy, cache and reminder bookkeeping rules) from
the AppKit/EventKit shell into its own SwiftPM library target. This stage ships no user-facing
change: the macOS app keeps its current behavior, bundle identity, and release pipeline. Cross-
platform shells (tray glue, notifications, SwiftCrossUI settings) are explicitly out of scope here
and are decided after this stage.

Read `AGENTS.md`, `autowiki/quickstart.md`, the relevant topic pages, and
`autowiki/engineering-notes.md` before implementation. This plan authorizes target/module
restructuring and access-control widening only where extraction requires it. It does not authorize a
release, a Swift 6 migration, platform/language-mode changes, behavioral changes, or weakening any
safeguard recorded in the engineering notes.

## Starting evidence and open decisions

- The package currently defines one executable target `NowApp` (21 source files in `Sources/`) plus
  allow-listed `NowHarness` test targets selected via `NOW_TEST_SUITE`. There is no library target.
- Platform-neutral candidates with no AppKit/EventKit imports: `ICS.swift` (parsing and recurrence),
  `Models.swift`, `TitleFilter.swift`, `MeetingActivity.swift`, most of `Helpers.swift`,
  `CalendarEventCache.swift` (verify its I/O is path-injected, not hardcoded), and the pure policy
  portions of `Preferences.swift`.
- Shell-bound files that must stay out of the core: `App.swift`, `AppStore.swift` (EventKit
  ownership), `MenuBar.swift`, `*UI.swift`, `Notifications.swift`, `NativeCalendars.swift`,
  `Updater.swift`/`UpdateDownload.swift`.
- `AppStore` responsibility extraction was deliberately deferred by PR #16 and remains follow-up
  work; this stage must not attempt a broad controller redesign. Extract the core around it.
- Library target naming and visibility strategy are open decisions: smallest viable option is a
  second SwiftPM target consumed by `NowApp` and the harnesses; widening `public` is allowed only
  where the module boundary requires it, and never as a general API cleanup.
- Harness selection in `Package.swift` compiles `Sources` plus suite fixtures; it must be updated so
  suites still compile without duplicating production sources between targets.
- The analysis scripts discover sources and match baselines by path; source moves between files or
  targets require reviewing `analysis/` baselines and `analysis/review.md` rationales. Findings must
  be relocated reviewably, never silently accepted or dropped.
- 16 lint findings carry individual rationales; extraction may resolve some and relocate others.
  Record which and why.

## Phase 1: define the core boundary

- [ ] Inventory every file in `Sources/` for framework imports (AppKit, EventKit, UserNotifications,
      OSLog) and network/updater dependencies; record the resulting core/shell split and any file
      that resists classification before moving anything.
- [ ] Choose the smallest viable library target layout and record the decision, including rejected
      alternatives (e.g., separate package, multiple feature modules).
- [ ] Move the core files into the library target without behavioral edits; keep names, types and
      access levels stable except where the module boundary requires widening, and record each
      widening.

## Phase 2: rebuild app and harnesses on the boundary

- [ ] Make `NowApp` depend on the core library; keep the executable entry point, bundle metadata,
      entitlements and signing pipeline identical.
- [ ] Update `Package.swift` harness selection so every suite builds against the same library; no
      suite may recompile a private copy of core sources.
- [ ] Update analysis source discovery, baselines and `analysis/review.md` for the new layout,
      relocating findings with reviewable rationale; verify that new findings still fail and
      resolved baseline entries are removed.
- [ ] Update agent instructions (`AGENTS.md`), AutoWiki pages, and any scripts that assume a single
      target, so instructions describe the layout that actually ships.

## Phase 3: verify behavior is unchanged

- [ ] Signed release and debug builds pass the full selftest suite; occurrence identity, receipt
      ownership, recurrence results, and recovery data are unchanged.
- [ ] All existing test suites (notification, reminder, cache, fetch, workload, parser, updater)
      pass in the new layout, including the parser benchmark digest comparison.
- [ ] Analysis and analysis smoke pass for shipping, selftest and updater configurations.
- [ ] GUI launch and liveness checks pass with no permission prompts; updater smoke passes against
      the unchanged pinned identity.
- [ ] Record artifact sizes and build timings as observations only; no performance claims.
- [ ] Run `npm ci`, `npm run format-docs`, and `npm run check-docs` after Markdown edits; refresh
      affected wiki pages with the AutoWiki skill if architecture explanations change.

## Validation and acceptance

Follow the current `AGENTS.md` commands. On this machine the signed build runs outside the agent
sandbox for login-keychain access; selftest runs normally. Keep selftests deterministic and
EventKit-free: never construct `AppStore` or another `EKEventStore` there. Use disposable test
domains and synthetic feeds; never seed the installed app's calendars or preferences.

## Boundaries and deferred work

Do not write any Windows/Linux code, tray implementations, notification shims, or add SwiftCrossUI
or other UI dependencies in this stage. Do not extract `AppStore` responsibilities beyond what the
core boundary forces, reorganize settings files, or touch the updater beyond keeping it compiling.
No release, no merge without a separate request. Follow-up candidates after this stage, in the order
they become meaningful: `AppStore` responsibility extraction, a cross-platform core usage spike
(headless run of the core on Linux via the Swift Linux toolchain), then shell experiments (tray
glue, notifications, SwiftCrossUI settings) per platform.

## Handoff

Implementation stages and validation evidence are recorded below as work proceeds. Continue on this
branch; do not merge or release without a separate request.
