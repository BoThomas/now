# Current work target: build/test modernization and scanner cleanup

Status: phase 1 implemented; validating signed configurations before test migration.

Branch: `feat/build-test-modernization`.

Starting point: analysis workflow merged through PR #15, merge commit
`1da1f71dec309c57f20b3bada0c170e56fe3f02e`.

## Objective

Standardize compilation and test execution, separate the full test suite from the shipping app, and
resolve or explicitly justify the existing scanner findings. Preserve observable application
behavior, calendar permissions, reminder bookkeeping, and updater safety. Work in small, reviewable
commits; do not combine build migration with broad controller redesign.

Read `AGENTS.md`, `autowiki/quickstart.md`, the relevant topic pages, and
`autowiki/engineering-notes.md` before implementation. This plan authorizes investigating and
migrating the current plain-Swift build layout; it does not authorize a release, signing-identity
rotation, platform/language-mode upgrade, or weakening safeguards. Update layout-specific agent
instructions when the implemented build actually changes.

## Starting evidence and open decisions

- `build-app.sh` compiles all `Sources/*.swift` into one executable, manually assembles/signs the
  app, deletes `.build` on each run, and has no explicit release optimization flag. `strip -x` is
  symbol stripping, not compiler optimization.
- Full selftests and several smoke/diagnostic entry points are reachable in the shipping executable.
  Dedicated test files account for substantial source size; source line counts are not binary-size
  measurements.
- Some smoke harnesses rewrite temporary copies of app source to expose methods or replace
  dependencies. Preserve their behavioral coverage while introducing stable test access points.
- The starting baselines contain 13 compiler warnings and 17 lint findings: nine complexity, six
  function-length, and two parameter-count findings. Re-run analysis before acting on these counts.
- SwiftPM is the preferred initial direction for compilation and separate test targets, retaining a
  thin app bundling/signing wrapper. Verify feasibility with the actual AppKit entry point, resource
  paths, access control and existing integration harnesses. An Xcode app/test project is an
  alternative if concrete integration requirements justify its additional tooling dependency.
- Do not create a large package graph or make everything public merely to enable testing. Choose the
  smallest viable production/test target structure. Pure unit tests must remain EventKit-free;
  hosted integration tests may need a separately signed, disposable app.

## Phase 1: establish the build and test boundary

- [x] Record the current build/test commands, toolchain, app metadata, designated signing
      requirement, and baseline analysis output. Inspect all `--selftest`, smoke flags and test
      environment hooks.
- [x] Trial the smallest SwiftPM target layout; document the selected layout and any reason to
      choose Xcode instead. Keep this separate from behavioral cleanup.
- [x] Add explicit development and release configurations. Use optimized compilation deliberately
      for release, preserve incremental artifacts for development, and provide an explicit clean
      action. Verify optimized behavior rather than assuming equivalence.
- [x] Preserve the app bundle ID, executable name, minimum OS, architecture, entitlements, icon and
      other resources. Keep Swift 5 mode, macOS 13 and Apple Silicon compatibility. Keep the icon
      generator outside the application target.
- [x] Preserve exact stable signing, certificate verification, designated requirement and existing
      staging/install/rollback/startup-health checks. Retain a single convenient build command and
      existing output paths where practical.

## Phase 2: separate tests without losing coverage

- [ ] Move the full selftest suite into separate test targets/runners. Initially preserve every
      assertion and deterministic fixture; reorganize tests only after proving the migration works.
- [ ] Ensure shipping builds exclude unit-test fixtures and developer-only runners. Decide
      separately which operational diagnostics remain supported; do not remove useful diagnostics
      blindly.
- [ ] Keep signed-app smoke coverage for startup, notification actions/focus and updater
      installation and rollback. Where hooks are needed, design narrowly scoped test builds/runners
      and verify that shipping behavior is still exercised. Document any unavoidable test-build
      differences.
- [ ] Replace temporary-source rewriting with minimal explicit dependency injection or supported
      test access. Do not widen the public API or introduce production bypasses just to satisfy
      tests.
- [ ] Update all harnesses, preflight, release integration, analysis source discovery/baseline
      paths, documentation and agent instructions for the chosen layout. Pure tests must not
      initialize `AppStore`/`EKEventStore` or use live preferences/calendars.

## Phase 3: resolve scanner findings

