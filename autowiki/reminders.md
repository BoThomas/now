# Reminder delivery and agenda

[Project map](quickstart.md) · [Calendar ingestion](calendars.md)

## Eligibility, routing, and acknowledgement

The one-second `AppStore.tick` in [AppStore.swift](../Sources/AppStore.swift) waits for cache
restore, reconciles notifications, processes diagnostic notices, then respects Pause before finding
due meetings. `dueForAlert` is a pure predicate: an unmuted, unhandled event is eligible from
`start - leadSeconds` until its exclusive end. An expired explicit snooze can re-fire in that same
end bound. Late launch or wake can therefore remind about an ongoing meeting; menu countdown limits
do not shorten this delivery window.

[NotificationLogic.route](../Sources/Notifications.swift) applies during-meeting policy first,
catch-up policy second (except for explicit snoozes), then the normal fullscreen/notification
choice. Suppression defers before start and marks handled at/after start. Unknown meeting activity
follows normal routing. Notification permission is checked after routing and never converts a denied
notification into fullscreen delivery.

Fullscreen groups are acknowledged before `onAlert` presents them. Notification groups are offered
through `ReminderNotificationController`, and acknowledged only when transport accepts the request.
Acceptance does not prove the person saw the banner. Ordinary notifications group events due in the
same tick by exact start date; catch-up waits for the full refresh owned by the latest launch/wake
before grouping ongoing meetings. See `CatchUpRefreshTracker`, `offerNotification`, and
`connectNotifications` in [Notifications.swift](../Sources/Notifications.swift) and
[AppStore.swift](../Sources/AppStore.swift).

## Edits and transient omissions

All event changes pass through `commitEvents`. It normalizes the list, reconciles handled/snoozed
history, applies the unmute rule, and updates open panels and accepted notifications. A meeting
unmuted after its lead window begins is marked handled and loses its snooze to avoid a surprise
alert. [TitleFilterMatcher](../Sources/TitleFilter.swift) supplies per-calendar exact or regex
matching; filtered meetings remain in lists.

`ReminderSnapshotTracker` and [ReminderLedger](../Sources/Notifications.swift) retain bookkeeping
through one successful omission from the event's own calendar. Two such omissions retire it;
unrelated commits and failed fetches do not count. This retention protects acknowledgement history,
not visible event cards: a newly accepted snapshot can remove a card immediately. Explicit source
invalidation and event expiry have their own cleanup paths in [AppStore](../Sources/AppStore.swift).

The ledger stores source-scoped hashed keys, end/start times, and snoozes without titles or URLs.
With fullscreen delivery, a changed scheduled start can re-arm the reminder; an explicit snooze or
accepted notification receipt retains ownership of its lifecycle. Notification occurrence keys
preserve the original recurrence anchor, so moved siblings remain distinct. These identities must be
kept consistent across [Models](../Sources/Models.swift), [ICSBuilder](../Sources/ICS.swift), native
mapping, and cache restoration.

## Notification actions and replacements

[ReminderNotificationController](../Sources/Notifications.swift) reserves occurrences during
asynchronous submission, adds a unique token to every request, persists receipt state before
transport submission, and rejects stale completions. Accepted receipts are reconciled separately
from fresh-delivery routing. Meeting edits use silent labeled replacements; failed replacement
intent and short-lived old-token aliases preserve action handling through races. Removing members
from a group retains its original banner text while actions resolve the remaining live meetings.

Actions enter `AppStore.handleNotificationResponse`, resolving live event keys after cold
restore/initial refresh. Missing-meeting actions fall back to the menu-bar agenda. Early agenda Join
preserves a future reminder; Join from the lead boundary until event end acknowledges it. An
explicit notification Snooze can re-arm while paused, but Pause still prevents delivery. The
[notification lifecycle fixtures](../scripts/notification-lifecycle-smoke.swift) exercise production
state through the [fake-transport harness](../scripts/notification-smoke.py).

## Fullscreen controls and menu presentation

[AlertController](../Sources/AlertUI.swift) merges real deliveries into an open panel and reconciles
edits/removals. Preview transitions are isolated: preview actions dismiss without joining,
scheduling, or writing real bookkeeping. A shared snooze is offered only when it expires before
every active card's end; “just in time” requires every active event to be unstarted.
`snoozeSchedule` revalidates at activation, and `primarySnoozePlan` resolves safe fallbacks as time
changes.

The borderless panel has an explicit key monitor, including a one-second guard against keystrokes in
flight when it takes focus. Keep its keyboard and activation behavior together with
[AppDelegate](../Sources/App.swift); ordinary SwiftUI shortcuts alone do not cover disappearing
snooze controls or background focus. Pure timing, snooze, key-action, and preview-transition cases
live in [SelfTest.swift](../Tests/NowTests/SelfTest.swift).

[MenuBarController](../Sources/MenuBar.swift) renders the agenda and countdown from store state.
`AppStore.menuBarFocus` picks the nearest eligible start, gives a future start the exact midpoint
tie, and falls back to the soonest running end when no start qualifies. Equal selected instants
group their calendar colors. Running events remain visible until end; muted events remain listed but
cannot own the countdown. The native menu updates row text while tracking and keeps Join available
while paused. See [reminder-state smoke](../scripts/reminder-state-smoke.py) for the isolated
menu/state harness.

[MeetingActivityProbe](../Sources/MeetingActivity.swift) uses CoreAudio process metadata to classify
active input owners without capturing audio. Browser inclusion is separate because process metadata
cannot identify a tab. The activity source debounces inactive snapshots;
[AppStore](../Sources/AppStore.swift) retries transient capability failures when restoring an
enabled choice. Unknown activity is deliberately fail-open. Use the production `--meeting`
diagnostic in [App.swift](../Sources/App.swift) when checking provider classification.

Before changing this area, read the relevant
[engineering constraints and regression notes](engineering-notes.md).
