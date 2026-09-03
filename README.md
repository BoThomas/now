# now

<img src="docs/screenshots/now-icon.png" width="96" align="right" alt="now app icon">

[![Release](https://img.shields.io/github/v/release/BoThomas/now?sort=semver)](https://github.com/BoThomas/now/releases/latest)
[![License](https://img.shields.io/github/license/BoThomas/now?style=flat)](https://github.com/BoThomas/now/blob/main/LICENSE)

Native macOS menu bar app for meeting reminders, inspired by [inyourface.app](https://inyourface.app).

Add your calendars with shared iCal links or Apple Calendar directly; `now` takes over the whole screen right before a meeting starts, with a big one-click **Join** button when it finds a meeting link.

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

Grab `now-vX.Y.Z.zip` from the [latest release](https://github.com/BoThomas/now/releases/latest), unzip, and move `now.app` to `/Applications`.

> Release builds are signed but not notarized, so Gatekeeper warns on first launch. Do this once:
>
> - **System Settings → Privacy & Security → Open Anyway**
> - or, right-click `now.app` → **Open** → **Open**
> - or, `xattr -cr /Applications/now.app` in Terminal

## Features

**Reminders**
- Fullscreen reminder just before a meeting starts.
- One-click **Join** (Zoom, Meet, Teams, Webex, any meeting link).
- Keyboard shortcuts: `esc` close, `return` join, `s` snooze, `1`-`9` join a specific meeting.
- Mute reminders by title or regex; muted meetings stay visible and joinable.
- Optional "don't interrupt me while I'm in a meeting" mode (no audio recorded).
- Choose between different alert sounds.

**Menu bar**
- Live countdown to the next meeting, including late ones (`-3m`).
- Upcoming events grouped by day: click to join, hover for details.
- Pause reminders, refresh (⌘R), reminder preview.

**Calendars**
- Any shared iCal/ICS feed: Google, Outlook, iCloud, CalDAV, …
- **Apple Calendar**, no links needed; changes show up near-instantly.
- Recurring events, including moved and cancelled instances.
- Per-calendar color, on/off switch, title filters.
- Hide events you've declined.

**General**
- In-app auto-updates.
- Launch at Login.
- Native Swift, no Electron.

</details>

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
./release.sh --dry-run                                     # release pipeline check
```

See [AGENTS.md](AGENTS.md) for development notes and the release workflow.

## Author & License

[Thomas Boch](https://thomasboch.com) · [GitHub](https://github.com/BoThomas) · [MIT license](LICENSE)
