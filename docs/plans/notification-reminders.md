# Notification reminders

Accepted foundation: 8 September 2026. Implemented on `feat/notification-reminders`.

## Product decisions

- Existing and new installs retain fullscreen until setup is accepted. The setup guide recommends notifications during another meeting, at launch/wake for ongoing meetings, and for new updates; sync diagnostics remain off. Existing custom reminder/suppression choices are preserved.
- Delivery: Fullscreen / macOS notification. Lead time, default snooze, title filters, and pause are shared.
- During another meeting: Remind normally / Use a notification / Suppress reminders. Existing suppression migrates unchanged. Detection remains capability-gated, browser detection opt-in, unknown activity fail-open to normal delivery. In-meeting notifications are silent. Suppression still defers before start and handles at/after start.
- Optional notifications for unhandled meetings already in progress at launch/wake. A source-scoped cutoff captures the launch/wake instant; first refresh completion collects asynchronously arriving calendars into one catch-up notification. Upcoming reminders do not wait for refresh. Meetings starting after that cutoff and ordinary refresh discoveries follow normal delivery. Snoozes retain normal delivery and their original deadline.
- A notification carries title and timing only. Hide meeting details substitutes generic wording; grouped notifications are generic in either mode. No calendar name, notes, location, or raw URL appears. Privacy changes remove previously delivered meeting notifications immediately.
- Join exists only for a single linked meeting. Snooze uses the configured choice with the existing safe fallback at action time. There is no notification-specific duration selector. Default click opens the shared meeting-detail popover, with Join for linked meetings and a meeting selector for grouped notifications; closing handles the reminder. Stale actions resolve only current, unmuted, unended occurrences and never launch a saved URL. A snooze with no safe duration opens current meeting details; a notification with no remaining valid meetings falls back to the agenda.
- Notification sound uses the system notification sound, controlled by both now's Play reminder sound choice and macOS. The custom sound picker applies to fullscreen.
- Sync-problem notifications are a separate opt-in: one silent grouped notification after five minutes of continuous failure; affected sources reset independently on recovery. No unchanged repeats or recovery notifications. Pause Reminders does not pause sync diagnostics. Includes missing native Calendar access, excludes degraded-feed warnings and cache-storage warnings. Details open Settings. Failure-episode state survives restart.

## Permission and setup

Request alert/sound permission only from an explicit notification feature choice or Enable Notifications. No launch prompt, badges, push registration, server, or new Calendar/microphone permission.

Settings distinguishes not requested, allowed, denied, and allowed with onscreen alerts disabled. Provide Enable Notifications, Preview Notification Reminder, and Notification Settings. The meeting preview replaces the separate generic test button. Denial keeps user intent and shows status in Settings and the menu, with an explicit option to use fullscreen. Never silently fall back from notifications to fullscreen. Blocked due reminders remain eligible while running, with bounded retries; expired reminders never return.

Refresh permission on activation, wake, before submission, and periodically while running. The OS owns presentation, sound, Focus, lock-screen and screen-sharing restrictions. Submission success is not evidence that a banner was displayed. Do not bypass Focus with time-sensitive/critical alerts. Requesting again after denial does not reopen Apple's permission prompt.

macOS has no public per-app notification-settings opening API. Use the Notifications pane URL with a bundle-ID hint; if launching it fails open System Settings. Always show the manual path: System Settings → Notifications → now. Guidance covers persistent alerts (Alerts on older releases), sound, Focus, and locked/shared screens. Direct pane targeting requires live OS testing and may vary by macOS version.

## State and concurrency

Pure eligibility remains `AppStore.dueForAlert`. `NotificationLogic.route` chooses the channel without consulting permission. Fullscreen delivery, suppression, and successfully submitted notifications become handled. Acknowledgements and exact snooze deadlines now persist separately from settings/cache, including fullscreen acknowledgements. This is at-most-once delivery bookkeeping, not proof of user interaction or visible OS presentation.

The bounded reminder ledger stores hashed occurrence IDs, source UUID, end time, snooze deadline and omission count, without meeting content or feed tokens. Restore applies live sources; disable/removal/URL replacement clears affected history. A missing event survives one successful snapshot from its own source, retires after two, and resets misses on return. Ended records expire. Records waiting for another source's asynchronous restore are not prematurely removed.

`ReminderNotificationController` owns injectable notification transport, in-flight reservations, unique tokens per submission attempt, retry delays, and notification receipts. Late cancelled completions remove only their own token and cannot acknowledge or delete replacements. Receipts contain hashed occurrence identities, content fingerprints, expiry and category; text is stripped from disk and no Join URL is stored. Notification action payloads contain an opaque token only. Actions arriving during cold restore/refresh wait for current calendar data.

Remove obsolete notifications on pause, mute, source changes, event changes/expiry, explicit joins, snooze, and delivery/privacy changes. Submission failures are visible and retryable. App exit stops reminder scheduling as before; cleanup of already delivered notifications resumes when now runs again. Snoozes overdue on relaunch fire only if their meeting is still running.

## Validation

- Signed `./build-app.sh --require-identity` and `--selftest`.
- `python3 scripts/notification-smoke.py`: fake Notification Center transport, real AppStore scheduling, synthetic sources and isolated preferences; no Calendar queries or fullscreen windows.
- `python3 scripts/notification-smoke.py --gui`: optional signed, isolated Settings/Notification Center preview with synthetic meetings. Requires the development signing identity; never uses installed now's preferences or calendars.
- Existing reminder-state and calendar-cache smoke suites protect source retention, pause, shared snooze, and restart behavior.
- Manual checks: first grant/denial, Settings recovery, foreground/background banners, notification actions, Focus/alert style, privacy, and narrow Settings layout. Do not infer actual banner presentation from an accepted request.

