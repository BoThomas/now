# AGENTS.md — now

Native macOS menu bar app for meeting reminders. Plain Swift files in `Sources/`, compiled together
without an Xcode project or Swift package. Keep Swift 5 language mode and macOS 13 / Apple Silicon
compatibility. `make-icon.swift` is a separate tool and must remain outside `Sources/`.

## AutoWiki and project context

Start with [autowiki/quickstart.md](autowiki/quickstart.md), then read the topic relevant to the
task:

- [Application lifecycle and state](autowiki/application.md): startup, setup, windows, preferences.
- [Calendar ingestion and cache](autowiki/calendars.md): ICS, EventKit, recurrence, offline
  recovery, diagnostics.
- [Reminder delivery and agenda](autowiki/reminders.md): routing, receipts, snooze, menu behavior.
- [Development and updates](autowiki/development-and-updates.md): checks, updater, release workflow.

Before changing a subsystem, read its relevant
[engineering constraints and regression notes](autowiki/engineering-notes.md). Preserve those
constraints; verify descriptive claims against current source. Source and repository instructions
remain authoritative. User documentation lives in [README.md](README.md) and
[docs/guide.md](docs/guide.md).

To refresh the wiki, use the project AutoWiki skill in `.agents/skills/autowiki/SKILL.md` with the
current coding harness and model. Keep architecture explanations in the wiki and detailed regression
lessons in the linked notes; reserve this file for instructions needed across tasks.

## Build and verify

After Markdown edits, run `npm run format-docs` and `npm run check-docs` (install the pinned
documentation tool with `npm ci` first). This formats project Markdown at 100 columns, leaves code
examples unchanged, and excludes installed third-party skills. Node.js/npm are only needed for
documentation tooling, not the Swift build.

Always run the signed build and selftest after changes:

```bash
./build-app.sh --require-identity
./outputs/now.app/Contents/MacOS/now --selftest
```

After Swift or analysis-tooling changes, also run `./scripts/analyze.sh` (one-time tool setup:
`./scripts/setup-analysis.sh`). It checks strict concurrency in Swift 5 mode and a focused SwiftLint
rule set against committed baselines. Inspect `./scripts/analyze.sh --report` when changing a
flagged function; existing lint findings may remain suppressed as that function grows. Fix new
findings or explain a justified exception. Do not regenerate baselines, loosen thresholds, add
blanket suppressions, or add unsafe concurrency annotations just to pass. Remove resolved baseline
entries when practical. Prefer coherent ownership and reusable business rules over mechanically
splitting functions or deduplicating UI/test fixtures. See the
[analysis workflow](docs/development.md#code-analysis) for scope and limitations. For
analysis-tooling changes, also run `python3 scripts/analysis-smoke.py`.

On this development machine, run the build outside the agent sandbox (`exec_command` with
`sandbox_permissions: "require_escalated"`) so signing can access the login keychain. Run selftest
normally. A sandbox-only identity lookup failure does not mean the certificate is absent. If the
unsandboxed build cannot use the identity, report it; do not accept ad-hoc signing, export private
keys, or change keychain trust/access settings to work around it.

Run focused suites from the
[test selection table](autowiki/development-and-updates.md#build-and-choose-checks) as appropriate.
For startup changes, also check GUI launch and continued liveness. `scripts/preflight.sh` runs the
full release checks; its updater smoke quits and reopens a running now. Use disposable test domains,
synthetic feeds, and fake transports. Never seed the installed app's calendars or preferences for
tests. Keep selftest deterministic and EventKit-free: never construct `AppStore` or another
`EKEventStore` there.

## Core safeguards

- Keep AppKit/state controllers on the main actor and policy helpers pure/nonisolated.
  Network/parser work stays off the main actor. Use common run-loop modes for timers that must
  continue during menu tracking. AppDelegate owns activation policy and wake handling.
- Keep one live EventKit store. Request Calendar access only through explicit user interaction.
  Never auto-prompt for notifications at launch or substitute fullscreen delivery after notification
  denial.
- Route source changes through existing fetch-generation, merge, and `commitEvents` paths. Failures
  retain accepted snapshots; incomplete feeds must not become successful empty results. Preserve
  occurrence identity, receipt ownership, and recovery data across edits/restarts.
- Previews must never open meeting links, schedule real snoozes, or write real reminder bookkeeping.
  Pause stops delivery while agenda actions remain usable.
- Preserve updater signature/version/OS checks at staging and install, and retain the old app until
  startup health is acknowledged. Read the detailed notes before changing install, rollback, or
  signing behavior.
- Never commit key material or log feed tokens. The signing backup belongs only in the password
  manager. See the [signing notes](autowiki/engineering-notes.md#code-signing-tcc-stability) for
  identity and recovery details.
- In zsh, never use `path` as a loop variable: it overwrites `PATH`.

## Releases

Only release when requested. Use `release.sh`; it updates version/build and changelog, runs the full
preflight, commits, tags, pushes, and publishes the release ZIP. `--dry-run` checks prerequisites
without publishing.

Releases, including dry runs, require clean `main` tracking and exactly synchronized with local and
live `origin/main`, both origin and authenticated `gh` resolving to `BoThomas/now`, the exact stable
signing identity, and an unused increasing version/tag. Preflights never fetch or mutate the
repository.

Every non-empty changelog entry and release body must group bullets under recognized `###` headers:
`Added`, `Changed`, `Improved`, `Fixed`, `Deprecated`, `Removed`, or `Security`. Never publish flat
release-note bullets. The README already links to the latest release; no per-release download-link
edit is needed.