- [ ] Address concurrency warnings in small batches: immutable preference defaults, isolation of
      pure settings helpers, shared formatter ownership, and nested callback captures/shared
      callback results. Inspect actual thread and lifetime guarantees; warnings are not
      automatically races.
- [ ] Review all lint findings. Extract cohesive parser stages or responsibilities only where it
      improves understanding. Preserve strict rejection, recurrence identity and resource budgets.
      Complexity needed for correct validation may warrant a documented retained finding.
- [ ] Remove resolved baseline entries and verify that new findings still fail. Never
      bulk-regenerate baselines, loosen thresholds, add blanket suppressions, or add unsafe
      concurrency annotations simply to obtain a pass. Path-only baseline migrations must be
      reviewable and preserve the original findings without silently accepting new ones.
- [ ] Record each remaining finding with a concrete rationale. The target is resolved or
      deliberately justified findings, not mechanically achieving zero warnings through
      suppressions.

## Validation and acceptance

During the transition follow the current `AGENTS.md` commands. If commands change, retain
compatibility wrappers until replacements are validated, then update all callers and instructions
together.

- [ ] Signed build and selftest/replacement test suite pass. On this machine the signed build needs
      execution outside the agent sandbox for login-keychain access; no ad-hoc workaround.
- [ ] Both development and optimized release builds pass relevant tests; record artifact sizes and
      representative build timings without promising a particular improvement.
- [ ] GUI launch and continued liveness pass, with no unexpected permission prompts. Use synthetic
      data and disposable app/preferences domains for integration tests.
- [ ] The full release preflight passes against the final signed release artifact, including updater
      smoke. It may temporarily quit/reopen a running now; preserve the harness's restoration logic.
- [ ] Analysis and analysis smoke tests pass with the new layout. Check full-report mode when
      editing baselined functions, since native SwiftLint baseline matching can hide growth in those
      functions.
- [ ] Verify the release artifact no longer includes the full unit-test runner/fixtures and that
      supported diagnostic commands still work. Check that test builds cannot replace release
      outputs.
- [ ] Run `npm ci`, `npm run format-docs`, and `npm run check-docs` after Markdown edits. Refresh
      affected wiki architecture explanations using the project AutoWiki skill when the architecture
      changes.
- [ ] Finish with a clear report of the final target structure, commands, validation, remaining
      justified findings and limitations. Commit and push implementation progress on this branch.

## Boundaries and deferred work

Broader `AppStore` responsibility extraction, general settings-file reorganization, and simplifying
its GitHub icon renderer are follow-ups unless a narrow change directly supports the target/test
boundary or a reviewed scanner finding. Do not add duplication/dead-code tools, migrate to Swift 6,
change user-facing behavior, publish a release, merge the implementation branch, or introduce a new
CI/signing-secret setup as incidental work.

## Handoff

The planning commit contains no implementation changes. Continue on this branch, update the
checkboxes and decision notes as work proceeds, and keep build migration, test migration and scanner
cleanup reviewable separately. This handoff is for later implementation; do not start that work as
part of the planning task. Merging or releasing the resulting work requires a later request.

## Implementation evidence

### Stage 1 — minimal SwiftPM build

Selected one executable target, `NowApp`, with product `now`. The existing `@main` AppKit entry
point builds unchanged with SwiftPM; no public API or extra production modules are needed. Apple
Swift 6.3.3 compiles in Swift 5 mode, targeting arm64 and macOS 13. The initial debug trial
completed in 31.09 seconds. Repository-local module/manifest caches avoid sandbox cache permission
failures. The bundle remains `com.thomasboch.now`, version 2.0.0/build 106, with unchanged
resources, entitlements, and certificate-root designated requirement
`A505B08900C56A28709479297A049525A2A187C6`. The pre-migration executable measured 4,802,800 bytes.

`build-app.sh --require-identity` defaults to SwiftPM release optimization; `--debug` writes to
`outputs/debug/now.app`, and `--clean` explicitly clears SwiftPM compilation artifacts. Existing
release paths are retained. Initial analysis confirmed 13 concurrency warnings and 17 lint findings
(nine complexity, six length, two parameter count). No baseline changes in this stage.

Stage 1 checks: signed release build 58.51 s, signed incremental debug build 4.15 s; release
executable 3,125,312 bytes, debug executable 10,728,480 bytes. Both full selftests pass. Default
analysis accepts exactly the unchanged baseline. Documentation formatting/checks pass.
