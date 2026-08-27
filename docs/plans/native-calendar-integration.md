# Native Calendar Integration — Research & Plan

Goal: read the user's real calendars (Apple Calendar and everything inside it) alongside our
existing ICS-subscription support, like inyourface.app does on Mac.

## Research findings

### 1. What "native integration" on macOS actually is

In Your Face's Mac app reads calendars via **EventKit** — the system framework behind
Calendar.app. Their own help docs ("Adding a Google, Exchange, or Yahoo calendar") tell Mac
users to add those accounts **to Calendar.app**; the app then sees them through EventKit.
Their *direct* Google/Microsoft API connections are a separate, much heavier path (OAuth apps,
verification, privacy policies — Google's Calendar scopes are *restricted*, requiring Google's
app verification / annual security assessment; not practical for an indie app).

**Answer to "are we limited to Apple Calendar?"** — No. EventKit exposes every calendar
configured in Calendar.app / Internet Accounts:

| Source | Visible via EventKit? |
|---|---|
| iCloud | ✅ |
| Google (added to Calendar.app) | ✅ (CalDAV source) |
| Exchange / Outlook / Office 365 | ✅ |
| Yahoo, generic CalDAV | ✅ |
| Local "On My Mac" | ✅ |
| Subscribed (ICS) calendars in Calendar.app | ✅ (read-only) |
| Birthdays | ✅ but should be excluded from our picker |
| Direct Google/Microsoft API | ❌ not via EventKit — separate OAuth integration (skip for now) |

So one integration (EventKit) covers ~everything users care about. Google calendar events
synced via Calendar.app include the Zoom/Meet/Teams link in location/notes, so our existing
`LinkExtractor` handles join-link detection unchanged.

### 2. Permission model (we target macOS 13+, so both paths needed)

Per Apple TN3153 + the EventKit docs:

- **macOS 14+ (Sonoma):** reading events requires **full access**: `requestFullAccessToEvents()`
  + Info.plist key `NSCalendarsFullAccessUsageDescription`. There is no read-only tier.
  ⚠️ The old `requestAccess(to: .event)`, when called on macOS 14+ (built with a modern SDK),
  grants **write-only** and can never read — we must branch with
  `if #available(macOS 14.0, *)`.
- **macOS 13:** `requestAccess(to: .event)` + Info.plist key `NSCalendarsUsageDescription`.
- Ship **both** plist keys (14+ falls back to the legacy key if the new one is missing; the
  legacy key is required by older systems or the app crashes).
- Check state with `EKEventStore.authorizationStatus(for: .event)`; handle `.denied` with a
  "enable in System Settings → Privacy & Security → Calendars" hint.
- **Entitlement** `com.apple.security.personal-information.calendars`: strictly required only
  for *sandboxed* apps (we're unsandboxed), but harmless and future-proofs us (newer macOS
  versions have tightened TCC prompting policy around it). Add it.
- UX: request permission **only when the user enables a native calendar** in settings — not at
  app launch.

### 3. Hard-won-knowledge-grade gotchas found during research

- **TCC + ad-hoc signing**: TCC grants are keyed to the code signature's *designated
  requirement*. Ad-hoc signing pins the DR to the binary's cdhash → **every rebuild/release
  invalidates the calendar grant** and re-prompts the user. Mitigations: (a) sign release
  builds with a stable self-signed code-signing identity (cert leaf hash anchors the DR — no
  $99 account needed), (b) real Developer ID + notarization eventually, (c) document
  `tccutil reset Calendars com.thomasboch.now` for stuck states. At minimum: note the
  re-grant-per-release behavior in the README; decide on stable signing before or shortly
  after shipping this feature.
- **One `EKEventStore` instance only**: creating a second instance has caused
  `calendars(for:)`/`calendarsForEntityType` to return nothing on recent macOS (radar-verified
  behavior in the field). Keep a single long-lived store.
- **Recurring events for free**: `events(matching:)` with
  `predicateForEvents(withStart:end:calendars:)` materializes **each occurrence** as its own
  `EKEvent` (shared `eventIdentifier`, distinct `startDate`; detached/RECURRENCE-ID overrides
  come through with the changed start). This replaces our RRULE expander for the native path
  and fits `MeetingEvent.id = (calendarID, uid, start)` exactly.
- **Conference links: no public API.** `EKEvent` has no public conference/`CONFERENCE`
  property (only a private one + the `EKVirtualConferenceProvider` extension API, which is for
  *providing* links, not reading). Community-verified reality: the link lives in
  `event.url`, `event.location`, or `event.notes` — exactly what `LinkExtractor` already
  scans. Synthesize an ICS `ParsedEvent` from the EKEvent's fields and reuse the whole
  pipeline.
- **`EKEventStoreChanged` notification** (posted by the store instance) fires on any calendar
  change → re-fetch. Combined with our existing refresh timer + `didWakeNotification`, native
  events update near-instantly when the user moves/cancels a meeting (big win over 15-min ICS
  polling).
- **EventKit + Swift 5 concurrency**: keep the store on the main actor; do the fetch + mapping
  in a static nonisolated func like our ICS fetch does, passing plain values back.