Apple references:
- https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications
- https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types
- https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions
- https://support.apple.com/guide/mac-help/change-notifications-settings-on-mac-mchl205da693/mac

## Verification status (8 September 2026)

The regular signed app was installed in Applications and notification permission/delivery were confirmed by the user. A separately signed temporary preview's authorization failure was not representative. Build, selftest, transport/AppStore smoke and the existing updater install/rollback smoke suites cover the implementation; macOS remains responsible for visible presentation.

## User trial and Settings refinement

The user installed the regular signed now.app in Applications and confirmed notification setup and delivery work (8 September 2026). An Apple Developer membership is not required for this verified setup; the isolated temporary preview failure was not representative. User requested removal of routine explanatory/status text, a question-mark help popover, and a meeting notification preview next to fullscreen. Both previews share the same dummy event; notification preview respects privacy and cannot act on a real meeting. Repeated explicit tests replace their previous receipt and use a fresh request ID, without adding timestamps to visible content. Real reminder deduplication is unchanged.

## Update notifications and reusable setup

- **Notify about new updates** is a separate preference, effective only while automatic checks are enabled. Eligible releases obey the same 24-hour age gate. Notify silently once per version; clicking opens the existing update window. Manual checks still answer with a window. When update notifications are selected, automatic three-day window escalation is disabled even if macOS permission is blocked. Menu/About indicators remain.
- `UpdateState.lastNotificationVersion` records accepted delivery separately from the existing window/failed-install marker. No notification for an installed/skipped/already-shown version. Expire old receipts, remove withdrawn/superseded updates after a successful check, and remove notices when the setting is disabled. Failed checks do not prove withdrawal. Update notifications work independently of reminder pause and calendar refresh.
- `FeatureGuideCatalog` contains stable introduction IDs with typed content. Add future informational entries directly; add an interactive content case for a feature that needs configuration. Never rename existing IDs. These guides render in update success; initial setup has its own sequential assistant.
- `FeatureGuideState` unions the catalog IDs encountered after a health-acknowledged launch. An updater success shows only IDs absent from that user's prior history, so skipping releases collects multiple introductions, subsequent updates do not repeat them, and downgrades do not erase history. A legacy profile without history receives the new guide once. No guessed release version or recurring version comparison is needed.
- New profiles launch the setup assistant before adding sources. Existing profiles (including those with no calendars) never enter it automatically. Update installs retain new-feature guidance in their success dialog, without inline Settings cards. Closing or keeping current settings does not nag on future updates.
- Setup requests authorization only after **Enable Notifications…**. No settings change until permission and any selected meeting-detection capability succeed; denial or cancellation preserves the prior configuration. A denied grant shows the macOS Settings path and a check-permission action. Later system revocation preserves enabled preferences and existing blocked-status behavior.
- Guide history is never consumed before the updater's startup health acknowledgement. Its existing pending-install marker, failure suppression, signature gate, and rollback transaction remain intact.

The Settings shortcut for reopening recommended setup was removed at the user’s request. Visual-only previews use `NOW_NOTIFICATION_RENDER_DIR` with the smoke harness’s fake transport; they never construct the system notification transport, register categories, request authorization, or send notifications.

## First-launch assistant

`SetupAssistantState.Step` defines three screens: welcome (launch at login, automatic update checks, notification permission), combined reminders (style with an adjacent style-aware Preview, timing, during-meeting behavior, privacy), and a brief celebration that opens source Settings. Removed controls retain their existing defaults and remain available in Settings. No Calendar permission is requested during setup.

A separate `local.tboch.now.initial-setup.v1` payload stores the draft, current step, and completion marker. Profile existence is captured before AppStore re-encodes defaults, checking both current and legacy domains. Existing profiles are enrolled completed. Closing an unfinished assistant preserves progress; reopening Settings/Finder resumes it. Drafts from the five-screen prototype migrate context to reminders and notification access to welcome.

Permission gates effective choices without erasing the draft: unavailable notification options are disabled, regular reminders use fullscreen, and notification-dependent defaults become inactive. Going back and granting access restores availability and the selected draft choices. Final completion rechecks permission without prompting and validates any enabled meeting detection before committing. Only visible controls and notification defaults are applied; snooze, sound, browser detection, and unrelated general preferences stay unchanged (including normal snooze compatibility adjustment if lead time becomes zero). Permission is requested only by the first screen's explicit Enable button. Preview uses the selected style and draft privacy settings. No local settings reset is part of implementation or preview tests.

Previews share a settings-driven sample event: its start is the configured lead time from now, and its duration accommodates the configured snooze. Fullscreen and notification preview snoozes only dismiss the sample; they never schedule another reminder or touch real reminder ledgers or URLs. Setup defaults to 60 seconds before start and just-in-time snooze; existing users’ saved timing is unchanged. The setup preview icon follows its selected style (eye/bell).

Launch/wake catch-up offers Use normal reminder style, Use notification, and Skip reminder. Existing checkbox values migrate unchanged (off → normal, on → notification). Skip marks catch-up occurrences handled, while explicit snoozes and ordinary reminders keep their normal route. During-another-meeting rules retain precedence.
