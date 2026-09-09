# now

<img src="docs/screenshots/now-icon.png" width="96" align="right" alt="now app icon">

[![Release](https://img.shields.io/github/v/release/BoThomas/now?sort=semver)](https://github.com/BoThomas/now/releases/latest)
[![License](https://img.shields.io/github/license/BoThomas/now?style=flat)](https://github.com/BoThomas/now/blob/main/LICENSE)

Native macOS menu bar app for meeting reminders, inspired by [inyourface.app](https://inyourface.app).

Add your calendars with shared iCal links or Apple Calendar directly; `now` reminds you before meetings with a fullscreen alert or a macOS notification, with a **Join** action when it finds a meeting link.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/now-reminder.jpg" height="380" alt="Fullscreen meeting reminder with join button and countdown"></td>
    <td align="center"><img src="docs/screenshots/now-menubar.jpg" height="380" alt="Menu bar countdown and quick menu"></td>
  </tr>
</table>

## Download

<p>
  <a href="https://github.com/BoThomas/now/releases/latest"><img src="https://img.shields.io/badge/⬇_Download-Latest_Release-2478D0?style=for-the-badge" alt="Download latest release"></a>
</p>

**Requires an Apple Silicon Mac (arm64), macOS 13 or later.**

Grab `now-vX.Y.Z.zip` from the [latest release](https://github.com/BoThomas/now/releases/latest), unzip, and move `now.app` to `/Applications`.

> Release builds are signed but not notarized, so Gatekeeper warns on first launch. Do this once:
>
> - **System Settings → Privacy & Security → Open Anyway**
> - or, right-click `now.app` → **Open** → **Open**
> - or, `xattr -cr /Applications/now.app` in Terminal

## Features

**Reminders**
- Fullscreen or macOS notification reminders just before a meeting starts.
- One-click **Join** (Zoom, Meet, Teams, Webex, any meeting link).
- Keyboard shortcuts: `esc` close, `return` join, `s` snooze, `1`-`9` join a specific meeting.
- Snooze until the meeting starts or for `x` minutes (choose a default in Settings).
- Mute reminders by title or regex; muted meetings stay visible and joinable.
- Optional "don't interrupt me while I'm in a meeting" mode (no audio recorded).
- Choose between different alert sounds.

**Menu bar**
- Smart live countdown: briefly shows a meeting that just started (`-3m`), then switches to the closer upcoming start; simultaneous meetings keep their calendar colors.
- Upcoming events grouped by day: click to join, hover for details. Joining within the reminder lead window or during the meeting dismisses its reminder; opening a link earlier keeps the reminder scheduled.
- Pause reminders, refresh (⌘R), reminder preview.

**Calendars**
- Any shared iCal/ICS feed: Google, Outlook, iCloud, CalDAV, …
- **Apple Calendar**, no links needed; changes show up near-instantly.
- Recurring events, including moved and cancelled instances.
- Saved ICS calendars keep meetings and reminders available after an offline restart.
- Offline status appears in the menu; Settings shows a calendar’s last successful sync when it has a sync or cache problem.
- Per-calendar color, on/off switch, title filters.
- Hide events you've declined.

**General**
- In-app auto-updates.
- Launch at Login.
- Native Swift, no Electron.

## Offline calendars

After a successful ICS sync, `now` saves the fetched meeting occurrences locally. On restart it restores upcoming and ongoing meetings before refreshing. Offline reminders use the same pause, title-filter, and meeting-detection settings as online reminders.

Saved data covers the original fetch window (up to 14 days ahead); it cannot know about later edits or cancellations, or generate meetings beyond that window. The menu reports offline/sync problems in its existing red status row. For calendars with a sync or cache problem, Settings shows the last successful sync, whether saved data is in use, and when its coverage has expired. Healthy calendars use the shared timestamp beside Refresh. “Last synced” still means the last completed full refresh attempt.

Copies live in `~/Library/Application Support/com.thomasboch.now/CalendarCache-v1/`, with owner-only file permissions. They contain meeting details and Join links; feed URLs are represented by a fingerprint. Disabling, removing, or changing a calendar URL clears its saved copy. Storage is bounded to 16 MB per calendar and 64 MB total; storage failures are surfaced without discarding the live agenda. Handled reminders and exact snooze deadlines survive restart; ended meetings never re-alert.

## Building from source

Requires Xcode Command Line Tools with a macOS 15 or later SDK (the build uses the active SDK reported by `xcrun`; override with `SDK_PATH` if needed).

```bash
./build-app.sh
```

Builds `outputs/now.app` and `outputs/now.zip`. macOS 13+, arm64.

### Development tools

```bash
./outputs/now.app/Contents/MacOS/now --selftest            # parser unit tests
./outputs/now.app/Contents/MacOS/now --parse <url-or-file> # inspect any iCal feed
./outputs/now.app/Contents/MacOS/now --native [list]       # inspect Apple Calendar access
./outputs/now.app/Contents/MacOS/now --meeting            # inspect active meeting audio metadata
python3 scripts/calendar-cache-smoke.py                 # isolated offline restart/cache checks
./scripts/preflight.sh                                    # full build + release regression suites
./release.sh --dry-run                                     # release prerequisites (no tests/publication)
```

See [AGENTS.md](AGENTS.md) for development notes and the release workflow.

## Author & License

[Thomas Boch](https://thomasboch.com) · [GitHub](https://github.com/BoThomas) · [MIT license](LICENSE)

## Notification reminders

In Settings → Reminder, choose **Fullscreen** (the default) or **macOS notification**. You can also use notifications only during another detected meeting, or for meetings already running when now launches or your Mac wakes. Existing reminder and suppression choices are preserved until you change them.

Enabling a notification feature asks macOS for permission. If you decline, open **Notification Settings…**, then System Settings → Notifications → now and enable notifications. Settings shows current permission, offers **Preview Notification Reminder**, and includes guidance for Focus, sound, persistent alerts, and screen-sharing restrictions. macOS decides whether a banner appears; now never silently replaces a blocked notification with fullscreen.

Notifications offer **Join** when a single meeting has a link and **Snooze** when a safe duration remains. Snooze uses your existing default and safe fallback; clicking the notification opens meeting details, with a Join button when a link is available. **Hide meeting details** uses generic wording. Notifications use the macOS notification sound; the custom sound picker controls fullscreen reminders. Notifications during another meeting are silent.

An outstanding notification is replaced silently with **Meeting updated** when its title, time, location, or Join link changes. If it briefly disappears from the calendar and returns, the replacement says **Meeting reminder restored**. Dismissed or joined reminders stay handled, and snoozes keep their deadlines. Grouped reminders stay available while another member is relevant; their displayed count may be outdated, but actions use current meeting data. A notification click during startup waits for calendars to load; if the meeting is gone, now opens its menu-bar agenda.

Meeting reminders due together with identical start times share one notification with **Choose Meeting…** to open your agenda. Other start times stay separate, and single reminders keep their Join/Snooze actions. Hidden notification details also hide grouped meeting titles.

Automatic update checks run every six hours and accept newly published releases immediately. Without update notifications enabled, the update window appears once after the release has been known for 18 hours, when prepared and no reminder is open.

**Notify about new updates** sends one silent notification per new version while automatic update checks are enabled. Clicking opens the update window; manual checks still open it directly. This replaces automatic update-window popups when enabled. **Skip This Version** in the update window stops automatic offers for that release and clears its downloaded update. Manual **Check for Updates…** can show it again; newer releases are still offered automatically.

On first launch, a three-screen assistant offers startup/update preferences and notification access, followed by reminder style, timing, meeting behavior, privacy, and a preview of the selected style. Notification-dependent options remain disabled until access is enabled. It finishes by opening Settings to add calendar/event sources. New setup starts with a one-minute reminder and just-in-time snooze. Other defaults stay unchanged; closing setup saves your draft for next time. Existing users keep their settings and receive new-feature guidance when first encountering a feature, including upgrades installed manually from a ZIP. Automatic installs show it in Update Complete; manual upgrades show What’s New. Later launches and updates do not repeat guides already shown.

**Notify about calendar sync problems** is separately optional: one silent notification after five minutes of continuous failure, with details in Settings. Unchanged failures do not repeat, and Pause Reminders does not disable sync diagnostics.

now must be running to deliver reminders, including snoozes. After a restart, unhandled ongoing meetings remain eligible; handled reminders and snoozes are remembered. Obsolete Notification Center entries are removed while now runs and on its next launch.

Reminder previews use your selected lead time and snooze. Snoozing a preview dismisses the sample without scheduling another reminder or affecting real meetings. Setup’s Preview button uses an eye for fullscreen and a bell for notifications.
