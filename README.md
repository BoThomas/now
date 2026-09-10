# now

<img src="docs/images/now-icon.png" width="96" align="right" alt="now app icon">

[![Release](https://img.shields.io/github/v/release/BoThomas/now?sort=semver)](https://github.com/BoThomas/now/releases/latest)
[![License](https://img.shields.io/github/license/BoThomas/now?style=flat)](https://github.com/BoThomas/now/blob/main/LICENSE)

Native macOS meeting reminders that live in your menu bar.

Connect Apple Calendar or an iCal/ICS feed. Get a fullscreen reminder or macOS notification, then join your meeting with a click.

![now features: fullscreen reminders, macOS notifications, a menu bar countdown, Join and Snooze, Apple Calendar and ICS, and offline reminders](docs/images/collage.jpg)

## Download

<p>
  <a href="https://github.com/BoThomas/now/releases/latest"><img src="https://img.shields.io/badge/⬇_Download-Latest_Release-2478D0?style=for-the-badge" alt="Download latest release"></a>
</p>

**Apple Silicon · macOS 13 or later**

Grab `now-vX.Y.Z.zip` from the [latest release](https://github.com/BoThomas/now/releases/latest), unzip, and move `now.app` to `/Applications`.

> Release builds are signed but not notarized. If macOS blocks the first launch, use one of these options:
>
> - **System Settings → Privacy & Security → Open Anyway** ([Apple’s instructions](https://support.apple.com/102445)).
> - Or, right-click `now.app` → **Open** → **Open** (if available on your macOS version).
> - Or, run `xattr -dr com.apple.quarantine /Applications/now.app` in Terminal, then open the app again.

## Get started

1. Open now and choose your reminder style and timing in the setup assistant.
2. In Settings, add an iCal/ICS link or grant Apple Calendar access and select your calendars.
3. Try a reminder preview, then leave now running in your menu bar.

Launch at Login and automatic updates are optional. Upgrades keep your calendars and preferences.

<details>
<summary><strong>See the app</strong></summary>

<table>
  <tr>
    <td align="center"><img src="docs/images/now-reminder.jpg" height="380" alt="Fullscreen meeting reminder with Join button and countdown"></td>
    <td align="center"><img src="docs/images/now-menubar.jpg" height="380" alt="Meeting agenda with sample Work and Personal calendars"></td>
  </tr>
</table>

</details>

## Learn more

- [Quick guide](docs/guide.md)
- [Changelog](CHANGELOG.md)
- [Building and testing from source](docs/development.md)

## Author & License

[Thomas Boch](https://thomasboch.com) · [GitHub](https://github.com/BoThomas) · [MIT license](LICENSE)

Inspired by [inyourface.app](https://inyourface.app).
