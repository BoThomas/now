# Reviewed scanner findings

Reviewed on Apple Swift 6.3.3 in Swift 5 mode; SwiftLint 0.65.1. Full-report mode confirms the 16
retained lint findings below. Thresholds and matching rules are unchanged. Revisit a rationale when
changing its function; this review does not authorize growth or blanket suppression.

## Resolved concurrency warnings

All 13 original warnings are resolved, and their individual baseline entries are removed:

- Three PreferenceKey defaults are immutable constants. Their reducers still mutate only the
  supplied per-reduction value.
- Both settings scroll-selection helpers are pure and explicitly nonisolated.
- RelativeDateTimeFormatter now belongs to one formatting call, avoiding shared mutable formatter
  ownership. This trades an allocation per relative label for straightforward thread safety.
- Nested display, termination and helper-exit callbacks capture their own weak references, avoiding
  concurrent access to an outer closure's mutable weak-capture storage. Common run-loop modes and
  main-actor execution remain unchanged.
- The update diagnostic formats its response in the completion callback before signaling its
  semaphore. It no longer shares mutable data/status/error variables with the waiting thread.

## Retained lint findings

| Function                                   | Finding                   | Concrete rationale and coverage                                                                                                                                                                                                                                                                             |
| ------------------------------------------ | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AlertController.installMonitor`           | complexity 23             | A single ordered keyboard dispatcher keeps escape, modifier, focus-guard and snooze precedence visible. Splitting branches risks conflicting key handling. Pure key-action tests and hosted activation/focus smoke cover it.                                                                                |
| `NowApp.updateSmokeCLIBody`                | complexity 25; length 122 | This headless test-only coordinator intentionally sequences check, stage, signature validation, mutation handoff, install and fault reporting in one readable scenario. It is absent from shipping compilation but still linted. Full updater smoke covers its negative and positive exits.                 |
| `RRULE.parse`                              | complexity 37             | The field switch rejects unsupported semantics, then validates cross-field/frequency combinations. Preserving explicit rejection is preferable to a generic dispatch table that hides those constraints. Recurrence/compliance selftests cover unsupported keys and combinations.                           |
| `ICSParser.parse`                          | complexity 21             | One component-stack traversal validates the entire envelope before publishing events. Splitting BEGIN/END transitions would spread the stack invariant and partial-feed rejection. Structure/transport and selftests cover malformed nesting and truncated feeds.                                           |
| `ICSParser.makeEvent`                      | complexity 30; length 132 | The property dispatcher deliberately preserves field order, first-valid-link rules, unknown-zone rejection, deferred end/recurrence parsing and duration precedence. A mutable property accumulator would mostly relocate the same state. Zone, duration, link and override fixtures protect this boundary. |
| `ICSParser.parseDuration`                  | complexity 21             | The compact state machine rejects duplicate/out-of-order components, mixed week/day forms and overflow. Extraction would scatter the grammar state across helpers. Duration/compliance fixtures cover those rejection branches.                                                                             |
| `RRULEExpander.expand`                     | complexity 19; length 82  | Local `consider` owns budget, COUNT, UNTIL, anchor and DST-gap accounting for both traversal modes. Retaining one ownership scope makes budget exhaustion and exact occurrence counting auditable. DST/COUNT selftests and workload probes cover it.                                                        |
| `ICSBuilder.meetings`                      | complexity 24; length 116 | This ordered materialization transaction shares a feed budget across sorted UIDs, resolves master/override revisions, and emits only a complete result. Broad parser redesign is deferred; recurrence identity, resource-limit and deterministic workload fixtures cover the coupling.                      |
| `ReminderNotificationController.reconcile` | complexity 17             | The ordered receipt pass distinguishes startup protection, in-flight submissions, diagnostic retries, hiding and replacement. Keeping these states together makes ownership and stale-action handling visible. Notification lifecycle fixtures cover cold starts, edits, retries and explicit actions.      |
| `MenuBarController.menuNeedsUpdate`        | length 106                | Native menu construction reads as a single ordered agenda with controls and separators. Splitting static row construction solely for line count would obscure visible order. Hosted reminder/menu tests cover selection and tracking updates.                                                               |
| `NativeCalendarSource.parsedEvent`         | 7 parameters              | Seven named plain values form the intentional EventKit-free boundary; wrapping them would introduce a second DTO with the same fields. Pure native mapping tests avoid constructing an EventKit store.                                                                                                      |
| `GitHubMark.arcToCubics`                   | 7 parameters              | Endpoint, radii, rotation and arc flags directly represent the SVG elliptical-arc algorithm. A parameter bag would hide the mathematical inputs without simplifying it. General icon-renderer reorganization remains explicitly deferred; no algorithm change here.                                         |

The startup function's length finding was resolved by extracting notification wiring during the
runner migration. No other lint entries were removed, regenerated or relaxed. Lint still scans
conditional test hooks within production files; dedicated fixture files remain outside its scope.

## Core extraction relocation

The first extraction moves seven existing findings to `Sources/NowCore/ICS.swift`: `RRULE.parse`
(one), `ICSParser.parse` (one), `ICSParser.makeEvent` (two), `ICSParser.parseDuration` (one), and
`RRULEExpander.expand` (two). Their baseline paths are relocated and source text includes `package`
where cross-module consumers require it; function bodies and the above rationales are unchanged. The
two `ICSBuilder.meetings` findings remain in `Sources/ICS.swift`, with updated line locations. The
other seven findings remain in place. No finding is resolved by this move and none is newly
accepted. Full SwiftLint `--report` verification still requires the pinned macOS toolchain.

Visibility changes are confined to the core's actual consumers:

- `ICSProperty` and its fields/explicit initializer: native mapping, materialization and fixtures.
- `ParsedEvent`, its existing initializer and payload fields: native mapping, CLI diagnostics,
  materialization, overrides and parser fixtures.
- `RRULE` and `parse`: parsed payload and rejection tests. Its representation/helpers stay internal.
- `ICSParseResult` and result fields: builder, CLI and fixtures. Its initializer stays internal.
- `ICSDateFormatters` initialization and `retainedCount`: builder-owned cache and ownership tests;
  its formatter operation/storage stay internal/private.
- `ICSParser` parse/date/make-event/duration/unescape/property/unfolding operations and line limits:
  production callers and existing parser regression tests. Implementation helpers, the zone
  table/lookup, warning-collecting make-event overload, duration bound and `ICSInputError` stay
  internal/private.
- `RRULEExpander` expansion/result fields, occurrence entrypoints and budget: builder and budget/DST
  fixtures. Calendar traversal helpers stay private.
- `LinkExtractor` selection with injected discovery, join conversion, provider/display/classifier
  and text cleanup operations: native adapter, UI and link regression tests. Tables stay internal;
  Apple's detector stays private in the shell.

All widened declarations use `package`, not `public`; no unsafe concurrency annotations are added.

## Models and filtering slice

`Models.swift` and `TitleFilter.swift` now live under `Sources/NowCore`; native presentation and
palette-default constructors stay in `Sources/Models.swift`. Neither moved file had a retained lint
entry, so no baseline is relocated or regenerated in this slice. The existing 16 findings and their
rationales remain; full macOS lint/concurrency analysis is still an outstanding gate.

The following surfaces gain `package` access for existing app/harness consumers:

- `CalendarSubscription`, `NativeCalendar`, `Persisted`, `MeetingEvent`: payload fields,
  initializers, Codable/Identifiable witnesses and the legacy occurrence-ID accessor. Core calendar
  and event constructors require explicit color strings; shell convenience initializers preserve the
  macOS defaults. Coding keys and failable element decoding stay internal.
- `AppSettings` and delivery enums: settings fields, derived choices and the existing preset/range
  helpers used by UI and regression tests. The sound identifier list moves from `AppStore` to the
  model's compatibility vocabulary; `AppStore.soundNames` delegates to it. Scalar normalization and
  coding keys stay internal/private.
- `TitleFilterRule`, its mode/fields/initializers, rule edit/normalization helpers and prepared
  `TitleFilterMatcher` operations: UI, source reconciliation and tests. Matching and normalization
  bodies are unchanged; compiled regex storage stays private.
- `PreferenceDecoding` initialization, key and recovery result: `StoredPreferences` and fixtures.
  Its existing `@unchecked Sendable` conformance moves with the same lock-protected state; no new
  unsafe conformance is introduced. Internal `note`/`recover` operations remain within core.
- `ModelDecoding.decoder(calendarColor:)`: a new per-decoder `@Sendable` callback for the native
  palette, with a private user-info key. No global mutable platform configuration is introduced.

Plain model values and delivery/filter enums have checked `Sendable` conformances, making their
existing use across fetch and UI ownership boundaries explicit. Debug/release core checks pass
complete strict concurrency with warnings treated as errors. This does not establish macOS actor
checking for the native adapters.
