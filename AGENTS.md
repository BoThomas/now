# AGENTS.md — now

Native macOS menu bar app for meeting reminders (plain Swift files in `Sources/`, no Xcode project). See README.md for user-facing docs.

## Project layout

- `Sources/Helpers.swift` — `Palette` (colors) and `Fmt` (formatting) helpers.
- `Sources/Models.swift` — `CalendarSubscription`, `NativeCalendar`, `AppSettings`, `Persisted`, `MeetingEvent`.
- `Sources/ICS.swift` — `ICSParser`, `RRULE`/`RRULEExpander`, `LinkExtractor`, `ICSBuilder` (pure Foundation, no UI).
- `Sources/NativeCalendars.swift` — `NativeCalendarSource` (EventKit: single `EKEventStore`, permission, fetch, EKEvent→`MeetingEvent` mapping).
- `Sources/AppStore.swift` — state, persistence, fetching, reminder scheduling (`@MainActor` ObservableObject).
- `Sources/AlertUI.swift` — `AlertPanel`/`AlertController` + fullscreen SwiftUI views.
- `Sources/MenuBar.swift` — `MenuBarController` (NSStatusItem + NSMenu).
- `Sources/SettingsUI.swift` — settings window views.
- `Sources/App.swift` — `AppDelegate`, `@main` entry, `--parse` CLI.
- `Sources/SelfTest.swift` — selftest.
- `build-app.sh` — builds `outputs/now.app` with `swiftc` (compiles `Sources/*.swift`, Swift 5 mode, target `arm64-apple-macos13.0`, SDK `MacOSX15.4.sdk`), generates icons via `make-icon.swift` (root, separate tool — do NOT move it into Sources/), signs with the self-signed "now Developer" identity (ad-hoc fallback) + `now.entitlements`, zips.
- `release.sh` — release pipeline (see Releasing below). `CHANGELOG.md` is generated/maintained by it.
- `Info.plist` — `LSUIElement=true` (menu bar only, no Dock icon), bundle ID `com.thomasboch.now`.
- Persistence: UserDefaults key `local.tboch.now.state.v1` (custom key, versioned), JSON of subscriptions + settings. Legacy `local.tboch.now` domain is migrated on first read (old bundle ID).

## Commands

```bash
./build-app.sh                                    # build outputs/now.app (+zip)
./outputs/now.app/Contents/MacOS/now --selftest   # parser unit test, exit 0/1
./outputs/now.app/Contents/MacOS/now --parse <url-or-ics-file>
./outputs/now.app/Contents/MacOS/now --native [list]  # EventKit: auth status, calendars, kept events
./release.sh --dry-run                            # check release prerequisites
```

