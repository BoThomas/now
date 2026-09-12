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
