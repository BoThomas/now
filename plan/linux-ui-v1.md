# Plan: now for Linux — v1 from environment setup to the first UI pass

Status: active, on `feat/headless-linux-probe`. The environment slice (devcontainer + Codespace
validation) landed 2026-10-01; no UI code exists yet. This plan anchors the recorded product
decision of 2026-09-19 in `plan/cross-platform.md` — Linux first, ICS-only feeds, Wayland-only, no
meeting detection, one bundled reminder sound, AUR packaging later — and sequences the work from an
empty environment to a feature-complete v1 the product owner can review interactively ("UI pass").
It ends at that sign-off; packaging and any release are separate plans.

## v1 scope (from the recorded product decision)

In scope:

- Tray menu-bar item on Wayland: StatusNotifierItem + `com.canonical.dbusmenu`, agenda countdown and
  menu driven by NowCore snapshots, Join/Snooze/Pause actions in the tray menu.
- App-owned reminder alert surface (primary path; toasts are secondary and default-action only), per
  the Hyprland probe findings that toasts neither persist nor carry action buttons.
- ICS feeds through the existing core fetch → merge → `commitEvents` paths with injected
  directories; offline recovery and freeze catch-up (already core-proven).
- File-backed preferences with the same tolerant recovery rules; decoder-local palette injection.
- One bundled reminder sound played directly through PipeWire; no freedesktop sound-theme
  assumption.
- Autostart via `~/.config/autostart` with "applies at next login" copy.

Out of scope for v1: native calendar accounts (no EventKit equivalent; evolution-data-server is a
later decision), meeting detection, updater/update trust, X11 support, packaging.

## Environment decisions (researched 2026-09-30, set up 2026-10-01)

- Primary development environment: a GitHub Codespace on this branch, defined by
  `.devcontainer/devcontainer.json`. It provides a pinned Swift toolchain on Ubuntu 24.04, D-Bus
  session tooling, and the `desktop-lite` browser desktop (noVNC on port 6080). Codespaces free tier
  covers prototyping (120 core-hours/month).
- The Codespace desktop (Fluxbox/X11) is a build and integration host, not a target: the product is
  Wayland-only by decision. D-Bus integration runs under `dbus-run-session` against synthetic
  watchers; a nested wlroots session can be added for render verification when M2 needs it.
- GNOME and KDE probe rows (required before the UI-framework lock) run where those desktops run
  natively — VMs on the signing Mac, like the Omarchy/Hyprland rows recorded in
  `plan/cross-platform.md`.
- A persistent Linux workstation (Netcup VPS 1000 G12, 4 vCore/8 GB, ~€10/month) is the agreed
  upgrade once the Codespace proves limiting; decision deferred, not scheduled.
- Recorded non-options: Microsoft Dev Box (maintenance mode; closing 2026, retires 2028), WSLg as a
  dev host (no StatusNotifierItem tray host; microsoft/wslg#532), and Railway free VMs for UI work
  (headless). Railway remains useful as a clean-room Linux gate for the portable checks.
- Safeguards that carry over: Linux validation never replaces macOS build/GUI/signing gates; no
  signing identity or keychain material ever goes into a Linux environment; tests use disposable
  feeds and fake transports only; previews never open real meeting links or write real bookkeeping.

## Milestones

### M0 — Environment (setup committed; Codespace run pending)

Devcontainer with the pinned Swift toolchain, D-Bus tooling, and `desktop-lite`; post-create runs
the portable gates and reports to `/tmp/now-post-create-report.txt`.

Gate: post-create green in a fresh Codespace — core (debug), headless (debug), module boundary
parse, compiler smoke; desktop session reachable on port 6080. Current state: the devcontainer is
committed and partially verified (see "Validation record"); the Codespace run needs the repository
owner, because the agent's fine-grained GitHub token has no Codespaces permission.

### M1 — Session integration harness

A committed, deterministic test harness that runs the app under `dbus-run-session` with a synthetic
`org.kde.StatusNotifierWatcher` fixture: registration, property updates, idempotent re-registration
after a watcher restart (~1.5 s per the Hyprland probe), and notification-channel capability probes.
No real desktop required.

Gate: harness passes in the Codespace and on the Linux devbox as part of selftest; failures are
diagnosable from the report alone.

### M2 — Tray prototype

Register a real StatusNotifierItem (`ItemIsMenu=true`, the proven menu-only configuration), export a
working `com.canonical.dbusmenu` agenda from a NowCore snapshot, render the icon and menu in a real
panel, and survive watcher restarts. The GNOME and KDE probe rows are recorded in
`plan/cross-platform.md` in this milestone, before any UI-framework lock.

Gate: D-Bus assertions plus a screenshot of the rendered menu (nested wlroots session with a
SNI-capable panel, or the probe VM); re-registration verified by killing the watcher mid-run.

### M3 — Alert and agenda surfaces (framework locked here)

The app-owned reminder alert window (primary alert path), the agenda window, and the settings
surface, on the UI framework chosen after the GNOME/KDE rows (candidates recorded in
`plan/cross-platform.md`: SwiftCrossUI, GTK, web view). The macOS fullscreen-alert fallback mirrors
this design intentionally.

Gate: screenshots of alert/agenda/settings states plus deterministic UI-state checks; preview modes
never trigger real delivery, snooze, or bookkeeping.

### M4 — v1 wiring

Everything connected end to end through core paths: ICS fetch/merge/commit with injected
directories, file preferences with tolerant recovery, toasts as the secondary default-action-only
channel, the bundled sound through PipeWire, autostart with next-login semantics, pause behavior
(agenda actions stay usable), snooze and join from the tray menu, offline recovery and catch-up.

Gate: extended EventKit-free deterministic selftest (fake transports, disposable feeds) plus the
full portable gate set — core and headless in debug and release — passing both in the Codespace and
on the Linux devbox.

### M5 — UI pass (end of this plan)

v1 runs continuously in the development environment. The product owner connects through the
Codespace noVNC desktop (or the persistent workstation's remote desktop, once it exists), reviews
the tray menu, alert, agenda, and settings against macOS now, and iterates with the agent: feedback
→ fix → re-verify via screenshots and D-Bus state. Exit condition: look-and-feel sign-off. Packaging
(AUR) and any release become a separate plan.

## Validation record

- 2026-10-01 — devcontainer committed on `feat/headless-linux-probe` (commit `dcc3706`, then the
  Swift pin fix). Verified from the Linux devbox: script syntax, devcontainer JSON, Swift tarball
  URL resolution for both x86_64 and aarch64 (`ubuntu2404[-aarch64]` path, Swift 6.4.0 first
  candidate), and the post-create gate sequence itself passing on this host: core debug (290
  checks), headless debug (51 checks), module boundary parse, compiler smoke. The devbox (Debian 12,
  glibc 2.36) had no Swift toolchain; it now runs the `ubuntu2204` Swift 6.4.0 build from
  `/opt/swift` — the container's Ubuntu 24.04 build needs glibc 2.39 and stays Codespace-only.
- Pending — the same gates green inside a fresh Codespace. Blocked on Codespaces creation, which the
  agent's fine-grained GitHub token cannot perform (no Codespaces permission). The repository owner
  creates it from the branch; the devcontainer is picked up automatically.