Always run the build + selftest after changes. A GUI smoke test (launch, check it's alive after ~4s, kill) is good for changes touching app startup.

## Releasing

`./release.sh` is the agent-friendly release pipeline: version bump (patch/minor/major or explicit `X.Y.Z`), prepends a CHANGELOG.md entry, sets Info.plist version/build, builds + selftests, commits, tags `vX.Y.Z`, pushes, and creates a GitHub release with `now-vX.Y.Z.zip` attached.

- `./release.sh patch --notes $'- Fixed X\n- Added Y' --yes`
- Flags: `--dry-run` (plan only), `--repo owner/name` (default `BoThomas/now`), `--yes` (skip confirm). Requires a clean tree and an authenticated `gh`.
- README's Download section links to `/releases/latest`, so it always points at the newest release — no README edits needed per release.
- Repo topics are already set on `BoThomas/now` — nothing to do per release.

## Debug tool: `--parse`

Prints exactly what the app would extract from any feed — use this first when "events are missing":

- fetches the URL (or reads a local file), runs the real parser, prints RAW VEVENT count, all-day count, the ±window, per-event start/allDay/rrule/status, then the final kept events with detected links.
- Example (public Google holiday calendar): `now --parse "https://calendar.google.com/calendar/ical/de.german%23holiday%40group.v.calendar.google.com/public/basic.ics"` — note: all-day feed, so expect RAW > 0 / PARSED 0
- If RAW count is 0 → line-ending/encoding problem at parse level; if RAW > 0 but PARSED 0 → window/filter issue (past events, all-day only).

## Debug tool: `--native`

The EventKit counterpart of `--parse`: prints authorization status, every EKCalendar (source, title, color), and exactly which events a fetch would keep in the −6h…+14d window (`--native list` = calendars only). Note: permission requested from a CLI run is attributed to the *terminal app*, not `now` — grant via the GUI (launch now.app → Settings → Apple Calendar) for testing the app's own grant. `tccutil reset Calendars com.thomasboch.now` resets a stuck app grant.

## Code signing (TCC stability)

TCC grants (Calendar permission) are keyed to the code signature's *designated requirement*. Ad-hoc signing anchors the DR to the binary's cdhash → every rebuild = "a different app" = re-prompt. So release/dev builds are signed with a self-signed identity **"now Developer"** (RSA-2048, codeSigning EKU, valid to 2036) whose certificate hash anchors the DR instead — grants survive rebuilds and release updates.

- The identity lives in the **login keychain** of the dev machine; `build-app.sh` uses it when present and falls back to ad-hoc with a warning.
- Backup: the `.p12` (with its password) lives **only** in the password manager (1Password/Bitwarden file attachment) — there is deliberately no on-disk copy. Key material must NEVER be committed (`.gitignore` blocks `*.p12/*.pem/*.key`).
- Restore on a new machine:
  ```bash
  security import now-codesign-backup.p12 -k ~/Library/Keychains/login.keychain-db -P '<password>' -T /usr/bin/codesign
  security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db <cert.pem-from-p12>   # make find-identity see it as valid
  ```
  Without the `add-trusted-cert` step `security find-identity -v -p codesigning` reports "0 valid identities" (untrusted self-signed) and `codesign -s` won't find it.
- After expiry (2036) regenerate a cert the same way — every machine then re-grants once.
- Self-signed ≠ notarized: Gatekeeper still warns on other machines (README covers that). A real Developer ID + notarization remains the eventual proper fix.

## Hard-won knowledge (don't regress)

- **CRLF feeds**: many servers send `\r\n`. In Swift, CR+LF is a single grapheme cluster, so `split(separator: "\n")` (Character) does NOT split CRLF lines — the whole file becomes one line and parsing silently yields 0 events. `ICSParser.unfolded` normalizes `\r\n`/`\r` → `\n` first. The selftest includes a CRLF variant for regression.
- **Standard shortcuts need a main menu**: the app is `.accessory`/LSUIElement, so there was no menu bar and Cmd+V/Cmd+A beeper-failed. `AppDelegate.setupMainMenu()` installs a minimal main menu — keep it: "now" app menu (Quit ⌘Q → custom `handleQuitRequest()`: confirm when Settings is key, close a showing alert, else terminate), Edit (copy/paste via responder chain), and Window (Close ⌘W / Minimize ⌘M — these are *menu* key equivalents, NOT built-in window behaviors; without the items the shortcuts do nothing). The menu bar only shows our menus while the app is ACTIVE **and** `.regular`: an `.accessory` app activating with a window (even `makeKeyAndOrderFront` before `activate`) often keeps the previous app's menu bar on screen. Policy is centralized in `AppDelegate.syncActivationPolicy()` — `.regular` while Settings or the alert is visible, `.accessory` otherwise — wired via `windowWillClose` and `AlertController.policyDidChange`; never set the policy anywhere else.
- **Pasteboard vs. menu commands**: standard text shortcuts are responder-chain actions; menu-bar-only apps must provide the menu explicitly.
- **Meeting links** come from (in priority order): `CONFERENCE`/`X-GOOGLE-CONFERENCE`/MS props → `URL:` property → known hosts in LOCATION → known hosts in DESCRIPTION → any http(s) URL. Some uses the `URL:` property.
- **Feed line endings/folding**: RFC 5545 continuation lines (leading space/tab) are unfolded before parsing; text values are unescaped (`\n`, `\,`, `\;`, `\\`).
- **Window**: events kept if start within −6h…+14d of fetch time; all-day and `STATUS:CANCELLED` events are always skipped. If a user's events "don't show up," check they're actually in the future.
- **Late visibility**: started meetings stay in the menu bar/menu with a negative countdown (`-3m`) per setting `lateMinutes` (−1 = hide once started, 0 = until end, N = N min after start). Running events take precedence over future ones in the menu bar label.
- **Snooze re-fire**: a snoozed alert re-fires when the snooze expires as long as `now <= event.end` — including after the meeting has started. Only a snooze ending after the meeting end stays dismissed.
- **Transient event omissions**: a fetch can briefly miss an event (`.EKEventStoreChanged` mid-CalDAV-sync, one bad/empty ICS response). `commitEvents` therefore prunes `alerted`/`snoozed` only for ids missing from **two consecutive commits** (`previousCommitIDs`) — a single miss keeps bookkeeping so a reappearing event doesn't re-alert or lose its snooze. Lagging bookkeeping is inert (`tick()` iterates `events` only).
- **Auth revocation**: `appBecameActive` re-fetches on ANY EventKit status change — a deny must clear native events immediately (fetchNativeEvents' unauthorized branch wipes them), not at the next 15-min refresh.
- **EventKit native calendars** (see `docs/plans/native-calendar-integration.md` for the full research):
  - **One `EKEventStore` only** (`NativeCalendarSource.store`) — a second instance makes `calendars(for:)` return nothing on recent macOS. Never create another one; the `--native` CLI makes its own because no AppStore exists in that path.
  - **Permission split**: macOS 14+ needs `requestFullAccessToEvents()` (no read-only tier); the legacy `requestAccess(to: .event)` on 14+ grants **write-only**. Both plist keys ship (`NSCalendarsFullAccessUsageDescription` + `NSCalendarsUsageDescription`); entitlement `com.apple.security.personal-information.calendars` via `now.entitlements`. Prompt only from the settings UI ("Grant Access…"), never at launch; `EKEventStore()` alone is TCC-silent.
  - **TCC + signing**: TCC grants key to the signature's designated requirement — solved with the self-signed "now Developer" identity (see *Code signing* above); ad-hoc fallback builds re-prompt per build (known). Status re-checked on `didBecomeActive` so granting via System Settings lights the UI up.
  - **Recurring events**: `events(matching:)` materializes each occurrence with shared `eventIdentifier`, distinct `startDate` → no RRULE code on the native path; fits `MeetingEvent.id` directly. No public conference API: synthesize a `ParsedEvent` from title/location/notes/url and reuse `LinkExtractor`.
  - `.EKEventStoreChanged` (debounced 1.5 s) → `fetchNativeEvents()`; native and ICS events are merged in `commitEvents` — `knownNativeCalendarIDs` distinguishes them by `calendarID` (our stable UUID, never the EK identifier).
  - Selftest stays EventKit-free: `NativeCalendarSource.parsedEvent(…)` is the pure mapping over plain values; only it is unit-tested.
- **Colors**: per-subscription `colorHex` in settings (ColorPicker). Changing a color re-tints already-fetched events in place (`recolorEvents`). New subscriptions get a rotating palette default.
- **Menu bar dropdown layout**: event rows use `attributedTitle` with a right-aligned tab stop (`NSTextTab(textAlignment: .right, location:)` — the `textEndpoint:` init does NOT exist in this SDK) so titles align regardless of time width; no explicit foreground color so selection highlighting stays native. Day section headers are disabled items with `secondaryLabelColor` + small semibold font. Long titles are cut via `Fmt.ellipsized` (48 chars); hover shows a rich multi-line tooltip (title/when/location/notes via `tooltipText`, notes word-wrapped by `Fmt.wrapped`; no join-link row, and location/notes lines that are nothing but the join link are suppressed — `isJustJoinLink`). Refresh has ⌘R (`keyEquivalent: "r"` — works while the menu is open).
- **Reminder location row**: shows `LOCATION` if set, else falls back to `LinkExtractor.providerName(for:)` ("Zoom", "Google Meet", …) so link-only meetings (URL/DESCRIPTION, e.g. `us02web.zoom.us/j/…?pwd=…`) still show a pin-label.
- **Concurrency**: AppKit/MainActor via `@MainActor` on AppStore; fetches run through static nonisolated funcs + task groups. Swift 5 language mode — keep new code compatible.
- `NSWorkspace.didWakeNotification` triggers a refresh (timers stall during sleep).
- Alert window: borderless NSPanel, `.screenSaver` level, `canJoinAllSpaces`, key-monitor handles esc/return/s. ALL three live in `AlertController.installMonitor()` — never rely on SwiftUI `keyboardShortcut` alone there: the snooze button is conditionally rendered, and a shortcut attached to a vanishing view silently dies (that's why "s" used to beep for started meetings). "s" snoozes while any event is still running (`end > now`), matching the button + hint; ⌘W/⌘M are swallowed silently (they'd beep on the borderless panel). **Keyboard focus**: a timer-fired panel can't take focus as a background `.accessory` app (macOS ignores `activate()` without user interaction → keystrokes invisibly went to the app behind the overlay). `present()`/`closePanel()` therefore call `policyDidChange`, which runs `AppDelegate.syncActivationPolicy()` → app goes `.regular` while the alert is up (Dock icon + our menu bar — the accepted cost) and back to `.accessory` on close (unless Settings is still visible).

## Gotchas

- `swiftc` expression type-check blowups: break long `CGRect(...)` expressions with mixed Int/CGFloat math into sub-expressions (this bit `make-icon.swift`).
- `Color.quaternary`/`NSImage.withTintColor` don't exist on this target; use `Color.primary.opacity(...)` and manual NSImage tinting.
- Selftest constructs fixed dates in 2026 — keep deterministic (UTC/Berlin calendars explicitly).
- Icon: `make-icon.swift` renders the SF `alarm` symbol white-on-gradient; menu bar uses the same symbol for consistency.
