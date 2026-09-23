# A quick guide to now

[← Back to the README](../README.md)

## Start here

1. **Choose your reminders.** The setup assistant walks you through style and timing.
2. **Add calendars.** Paste an ICS link in Settings, or grant Apple Calendar access and pick your
   calendars.
3. **Try Preview.** Then leave now running in your menu bar.

New setups remind you one minute before a meeting. Upgrading keeps your existing choices.

## Choose a reminder style

Open **Settings → Reminder**.

| Style            | What you get                                              |
| ---------------- | --------------------------------------------------------- |
| **Fullscreen**   | A large reminder with meeting details and a Join button.  |
| **Notification** | A macOS notification with Join and Snooze when available. |

Meetings starting together can share a notification. **Choose Meeting…** opens your agenda.

With two displays, fullscreen reminders cover the one you are working on. **Show on → Main Display**
pins them to your main display instead — handy when a large monitor is your home base.

You can also use notifications only during another meeting, or for meetings already running when
your Mac wakes. **Hide meeting details** keeps notification text private.

## Multiple reminder times

In **Settings → Reminder**, use **+** below the **Remind me** rows to add up to three times,
including **Just in time**. Choose a time to activate a new row; duplicate times are combined. **−**
in front of a row removes an extra time. The **ⓘ** button explains how multiple reminders work.
Setup keeps one timing choice.

- **Snooze** silences this meeting until your chosen time. Earlier reminder times are skipped; later
  times remain active. An existing Snooze survives removing a reminder time from Settings.
- **Join** makes outstanding reminders conditional: they appear only if enabled meeting detection
  confirms you are not in a meeting. With detection off or unavailable, they are skipped. This
  detects activity, not attendance in a particular meeting. The latest Join or Snooze action wins.
- **Close** dismisses only the current reminder; later reminders remain active.
- Several overdue reminders are combined. An already open fullscreen card absorbs further reminders
  for that meeting without another sound or focus change.

Newly added times are not applied retroactively. Existing reminders still catch up after sleep. When
a meeting moves, its Snooze shifts by the same amount and its previous Join state is cleared. If
moving earlier makes the Snooze overdue, it catches up once while the meeting is still active. These
Join and Snooze rules also apply when you configure only one reminder.

Click a meeting notification's body to open its details. **Snooze** there uses your configured
Snooze preference and works even without a Join link. In a detail view with several meetings, it
applies to the selected meeting. Group notifications offering **Choose Meeting…** open the agenda.

## Joining meetings

Links that use a meeting app's own protocol — for example `zoomus://` from a Zoom calendar entry —
open the app directly, without a browser detour. If the app is not installed, the link falls back to
its browser page.

**Always open join links in the meeting app, if installed** in **Settings → General** also opens
ordinary Zoom and Microsoft Teams links in the installed app. It is off by default; without the app,
links open in your browser as before.

## Everyday controls

| To…                      | Use…                                                          |
| ------------------------ | ------------------------------------------------------------- |
| Join a meeting           | **Join**, or click its agenda entry.                          |
| Remind yourself later    | **Snooze** until the start or for a chosen duration.          |
| Silence certain meetings | The calendar’s **Muted meetings** rules in Settings.          |
| Take a break             | **Pause Reminders** in the menu. Your agenda stays available. |
| Refresh calendars        | **Refresh Calendars**, or **⌘R** while the menu is open.      |

Snoozes work after a meeting starts, but never after it ends. Preview actions only dismiss the
sample.

<details>
<summary><strong>Fullscreen keyboard shortcuts</strong></summary>

| Key    | Action                                            |
| ------ | ------------------------------------------------- |
| Return | Join the meeting, or activate the focused button. |
| S      | Snooze.                                           |
| Escape | Close the reminder.                               |
| 1–9    | Join a numbered meeting.                          |

</details>

## Notifications not showing?

- Make sure **now is running** and reminders aren’t paused.
- Check **System Settings → Notifications → now** allows notifications.
- Check **Focus** and screen-sharing settings aren’t hiding them.

Choose **Persistent** alerts in macOS if you want notifications to stay until you act. Use **Preview
Notification Reminder** in now to try your settings.

## Offline calendars and saved data

After a successful sync, saved ICS meetings can still remind you offline. They cover up to 14 days
ahead; later edits and cancellations need a fresh sync.

Snoozes and dismissed reminders survive a restart. If a calendar cannot sync, now shows the problem
in its menu and Settings.

<details>
<summary><strong>Seeing “Saved data needs attention”?</strong></summary>

Check your calendars and preferences, then mark the notice **Reviewed**. now preserves recovery
copies if saved settings are damaged.

</details>

## Updates and new features

Use **Check for Updates…** from the menu. Automatic checks and update notifications are optional in
Settings.

The update window's **What's New** lists everything since the version you are running — if you skip
several versions, each release's notes appear under its own version heading, newest first.

Updates keep your calendars and preferences. New features get a short introduction once. **Skip This
Version** skips an automatic offer; a manual check can show it again.

### Installed with Homebrew?

If Homebrew installed now (`brew install --cask BoThomas/tap/now`), the app leaves updating to
Homebrew: **Check for Updates…** still discovers and presents new versions, but instead of
installing itself it shows a copyable `brew upgrade --cask BoThomas/tap/now` command. Run it in
Terminal, then relaunch now — the running copy keeps the old version until then.

The app detects this automatically from Homebrew's install records. If you move the app out of the
Homebrew-managed location, it falls back to updating itself.
