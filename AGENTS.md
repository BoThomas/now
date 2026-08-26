# AGENTS.md — now

Native macOS menu bar app for meeting reminders (single-file Swift, no Xcode project). See README.md for user-facing docs.

## Project layout

- `Sources/Helpers.swift` — `Palette` (colors) and `Fmt` (formatting) helpers.
- `Sources/Models.swift` — `CalendarSubscription`, `AppSettings`, `Persisted`, `MeetingEvent`.
- `Sources/ICS.swift` — `ICSParser`, `RRULE`/`RRULEExpander`, `LinkExtractor`, `ICSBuilder` (pure Foundation, no UI).
- `Sources/AppStore.swift` — state, persistence, fetching, reminder scheduling (`@MainActor` ObservableObject).
- `Sources/AlertUI.swift` — `AlertPanel`/`AlertController` + fullscreen SwiftUI views.
- `Sources/MenuBar.swift` — `MenuBarController` (NSStatusItem + NSMenu).
- `Sources/SettingsUI.swift` — settings window views.
- `Sources/App.swift` — `AppDelegate`, `@main` entry, `--parse` CLI.
- `Sources/SelfTest.swift` — selftest.
- `build-app.sh` — builds `outputs/now.app` with `swiftc` (compiles `Sources/*.swift`, Swift 5 mode, target `arm64-apple-macos13.0`, SDK `MacOSX15.4.sdk`), generates icons via `make-icon.swift` (root, separate tool — do NOT move it into Sources/), ad-hoc codesigns, zips.
- `release.sh` — release pipeline (see Releasing below). `CHANGELOG.md` is generated/maintained by it.
- `Info.plist` — `LSUIElement=true` (menu bar only, no Dock icon), bundle ID `com.thomasboch.now`.
- Persistence: UserDefaults key `local.tboch.now.state.v1` (custom key, versioned), JSON of subscriptions + settings. Legacy `local.tboch.now` domain is migrated on first read (old bundle ID).

## Commands

```bash
./build-app.sh                                    # build outputs/now.app (+zip)
./outputs/now.app/Contents/MacOS/now --selftest   # parser unit test, exit 0/1
./outputs/now.app/Contents/MacOS/now --parse <url-or-ics-file>
./release.sh --dry-run                            # check release prerequisites
```

Always run the build + selftest after changes. A GUI smoke test (launch, check it's alive after ~4s, kill) is good for changes touching app startup.

## Releasing

`./release.sh` is the agent-friendly release pipeline: version bump (patch/minor/major or explicit `X.Y.Z`), prepends a CHANGELOG.md entry, sets Info.plist version/build, builds + selftests, commits, tags `vX.Y.Z`, pushes, and creates a GitHub release with `now-vX.Y.Z.zip` attached.

- First release: `./release.sh --notes "Initial release — see README for features" --yes` (no bump needed; uses the current 1.0.0 since no tag exists yet, and creates the repo via `gh repo create` if origin is missing).
- Subsequent: `./release.sh patch --notes $'- Fixed X\n- Added Y' --yes`
- Flags: `--dry-run` (plan only), `--repo owner/name` (default `BoThomas/now`), `--yes` (skip confirm). Requires a clean tree and an authenticated `gh`.
- README's Download section links to `/releases/latest`, so it always points at the newest release — no README edits needed per release.
- After first publish, set repo topics once: `gh repo edit --add-topic macos --add-topic menubar --add-topic calendar --add-topic ics --add-topic meeting-reminders`

## Debug tool: `--parse`

Prints exactly what the app would extract from any feed — use this first when "events are missing":

- fetches the URL (or reads a local file), runs the real parser, prints RAW VEVENT count, all-day count, the ±window, per-event start/allDay/rrule/status, then the final kept events with detected links.
- Example (public Google holiday calendar): `now --parse "https://calendar.google.com/calendar/ical/de.german%23holiday%40group.v.calendar.google.com/public/basic.ics"` — note: all-day feed, so expect RAW > 0 / PARSED 0
- If RAW count is 0 → line-ending/encoding problem at parse level; if RAW > 0 but PARSED 0 → window/filter issue (past events, all-day only).

## Hard-won knowledge (don't regress)

- **CRLF feeds**: many servers send `\r\n`. In Swift, CR+LF is a single grapheme cluster, so `split(separator: "\n")` (Character) does NOT split CRLF lines — the whole file becomes one line and parsing silently yields 0 events. `ICSParser.unfolded` normalizes `\r\n`/`\r` → `\n` first. The selftest includes a CRLF variant for regression.
- **Copy/Paste needs a main menu**: the app is `.accessory`/LSUIElement, so there was no menu bar and Cmd+V/Cmd+A beeper-failed. `AppDelegate.setupMainMenu()` installs a hidden Edit menu — keep it.
- **Pasteboard vs. menu commands**: standard text shortcuts are responder-chain actions; menu-bar-only apps must provide the menu explicitly.
- **Meeting links** come from (in priority order): `CONFERENCE`/`X-GOOGLE-CONFERENCE`/MS props → `URL:` property → known hosts in LOCATION → known hosts in DESCRIPTION → any http(s) URL. Some uses the `URL:` property.
- **Feed line endings/folding**: RFC 5545 continuation lines (leading space/tab) are unfolded before parsing; text values are unescaped (`\n`, `\,`, `\;`, `\\`).
- **Window**: events kept if start within −6h…+14d of fetch time; all-day and `STATUS:CANCELLED` events are always skipped. If a user's events "don't show up," check they're actually in the future.
- **Late visibility**: started meetings stay in the menu bar/menu with a negative countdown (`-3m`) per setting `lateMinutes` (−1 = hide once started, 0 = until end, N = N min after start). Running events take precedence over future ones in the menu bar label.
- **Snooze re-fire**: a snoozed alert re-fires when the snooze expires as long as `now <= event.end` — including after the meeting has started. Only a snooze ending after the meeting end stays dismissed.
- **Colors**: per-subscription `colorHex` in settings (ColorPicker). Changing a color re-tints already-fetched events in place (`recolorEvents`). New subscriptions get a rotating palette default.
- **Concurrency**: AppKit/MainActor via `@MainActor` on AppStore; fetches run through static nonisolated funcs + task groups. Swift 5 language mode — keep new code compatible.
- `NSWorkspace.didWakeNotification` triggers a refresh (timers stall during sleep).
- Alert window: borderless NSPanel, `.screenSaver` level, `canJoinAllSpaces`, key-monitor handles esc/return/s.

## Gotchas

- `swiftc` expression type-check blowups: break long `CGRect(...)` expressions with mixed Int/CGFloat math into sub-expressions (this bit `make-icon.swift`).
- `Color.quaternary`/`NSImage.withTintColor` don't exist on this target; use `Color.primary.opacity(...)` and manual NSImage tinting.
- Selftest constructs fixed dates in 2026 — keep deterministic (UTC/Berlin calendars explicitly).
- Icon: `make-icon.swift` renders the SF `alarm` symbol white-on-gradient; menu bar uses the same symbol for consistency.