- **CLI/TCC attribution**: running the binary directly from Terminal attributes TCC prompts to
  *Terminal*, not the app. The `--native` debug command should note this; GUI launch via
  `open`/Finder attributes correctly.

### 4. Feature gaps vs. In Your Face we consciously skip (for now)

- Direct Google/Microsoft OAuth sync (see above).
- Apple Reminders alerts (`EKReminder`, macOS 14 `NSRemindersFullAccessUsageDescription`) —
  possible later; same store, different entity type.
- Travel-time-aware reminders (not exposed by EventKit's public API).

## Plan

### Model & persistence (backward compatible)

```swift
struct NativeCalendar: Codable, Identifiable, Equatable {
    var id = UUID()              // OUR stable UUID — MeetingEvent.calendarID stays UUID
    var ekIdentifier: String     // EKCalendar.calendarIdentifier
    var name: String
    var colorHex: String = ""    // default from EKCalendar.color
    var colorIndex: Int = 0
    var isEnabled = true
}
```

- Add `var nativeCalendars: [NativeCalendar] = []` to `Persisted` with the usual defensive
  `decodeIfPresent ?? []` pattern → old state decodes untouched.
- `MeetingEvent` needs **no changes**: native events use the `NativeCalendar.id` as
  `calendarID`, `ekCalendar.title` as `calendarName`; alerts, snooze, menu, recoloring all
  keep working.

### New file `Sources/NativeCalendars.swift`

- `NativeCalendarSource` — owns the single `EKEventStore`.
  - `authorizationStatus()`, `requestAccess()` (macOS 14 branch → `requestFullAccessToEvents`,
    macOS 13 → `requestAccess(to: .event)`).
  - `availableCalendars() -> [EKCalendar]` — `calendars(for: .event)`, minus birthday
    calendars; hide subscribed ones behind a "show subscribed" default-off if trivial.
  - `fetchEvents(ekIdentifiers:now:) -> [MeetingEvent]` — window −6h…+14d (same as
    `ICSBuilder`); skip `isAllDay`, `status == .canceled`, and (behind a future setting)
    events the user declined (`attendees` → `EKParticipant.participantStatus == .declined`,
    self identified via `isCurrentUser`); map via `LinkExtractor.link(from:)` on a
    synthesized `ParsedEvent` (title/location/notes/url).
- Observe `.EKEventStoreChanged` → AppStore.throttled refresh.

### AppStore changes

- `refresh()` / `apply(results:)`: fetch enabled native calendars alongside subscriptions
  (same re-entrancy guards, same replace-on-apply semantics).
- When a persisted `ekIdentifier` no longer exists in the store (calendar/account removed),
  drop its events and surface it in settings UI (stale badge), don't crash.

### Settings UI

- New section "Apple Calendars" mirroring `calendarsSection`:
  - Not determined → "Grant Calendar Access" button (fires the TCC prompt).
  - Denied → status text + "Open System Settings" button.
  - Authorized → rows: Toggle + ColorPicker (default = calendar's own color) + expandable
    upcoming events, same grammar as `SubscriptionRow`.
- Keep the permission request user-initiated (only from this section).

### Build plumbing

- `build-app.sh`: add `-framework EventKit`; new `now.entitlements` with
  `com.apple.security.personal-information.calendars`; `codesign … --entitlements now.entitlements`.
- `Info.plist`: `NSCalendarsUsageDescription` + `NSCalendarsFullAccessUsageDescription`
  ("now shows your upcoming meetings in the menu bar. Calendar data stays on your Mac.").
- `SelfTest.swift` stays EventKit-free (must run without prompting TCC); extract the
  EKEvent→ParsedEvent mapping as a pure function over plain values if we want to unit-test it.

### Debug tool

- `now --native [now|list]`: prints authorization status, all EKCalendars, and exactly which
  events our fetch would keep in the window — the EventKit counterpart of `--parse`.
  (Print a note that CLI runs attribute TCC to Terminal.)

### Phases

1. **Phase 0 — plumbing**: entitlements, plist keys, `-framework EventKit`. Build + selftest
   green; app behaves identically when nothing native is enabled.
2. **Phase 1 — core**: model + persistence, `NativeCalendars.swift`, AppStore fetch/merge,
   `EKEventStoreChanged` refresh.
3. **Phase 2 — settings UI**: permission flow + calendar picker rows.
4. **Phase 3 — polish**: `--native` CLI, declined-event option, README (permissions, re-grant
   note, Calendar.app notification double-firing hint), cross-source duplicate note
   (ICS-subscribed-in-both-places edge case; heuristic dedupe only if it bites).

### Testing

- `./build-app.sh` + `--selftest` after every change (selftest must stay TCC-free).
- GUI smoke: launch → settings → grant → enable a calendar → events in menu bar within the
  window; edit/move an event in Calendar.app → menu updates within seconds (changed
  notification); cancel an event → disappears; ad-hoc rebuild → expect re-prompt (known).
- `tccutil reset Calendars com.thomasboch.now` between permission-flow tests.

### Decisions to make (not blockers)

- Signing: stay ad-hoc (accept re-grant per release) vs. stable self-signed identity for
  releases (recommended, cheap) vs. Developer ID later.
- Skip-declined default (probably default ON once implemented; In Your Face recommends
  filtering rejected events).
