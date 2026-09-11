# now: project map

now is a native macOS menu bar app that turns Apple Calendar events and ICS feeds into meeting
reminders, delivered through a fullscreen panel or macOS notifications. The [README](../README.md)
covers installation; the [quick guide](../docs/guide.md) explains the user controls. This wiki
explains how the implementation fits together. [AGENTS.md](../AGENTS.md) remains the authoritative
engineering rulebook.

## Build and orient yourself

The app uses one SwiftPM executable target in [Package.swift](../Package.swift).
[build-app.sh](../build-app.sh) assembles and signs the bundle. The build targets Apple Silicon and
macOS 13 in Swift 5 language mode. See [development prerequisites](../docs/development.md) for SDK
requirements.

Run from the repository root:

```bash
./build-app.sh --require-identity
./outputs/now.app/Contents/MacOS/now --selftest
```

On this development machine, the signed build must run outside the agent sandbox so it can access
the login keychain; follow [the build instructions in AGENTS.md](../AGENTS.md). The outputs are
`outputs/now.app` and `outputs/now.zip`. Selftest selects the CLI path before GUI startup and
exercises more than parsing, including reminder, cache, settings, and updater decisions. See
[development and updates](development-and-updates.md) for focused checks and release constraints.

## Choose a path

| Task                                                                               | Read                                                  |
| ---------------------------------------------------------------------------------- | ----------------------------------------------------- |
| Understand startup, settings, window ownership, or persistence recovery            | [Application lifecycle and state](application.md)     |
| Diagnose missing events or change feeds, recurrence, filtering, or offline restore | [Calendar ingestion and cache](calendars.md)          |
| Change when reminders fire, notification actions, snooze, or menu countdowns       | [Reminder delivery and agenda](reminders.md)          |
| Build, select regression checks, investigate updates, or prepare a release         | [Development and updates](development-and-updates.md) |

The main flow is calendar source → `MeetingEvent` → `AppStore.commitEvents` → agenda and reminder
routing. [AppDelegate](../Sources/App.swift) connects the controllers, while
[AppStore](../Sources/AppStore.swift) owns the live state and reconciliation. Pure helpers in the
source files let tests exercise policy without creating the normal app and its EventKit store.

To maintain these pages, use the [project AutoWiki skill](../.agents/skills/autowiki/SKILL.md).
Verify affected claims against source and tests; the wiki is a navigation aid, not a substitute for
that verification.

Before changing this area, read the relevant
[engineering constraints and regression notes](engineering-notes.md).
