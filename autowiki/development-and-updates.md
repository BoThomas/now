# Development and updates

[Project map](quickstart.md) · [Application lifecycle](application.md)

## Build and choose checks

Follow [docs/development.md](../docs/development.md) for prerequisites and [AGENTS.md](../AGENTS.md)
for the required signed build and selftest after changes. [build-app.sh](../build-app.sh) builds the
SwiftPM `NowApp` executable target, separately runs the root icon generator, assembles the bundle,
signs and verifies it, then creates the ZIP. Keep `make-icon.swift` outside `Sources/` because it is
a separate executable.

After Swift or analysis-tooling changes, run `./scripts/analyze.sh` after the build. It compares
strict-concurrency warnings and focused SwiftLint findings against committed baselines; preflight
also runs it in shipping, selftest and updater-runner configurations.
[Reviewed findings](../analysis/review.md) records the resolved concurrency warnings and retained
lint rationales. `./scripts/setup-analysis.sh` installs the pinned linter once, and `--report` on
the analysis command exposes the existing backlog. See the
[analysis workflow](../docs/development.md#code-analysis) for baseline review and limitations. The
compiler emits `NowCore` as a module before checking shell and fixture consumers; the
[module checker](../scripts/typecheck-modules.py) never flattens core sources into the shell.

[SelfTest.run](../Tests/NowTests/SelfTest.swift) aggregates pure parser, recurrence, reminder,
notification, settings, fetch/cache, bookkeeping, filter, and updater checks. Its own entry point
never starts the normal app; keep new tests free of constructed EventKit stores or fullscreen
panels. Extend the existing pure policy helpers when testing decisions.

| Changed behavior                                                  | Focused checks beyond build/selftest                                                                                                                                                                                                                        |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Shared parser, models, filtering, decoding or module boundary     | `./scripts/test-core.sh` and `NOW_TEST_CONFIGURATION=release ./scripts/test-core.sh` ([runner](../Tests/NowCoreTests/Runner.swift), [model cases](../Tests/NowCoreTests/ModelTests.swift)); these do not replace macOS adapter/materialization/smoke suites |
| Notification routing, receipts, preferences, setup, startup/focus | `python3 scripts/notification-smoke.py --all-smokes` ([harness](../scripts/notification-smoke.py))                                                                                                                                                          |
| Reminder bookkeeping or paused agenda                             | `python3 scripts/reminder-state-smoke.py` ([harness](../scripts/reminder-state-smoke.py))                                                                                                                                                                   |
| Offline persistence/restoration                                   | `python3 scripts/calendar-cache-smoke.py` ([harness](../scripts/calendar-cache-smoke.py))                                                                                                                                                                   |
| Feed transport or envelope validation                             | `python3 scripts/calendar-fetch-smoke.py` ([harness](../scripts/calendar-fetch-smoke.py))                                                                                                                                                                   |
| Recurrence workload or occurrence materialization                 | `python3 scripts/feed-workload-smoke.py` and `python3 scripts/parser-performance-smoke.py` ([workload](../scripts/feed-workload-smoke.py), [performance](../scripts/parser-performance-smoke.py))                                                           |
| Signed update staging/install/rollback                            | `./scripts/update-smoke.sh --app outputs/now.app` ([harness](../scripts/update-smoke.sh))                                                                                                                                                                   |

[scripts/preflight.sh](../scripts/preflight.sh) runs the signed release build, debug and optimized
selftests, and all of these suites; `--app` uses an existing bundle instead of rebuilding. The
updater smoke temporarily quits and later reopens a running now. The full notification harness
includes synthetic GUI fixtures. Use the disposable harness data rather than installed
calendars/preferences. These commands describe repository workflows; a documentation review alone
does not establish that they pass.

## Update discovery and preparation

The updater uses GitHub Releases directly. [UpdateLogic](../Sources/Updater.swift) owns pure
version, throttle, and presentation decisions; `UpdateController` owns live main-actor state.
Automatic checks are spaced at least six hours apart, including failures; manual checks bypass that
throttle. A newly published eligible release can be offered immediately. Automatic presentation
starts with a menu/About indication, with an eighteen-hour uninstalled dwell before window
escalation; opt-in update notifications use their own once-per-version marker and suppress that
automatic delayed window. Manual checks still answer with a window.

`UpdateFetch` enforces HTTPS for production URLs and redirects, with HTTP allowed only for an
explicit loopback test override. `UpdateStaging` streams a bounded archive via
[UpdateArchiveDownload](../Sources/UpdateDownload.swift), extracts with `ditto`, and requires
exactly one top-level `now.app`. Production limits are 100 MB archive, 500 MB extraction, 50,000
entries, and 60 seconds extraction time. Dedicated file-queue work keeps extraction polling and
install verification off the main actor. See [Updater.swift](../Sources/Updater.swift).

Staged bundles must satisfy strict nested/all-architecture code-signature validation against the
pinned bundle identifier and certificate fingerprint, then match the manifest version, minimum build
constraint, and supported OS metadata. `validationProblem` is reused immediately before
installation. Request generations and install-attempt/root/manifest checks stop stale asynchronous
preparation or validation from winning.

## Installation is a health-checked swap

[UpdateInstaller](../Sources/Updater.swift) starts a detached shell helper with parameters in
environment variables. It waits for the old PID to exit, renames the old bundle to a sibling backup,
moves the staged bundle into place, and launches the actual executable. It retains the backup until
the child writes the exact PID/random-token acknowledgement. Child exit or timeout attempts rollback
and relaunches the old app with a one-launch error reason.

The pending version is persisted before the helper starts. [AppDelegate](../Sources/App.swift)
acknowledges startup after two seconds of normal AppKit startup; only successful acknowledgement
allows `startupHealthAcknowledged` to consume that marker and show Update Complete. An absent helper
contract is an ordinary-launch no-op success; a partial or unwritable contract fails closed. Keep
this commit point aligned with [feature guide history](application.md). Multiple running instances
block installation, and updater termination bypasses the normal user quit dialog while still using
cache termination coordination.

The stable signing identity also anchors Calendar permission across rebuilds. Rotation must
coordinate the build identity and updater pins;
[engineering notes](engineering-notes.md#code-signing-tcc-stability) contain signing details, and
[AGENTS.md](../AGENTS.md) retains release rules. Do not infer a missing identity from sandboxed
keychain lookup or replace the required signed build with ad-hoc signing on this machine.

## Release workflow

[release.sh](../release.sh) validates prerequisites before modifying version/build and changelog,
builds and runs the full preflight, then commits, tags, pushes, and publishes the release asset.
`--dry-run` checks prerequisites and prints a plan without running that publication pipeline.
Release operations require a clean `main`, exact synchronization with local and live `origin/main`,
the expected repository/authentication, stable signing identity, and an unused increasing version.
Release notes must contain recognized `###` categories such as `Added` and `Fixed`.

Use the release rules in [AGENTS.md](../AGENTS.md), signing recovery guidance in
[engineering notes](engineering-notes.md#code-signing-tcc-stability), and commands in
[release.sh](../release.sh) when a release is requested. A normal code or documentation change does
not itself require publishing a release.

Before changing this area, read the relevant
[engineering constraints and regression notes](engineering-notes.md).

## Compilation and test isolation

[Package.swift](../Package.swift) selects the shipping `NowApp` executable plus its `NowCore`
library dependency by default. macOS test commands select an allow-listed `NowHarness` executable
with the same core dependency and a dedicated scratch directory, supporting Command Line Tools
without XCTest. `NOW_TEST_SUITE=core` instead selects `NowCoreTests`, which imports only the library
and Foundation. Suite defines apply to the shell harness, not the core. Cross-module APIs use
`package` access, with implementation helpers remaining internal/private. Unit fixtures live in
`Tests/NowTests`; hosted runners use conditional accessors in the same files as private production
state. No source copies are rewritten. See the
[test boundary](../docs/development.md#test-target-boundary) for dependency substitutions and the
separate signed updater fixture. Production CLI parsing, native-calendar inspection, meeting
detection and update-check diagnostics remain supported.
