# Application lifecycle and state

[Project map](quickstart.md) · [Calendars](calendars.md) · [Reminders](reminders.md)

## Startup and ownership

[NowApp.main](../Sources/App.swift) dispatches diagnostic arguments before starting `NSApplication`.
Normal startup installs `AppDelegate`, starts as an accessory app, and enters the AppKit run loop.
The delegate owns the store, alert controller, menu controller, and settings/setup/update windows.
`applicationDidFinishLaunching` wires notification responses and delivery callbacks before calling
`AppStore.start()` and `UpdateController.start()`.

[AppStore](../Sources/AppStore.swift) is the main-actor state owner. It loads the saved profile and
reminder history, starts a shared asynchronous ICS cache load, and re-encodes preferences to
materialize migrations. `start()` installs refresh/tick timers and native-calendar change handling,
reconciles Launch at Login through ServiceManagement, initializes requested meeting detection, and
refreshes sources. Network/parser work uses nonisolated helpers; the disk cache serializes I/O on
its own queue. Native EventKit fetching is synchronous on the main actor. These boundaries matter
when adding work to the one-second tick or source refresh path.

The delegate owns the wake observer on `NSWorkspace.shared.notificationCenter`: waking refreshes
meeting activity, calendars, and updater eligibility. App timers use `AppStore.commonTimer`, which
registers in common run-loop modes so menu tracking does not suspend reminder processing. Normal
termination stops accepting results and waits for a completion enqueued behind existing cache
writes; it does not block the main thread or wait for network downloads. The termination reply is
delivered in common run-loop modes. See [App.swift](../Sources/App.swift) and
`prepareForTermination` in [AppStore.swift](../Sources/AppStore.swift).

## First-run choices and later feature guides

[SetupAssistantController](../Sources/SetupAssistant.swift) persists a draft independently of active
settings. New profiles get the three-step welcome/reminders/ready flow; an existing profile without
a setup marker is enrolled as completed. `AppStore.hadSavedProfile` is captured before launch
re-encoding, so an existing profile with no calendars is still an existing profile.

Completing setup derives effective choices from notification permission, validates meeting-detection
capability if needed, then commits once through `applyInitialSetup`. A generation check cancels
stale work after draft changes or closure. Permission denial permits completion with notification
routes disabled and preserves the draft choices for navigation. Setup's new-profile timing default
is 60 seconds; do not infer onboarding defaults solely from `AppSettings()`, whose base lead is 300
seconds. The distinction is implemented in [Models.swift](../Sources/Models.swift) and
[SetupAssistant.swift](../Sources/SetupAssistant.swift).

[FeatureGuides](../Sources/FeatureGuides.swift) separately tracks stable introduction IDs for
upgrades, including manual ZIP upgrades. Encountered IDs are recorded only after startup health
acknowledgement; pending presentation survives restarts until its window becomes visible. Add new
introductions to the catalog with stable IDs rather than renaming old entries. The
[updater lifecycle](development-and-updates.md) explains why showing an installation confirmation
must wait for that acknowledgement.

## Persistence and recovery

| State                                             | Owner and storage                                                                                                                          |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Subscriptions, native selections, settings, pause | `Persisted` in [Models.swift](../Sources/Models.swift); `local.tboch.now.state.v1` via [AppStore](../Sources/AppStore.swift)               |
| Handled reminders, snoozes, notification receipts | [Notifications.swift](../Sources/Notifications.swift) and the ledger integration in [AppStore](../Sources/AppStore.swift)                  |
| Offline ICS occurrences                           | [CalendarEventCache](../Sources/CalendarEventCache.swift), under Application Support / bundle ID / `CalendarCache-v1`                      |
| Initial setup and feature history                 | [SetupAssistant](../Sources/SetupAssistant.swift) and [FeatureGuides](../Sources/FeatureGuides.swift), each with a separate preference key |
| Update bookkeeping                                | [UpdateController](../Sources/Updater.swift), `local.tboch.now.updates.v1`                                                                 |

[StoredPreferences](../Sources/Preferences.swift) distinguishes absent data from damaged data.
Tolerant decoding can salvage valid siblings, but records recovery; loading prefers a verified
last-good backup when available. It preserves the first damaged value and the two latest failures
separately from the live payload. The persistent review notice is acknowledged through
`PersistenceStatus.reviewed`, which leaves recovery copies intact. Encoding or size failures
preserve previous saved bytes; UserDefaults provides no synchronous disk-error result, so successful
encoding is not proof of disk durability.

Legacy-domain migration in `AppStore.loadState` runs only if the current key is absent. While
profile recovery remains unreviewed, startup preserves orphan or mismatched cache files rather than
deleting possible recovery data. Exercise changes with the
[preference recovery fixtures](../scripts/preference-recovery-smoke.swift) through the
[notification smoke harness](../scripts/notification-smoke.py).

## Windows and activation

`AppDelegate.syncActivationPolicy` coordinates regular mode while a settings, setup, reminder, or
update window is visible, and accessory mode otherwise. The installed main menu supplies
responder-chain editing and window shortcuts. Finder reopen surfaces unfinished setup or Settings;
notification agenda interaction has its own reopen suppression to avoid a competing Settings window.
The fullscreen panel uses explicit focus/keyboard handling in
[AlertUI.swift](../Sources/AlertUI.swift), so changing activation policy or replacing those
shortcuts can affect background delivery even when a preview works.

Settings bind back to the store through [SettingsUI.swift](../Sources/SettingsUI.swift), with
calendar rows and shared title-filter editing in
[CalendarSettingsUI.swift](../Sources/CalendarSettingsUI.swift). Keep state transitions in the
existing store/controller methods so settings edits participate in reconciliation and persistence.

Before changing this area, read the relevant
[engineering constraints and regression notes](engineering-notes.md).
