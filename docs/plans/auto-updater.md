# Auto-Updater — Research & Plan

> **Status: implemented** on `feat/auto-updater` (see `Sources/Updater.swift`,
> `Sources/UpdateUI.swift`, `scripts/update-smoke.sh`, and AGENTS.md →
> Auto-updater). Kept as the design rationale; behavior documented in AGENTS.md
> is authoritative where wording drifted.

Goal: the app updates itself from GitHub Releases — no Sparkle, no appcast, no extra
hosting, no Apple Developer account. One manual download per machine ever (the release
that first contains the updater), everything after that automatic.

## Research findings

### 1. How Sparkle solves "replace a running .app" (and what we copy)

Read from Sparkle 2.x source (`Autoupdate/SUPlainInstaller.m`,
`Sparkle/Autoupdate/TerminationListener.m`, `Autoupdate/AppInstaller.m`). The architecture:

- **The app never swaps itself.** A separate `Autoupdate` process (shipped in the
  framework) does all filesystem work; the app just quits.
- **Wait for death via kqueue**: `EVFILT_PROC` + `NOTE_EXIT` on the host PID — kernel
  notification, no polling. Sparkle re-checks "already dead?" *after* registering the
  watch, because check-then-register can hang forever if the process dies in between.
  Our shell helper uses `kill -0` polling (0.1 s) — same ordering discipline applies:
  the *app* spawns the helper while it is still alive, so there is always a live PID to
  poll; no race.
- **Stage 1 before quitting**: strip quarantine from the new bundle, copy owner/group
  + Finder tags, bump access times (temp-dir cleanup!), pre-warm Gatekeeper via
  `gktool scan` (14.4+) so relaunch doesn't show "Verifying…".
- **Swap atomically**: APFS `renamex_np(RENAME_SWAP)` old↔new in one syscall; fallback
  path = old→temp dir on same volume, new→destination, **rollback old on failure**.

What we adopt: separate-process installer (a detached `/bin/sh` helper), strict ordering
*death → swap → launch*, staging **sibling to the destination** (same volume → final step
is `mv`, never a copy), trash/backup of the old bundle as rollback, quarantine never
applied (we download ourselves — no quarantine xattr gets set at all, so no Gatekeeper
re-prompt and no "Verifying…" on the updated app).

What we skip (documented trade-offs, fine for a single-binary app with a small user
base): delta updates, install resume, progress UI, sandbox XPC services, downgrade
refusal at install time (we refuse at check time), `gktool` pre-scan (moot without
quarantine).

### 2. macOS facts that make hand-rolling viable

- **No Windows-style file lock**: a running process keeps its (even moved/deleted)
  binary mapped via the old inode. Moving the bundle under a running app is safe as long
  as the app exits promptly and doesn't lazily load bundle resources afterwards. We are a
  single binary, no nested frameworks → hazard ≈ 0.
- **`/Applications` is admin-group-writable** and zip-drag installs are user-owned →
  `mv` needs no privileges in practice. If it fails (root-owned copy, DMG install),
  we roll back and point at the releases page.
- **`ditto -x -k --sequesterRsrc`** is the correct extraction (build-app.sh uses the
  matching flags to create the zip). Plain `unzip` loses permissions/symlinks.
- **Relaunch of an LSUIElement app** via `open <path>` works; the new instance comes up
  `.accessory` per our normal launch path. `open --env K=V` lets us pass env to the
  relaunched process (used by the smoke test).
- **Translocation**: an app launched from an quarantined zip can run from
  `/App Translocation/…` — a read-only randomized path. If our bundle path is
  translocated or on `/Volumes/`, updating is impossible → detect and refuse.

### 3. GitHub as the whole update backend

- `GET https://api.github.com/repos/BoThomas/now/releases/latest` — returns the newest
  **non-draft, non-prerelease** release: tag, `assets[]`, and the release body (our
  changelog bullets — already written by `release.sh`). Asset URLs redirect to GitHub's
  CDN. **Zero release-pipeline changes**: `release.sh` already produces
  `now-vX.Y.Z.zip` with exactly the name the updater looks for.
- Unauthenticated API limit: 60 req/hr per IP. We check at most daily + manually →
  irrelevant. 403/429 → skip this cycle silently (retry policy: see UpdateController).
- `/releases/latest` returns **404** when the repo has no (non-draft, non-prerelease)
  release → mapped to silent "up to date", not an error.
- **Age gate**: `published_at` is in the payload — automatic checks ignore releases
  younger than 24 h (manual checks offer immediately). That window is the
  maintainer's chance to **delete a bad release**: `/latest` then falls back to the
  previous one, and the strictly-greater rule means no downgrade is ever *offered*.
  Machines that already installed the bad release are not rolled back — they wait for
  the next good release. So: deleting the release stops the spread; it is not an
  undo.
- TLS + GitHub account = transport/channel trust; *update authenticity* comes from code
  signing (below), so a compromised GitHub account cannot push a malicious update.

### 4. Trust model: reuse the TCC-stable designated requirement

The updater verifies the **staged bundle's code signature against the same designated
requirement that keeps Calendar TCC grants stable across releases**
(`certificate root = H"<SHA1>"` anchored to "now Developer", cf. build-app.sh). Pin a
**list** of accepted certificate fingerprints in `Updater.swift` (starts with
`A505B08900C56A28709479297A049525A2A187C6`). Also check
`identifier "com.thomasboch.now"` so a different app signed with the same cert can't
substitute. Verification via Security framework (`SecStaticCodeCheckValidity`) — no
subprocess needed.

**Rotation procedure (explicit — laggards strand):** clients pin the list compiled
into *their* binary. Rotating = (1) release an update that *adds* the new
fingerprint while still signing with the **old** cert, (2) keep signing with the old
cert for a generous window (several releases), (3) switch to the new cert, (4) drop
the old fingerprint a release or two later. Any client older than step 1 refuses all
further updates once step 3 happens → manual download. Accepted for this user base;
the window is the mitigation.

**Compromised key reality:** a self-signed key has no revocation — a stolen signing
key is unrecoverable over the air. The actual perimeter is GitHub 2FA + the 1Password
custody of the key material; the signature gate protects specifically against a
compromised *GitHub account* (attacker controls releases but cannot produce a valid
signature).

## Plan

### New file `Sources/Updater.swift`

Pure, selftest-callable decision layer (top-level types + static nonisolated funcs, like
`FetchTracker`/`mergeICS`):

```swift
struct UpdateManifest: Equatable {
    var version: String        // "1.5.0" — parsed from tag "v1.5.0"
    var zipURL: URL            // browser_download_url of the matched asset
    var assetSize: Int         // assets[].size — cross-checked after download
    var publishedAt: Date      // age gate for automatic checks
    var notes: String          // release body, plain text
}

enum UpdateDecision: Equatable {
    case upToDate              // also covers: release younger than the age gate
    case available(UpdateManifest)
    case skippedVersion(String)   // matches settings.skippedUpdateVersion
    case error(String)            // parse/network reason (UI shows only on manual check)
}
```

Static funcs (all pure, unit-tested):
- `parseLatestRelease(_ data: Data, assetName: String) -> UpdateManifest?` — strict
  JSON decode; asset must be exactly `now-v{version}.zip`; tag must be `v` + x.y.z.
- `isVersion(_:newerThan:) -> Bool` — 3-component semver, strictly greater (no
  downgrade, equal = up to date). Reuse the semantics release.sh enforces.
- `decide(manifest:currentVersion:skipped:now:minAge:) -> UpdateDecision` — `minAge`
  is 0 for manual checks, 24 h for automatic ones (young releases → `.upToDate`).
- `updateRequirement(fingerprint:) -> String` — builds
  `identifier "com.thomasboch.now" and certificate root = H"<fp>"` (lowercase hex, same
  format build-app.sh verifies against).
- `pinnedFingerprints: [String]` — the constant list, documented in AGENTS.md next to
  the signing section.

`@MainActor final class UpdateController` (owned by AppDelegate next to store/menu):
- `check(userInitiated:)` — async; network + parse via static nonisolated helper
  (never on the main actor, mirrors `performFetch`).
- Triggers: launch +10 s; `Timer` every 24 h in `.common` mode via
  `AppStore.commonTimer` pattern; one AppDelegate observer on
  `NSWorkspace.shared.notificationCenter` refreshes calendars and invokes the updater
  on wake; manual from menu/settings. A check that fires while
  the update window is open is a **no-op**.
- Throttle, split by outcome: success → `lastSuccessCheckDate` ≥ 24 h; **failure →
  retry after ≥ 1 h, max 3 silent attempts/day** (a network blip at launch+10 s must
  not silence checks for a day).
- **Decide before downloading**: `decide()` runs on the manifest first. Age-gated,
  skipped, and non-newer releases stop before download. First discovery stages eagerly
  so Install is instant. Once that version has actually been shown, later automatic
  checks keep the offer visible without restaging; menu/Settings/manual actions stage
  it explicitly.
- Request: explicit `User-Agent: now/<version>` (GitHub 403s without a UA; an explicit
  one keeps a UA-403 distinguishable from rate limiting). HTTP 404 → up to date.
- API base override: `NOW_UPDATE_API_BASE` env (test hook; default
  `https://api.github.com`). The `--update-*` CLI modes are **read-only** on the
  updates defaults — a terminal run must never record `lastCheckDate` and suppress
  the real app's next auto-check (the smoke install shares the dev's UserDefaults).
- A dedicated updater URLSession is used by API, asset, and updater CLI requests.
  Production accepts HTTPS only and redirect policy is checked before following;
  arbitrary HTTPS CDN destinations are allowed. HTTP is accepted only for loopback
  URLs when `NOW_UPDATE_API_BASE` is explicitly set to a loopback HTTP base.

### Install flow (check → verify → swap → relaunch)

1. **Download** (off main actor): `URLSession.AsyncBytes` streaming to
   `<bundleDir>/.now-update-<uuid>/now-vX.Y.Z.zip`; hard cap 100 MB; timeouts; final
   size cross-checked against `manifest.assetSize` (cheap early tamper/corruption
   signal before signature verification even runs).
2. **Extract**: `ditto -x -k --sequesterRsrc` via a monitored `Process` into the same
   staging dir (60 s, 500 MB logical/allocated data, 50k-entry ceilings).
   Staging is a **sibling of the current bundle** → guaranteed same volume → the final
   install step is a rename. Launch cleanup matches exact canonical-UUID artifact
   names, excludes helper-active paths, deletes staging only after 24 hours, and
   retries moving verified `now.app.old-<uuid>` backups to Trash rather than deleting
   them. Side benefit of the dot-prefix: hidden dirs aren't indexed by LaunchServices,
   so the staged copy never gets registered mid-update.
3. **Verify (the security gate)**:
   - Staging contains **exactly one top-level entry and it is `now.app`** (catches
     malformed/adversarial zips regardless of extractor path handling).
   - `SecStaticCodeCreateWithPath(staged now.app)` + `SecStaticCodeCheckValidity`
     with strict, all-architectures, and nested-code flags against every pinned
     `updateRequirement(fingerprint:)`.
   - Sanity: staged `CFBundleShortVersionString` == manifest version, staged
     `CFBundleVersion` >= running `CFBundleVersion`, and staged
     required `LSMinimumSystemVersion` is one to three canonical decimal components
     and <= running OS (a future deployment-target bump refuses instead of installing
     an app that can't launch).
   - Any failure → delete staging, keep running, surface error (manual checks only).
4. **Confirm**: update window (below) → "Install & Relaunch".
5. **Install**: refuse if bundle path is translocated (`/App Translocation/`) or on
   `/Volumes/`. **Multi-instance guard**: refuse while *any* `NSRunningApplication`
   with our bundle identifier and **pid ≠ self** is alive — this covers different-path
   copies *and* `open -n` second instances of the same path (which would keep the old
   binary mapped through the swap). CLI runs (`--parse` etc.) never register there, so
   the rule stays false-positive-free. Spawn **detached** `/bin/sh -c` helper; **all
   parameters passed via environment, never string-interpolated** (manifest data must
   never reach a shell): `NOW_OLD_PID`, `NOW_APP_PATH`, `NOW_STAGED_APP`,
   `NOW_BACKUP_PATH`, `NOW_RELEASES_URL` (constant compiled from the repo slug),
   optional `NOW_SMOKE_*`. Helper contract: every failure after filesystem mutation
   first restores a valid bundle at `$NOW_APP_PATH`, then relaunches the *old* app
   with `NOW_UPDATE_ERROR=<reason>` so it can tell the user; if even that `open`
   fails, `open "$NOW_RELEASES_URL"` (browser) as the last ditch. Hardening:
   `PATH=/bin:/usr/bin` pinned inside the script, stdio → `/dev/null`, poll bounded to
   60 s (env-overridable for the smoke's stuck-quit variant) — a stuck quit must not
   leak a spinning helper forever; on timeout nothing has been touched yet, so it
    deletes staging and bails (the old app is still running). Old bundle goes to
   the **Finder Trash** only after the launched executable writes an exact
   child-PID/random-token health acknowledgement. Child exit or a 30-second timeout
   triggers rollback. If the Trash move fails, launch cleanup retries moving the valid
   backup rather than deleting it.
   ```sh
   PATH=/bin:/usr/bin; export PATH
   end=$(( $(date +%s) + ${NOW_SMOKE_POLL_TIMEOUT:-60} ))
   while kill -0 "$NOW_OLD_PID" 2>/dev/null; do
      if [ "$(date +%s)" -ge "$end" ]; then
        rm -rf "$NOW_STAGING_ROOT"                  # old app is still intact
        exit 1
      fi
     sleep 0.1
   done
   fail() {                                        # restore, then tell the user
      if [ -d "$NOW_BACKUP_PATH" ]; then            # rename aside; never delete first
        [ ! -e "$NOW_APP_PATH" ] || mv "$NOW_APP_PATH" "$NOW_FAILED_PATH" || exit 1
        mv "$NOW_BACKUP_PATH" "$NOW_APP_PATH" || {
          [ ! -e "$NOW_FAILED_PATH" ] || mv "$NOW_FAILED_PATH" "$NOW_APP_PATH" || true
          open "$NOW_RELEASES_URL"; exit 1
        }
        rm -rf "$NOW_FAILED_PATH"
      fi
     open "$NOW_APP_PATH" --env "NOW_UPDATE_ERROR=$1" 2>/dev/null \
       || open "$NOW_RELEASES_URL"                 # last ditch: browser
     exit 1
   }
    mv "$NOW_APP_PATH" "$NOW_BACKUP_PATH" || fail "backup move failed"
   mv "$NOW_STAGED_APP" "$NOW_APP_PATH" || fail "install move failed"
   open "$NOW_APP_PATH" || fail "relaunch failed"
    mv "$NOW_BACKUP_PATH" "$HOME/.Trash/now-old-$(date +%Y%m%d%H%M%S)-$$.app" 2>/dev/null
   exit 0
   ```
   The failed new app is renamed aside before restore; rollback never deletes the only
   bundle at the install path before the old bundle has been restored.
6. **Quit**: `AppDelegate.terminateForUpdate()` — closes the alert panel (via
   AlertController), bypasses both `handleQuitRequest` confirmations, `NSApp.terminate`.
   The helper finishes the swap + relaunch after our PID dies.
7. **App-side, when relaunched by a failed update**: `NOW_UPDATE_ERROR` present at
   launch → show the update window's error variant (reason + "View on GitHub…"),
   and record that version as `lastNotifiedVersion` so the failed version is never
   auto-offered again on this install (a manual check still re-offers). Without this
   the popup variant would nag about a version that just failed to install.

### UI (v1: automatic checks, manual installs)

The menu bar itself stays meeting-only (no badge, no dot — the countdown owns that
space). Updates are discoverable in three places, escalating in intrusiveness:

- **Menu dropdown** (`MenuBarController`): one update slot after Settings. It reads
  "Check for Updates…" normally and is replaced by "Update to v1.5.0…" while an
  update is known. Selecting the offer opens the staged update or its preparation
  failure with a direct retry. No shortcut in v1.
- **A manual check always answers with the window** — clicking a menu item dismisses
  the menu, so the transient item title can never be the feedback channel (it stays
  as a hint for the *next* menu open). Window variants: update-available /
  up-to-date / couldn't-check.
- **Update window**: one small ~460 pt `[.titled, .closable]` `NSWindow` (transient,
  no autosave), built like a mini-Settings card, three content states:
  - Header: AppIcon (64) + "**now 1.5.0**" semibold over a secondary caption
    "Released Aug 30, 2026 · you have 1.4.0".
  - "What's new" caption (the day-header small-semibold-secondary style), then the
    release body as plain selectable `Text` in a ~160 pt `ScrollView` inside the
    Settings card background (`Color.primary.opacity(0.05)`). Strip the trailing
    "Full changelog: …" line release.sh appends; quiet "View on GitHub…" link button
    bottom-left instead. No HTML/JS rendering, ever.
  - Footer caption: `checkmark.seal` + "Signature verified · ready to install" —
    honest, and it explains why Install is instant (download + verify already
    happened).
  - Buttons bottom-right: **Later** (`.cancelAction`, Esc) / **Install & Relaunch**
    (`.defaultAction`, Return). Both always exist → plain SwiftUI keyboard shortcuts
    are safe here; the alert's vanishing-button/keyMonitor machinery is deliberately
    *not* needed. Full Keyboard Access users get standard Return/Space behavior free.
  - Up-to-date variant (manual): same shell, "You're up to date — now 1.4.0 is the
    latest version.", single OK. Error variant: reason caption + Try Again / Cancel.
    One window class, three states. No sound, no bounce, no progress UI (pre-staged).
- **Settings**: General gains "Check for updates automatically" + "Check Now" +
  "Last checked \(Fmt.ago(…))" caption; while an update is staged the caption becomes
  "v1.5.0 is ready to install" + an "Install…" button opening the window. About
  appends "· v1.5.0 available →" to the version badge row (the `BadgeLink` pattern) —
  update state lives where the version lives. `SettingsSection` stays untouched.
- **Choreography**:
  - `syncActivationPolicy()`'s `wantRegular` gains a third term
    (`updateWindow?.isVisible`); AppDelegate becomes the window's delegate so the
    existing `windowWillClose` + async re-sync hardening covers it. The
    single-policy rule stands.
  - **Never show the update window while a reminder alert is open** — the alert is a
    `.screenSaver`-level fullscreen panel whose key monitor eats Return/Esc; the
    update window would sit underneath, invisible and unfocusable. Defer; show when
    the alert closes.
  - ⌘Q with the update window key: plain terminate. Staging files can remain until
    launch cleanup, but manifest/staging state is not persisted; the offer returns on
    the next eligible automatic check or manual Check Now. No third confirm dialog. ⌘W/⌘M come
    free from the Window menu once `.regular`.
- **Auto-discovery choreography (escalation — Q1 resolved)**: automatic checks never
  steal focus — they only light up the menu item + About link. The update window
  auto-shows **once per version**, and only if that same version has sat uninstalled
  for ≥ 3 days (`firstSeenUpdateVersion`/`firstSeenUpdateDate`, evaluated at check
  time — the daily/wake cadence is a sufficient trigger, no extra timer needed).
  Manual checks always show it immediately. Shared by every variant:
  `lastNotifiedVersion` is set when the window is **shown**, never when the check
  lands (else a deferred window suppresses itself forever).

### Model & persistence

- `AppSettings`: + `automaticUpdateChecks = true`, + `skippedUpdateVersion: String? = nil`
  (explicit CodingKeys + `decodeIfPresent` defaults, same defensive pattern).
- Ephemeral bookkeeping in a separate UserDefaults dict key
  `local.tboch.now.updates.v1`: `lastSuccessCheckDate`, `lastAttemptDate`,
  `attemptsToday` + day stamp (retry throttle), `lastNotifiedVersion` (set at
  window-show time), `firstSeenUpdateVersion` + `firstSeenUpdateDate` (escalation
  variant). Keeps `Persisted` untouched. Never written by the `--update-*` CLI modes.

### Failure modes

| Failure | Behavior |
|---|---|
| No network / 403 / 429 / malformed JSON | silent skip, retry ≥ 1 h, ≤ 3/day (manual: error window) |
| 404 (no releases yet) | silent "up to date" |
| Release younger than 24 h | automatic checks ignore it; manual checks offer it |
| Download dies mid-way / exceeds 100 MB / size ≠ `assetSize` | delete staging; direct retry when surfaced, otherwise next cycle |
| Extraction exceeds 60 s / 500 MB / 50k entries | terminate extraction, delete staging; direct retry when surfaced |
| Signature/DR mismatch (tampered or foreign zip) | hard abort, keep running, error |
| Staging not exactly one top-level `now.app` | hard abort (adversarial/malformed zip) |
| Staged version ≠ manifest, older build, or `LSMinimumSystemVersion` > running OS | hard abort |
| Old PID never dies (stuck quit) | helper bails ≤ 60 s before touching anything |
| `mv` fails (permissions/read-only) | helper restores + relaunches old app with `NOW_UPDATE_ERROR`; last ditch: browser → releases |
| Relaunch or startup health acknowledgement fails after swap | restore backup, relaunch old with `NOW_UPDATE_ERROR` |
| Trash move fails | non-fatal; exact canonical-UUID backup is verified and retried to Trash next launch |
| Bundle translocated/on DMG | refuse up front with explanation |
| Another now instance running (any path, incl. `open -n`) | refuse with "quit the other copy first" |
| Update window open while reminder alert shows | deferred until the alert closes |

### Risks (accepted, named)

- **The no-quarantine assumption**: the whole design rests on "URLSession-downloaded,
  self-installed updates carry no quarantine xattr → Gatekeeper never assesses the
  updated bundle." Long-standing macOS behavior, but it is *the* assumption an OS
  update could break. What degrades gracefully if it ever changes: the signature
  verify still gates the download, and the staged-launch smoke would catch the
  "Verifying…" regression.
- **The startup handshake is deliberately shallow**: it proves that the exact launched
  executable reached early app startup, not that every delayed code path is healthy.
  The age gate + delete-the-release brake still mitigate later crashes.
- **PID reuse** after the bounded helper wait: theoretical, accepted (Sparkle accepts
  the same residual).
- **No revocation** for a self-signed key — see the trust-model rotation notes.

## Testing without touching real releases

Four tiers; nothing requires the real repo's Releases until the very first production
update.

### Tier 1 — pure logic in `SelfTest` (`SelfTest.updateTests()`)

Fixtures as inline JSON strings, no network, no EventKit (selftest stays pure):
release-JSON parsing (valid, missing assets, wrong asset name, non-v tag, 2-component
tag), `isVersion` matrix (equal/lower/higher), `decide` incl. skipped version and
age-gate cases (young release auto → `.upToDate`, manual bypass), `assetSize`
mismatch handling, `updateRequirement` string exactly matching build-app.sh's DR
format.

### Tier 2 — `--update-check [base-url]` CLI (the `--parse` of updates)

Prints: running version/build, fetched tag, matched asset, decision + reason (age-gate
included), the DR fingerprints it would accept. Works against production, a local
server, or a `file://`-served fixture. Deterministic output → usable in the smoke
script. **Read-only**: never writes the updates defaults.

### Tier 3 — end-to-end smoke, fully local (`scripts/update-smoke.sh`)

No GitHub, no real release, exercises the *real* updater + real signatures:

1. `./build-app.sh` (really signed current app).
2. "Install" a copy at a path **containing a space** (`$TMPDIR/now update test/now.app`)
   — the cheapest possible quoting-bug net for the shell helper.
3. Forge a "newer release" locally: clone the built app, `PlistBuddy` bump
   `CFBundleShortVersionString`/`CFBundleVersion`, re-sign with the same stable
   identity (present on the dev machine) — the `codesign` invocation must mirror
   build-app.sh's exactly (flags, entitlements, fingerprint); keep a "keep in sync"
   comment pair in both scripts, they *will* drift — then
   `ditto -c -k --sequesterRsrc --keepParent` → the dynamically versioned asset.
4. Serve a fake `releases/latest` JSON + the zip via `python3 -m http.server` on
   127.0.0.1 (background, killed at the end).
5. Run the *installed* copy's binary with
   `--update-smoke http://127.0.0.1:PORT` — hidden CLI mode that runs the **real**
   Updater flow (check → download → verify → stage → swap → relaunch) against the
   override base, then terminates so the helper can swap. The helper relaunches with
   `open --env NOW_SMOKE_REPORT=<file>`; the relaunched child sees the env, writes its
   version to the report file, exits — script never talks to the GUI. The updater
   passes its own `HOME=$TMPDIR/now-update-test/home` to the helper, so the trashed
   old bundle lands in the test sandbox, not the developer's real `~/.Trash`.
6. Assertions: exit codes; temp path and report contain the dynamically newer version;
   exact startup health acknowledgement completed; old bundle sits in `~/.Trash`;
   staging is gone.
7. Negative variants, same harness: ad-hoc signature rejection; older tag; no-release
   404; a lying response stopped at the streaming byte cap; manifest size mismatch;
   asset-download 404; injected old→backup failure; injected post-swap relaunch
   failure with restore/error relaunch; suppressed startup acknowledgement with
   pre-Trash rollback; and **stuck quit** — smoke mode
   keeps the old process alive (`NOW_SMOKE_SKIP_QUIT=1`) while the helper runs with
   `NOW_SMOKE_POLL_TIMEOUT=3` → helper must bail with nothing moved, app untouched.
   Smoke hooks are stripped from normal inherited environments and only the hidden
   CLI can pass an allow-listed fault to the helper. The failed-version bookkeeping
   transition is covered separately by pure selftest.

Note: the smoke "installed" copy shares the bundle id (and thus UserDefaults) with a
dev's real instance; the child exits immediately via the env flag, so exposure is a
one-second read of persisted state — acceptable, documented in the script header.

### Tier 4 — optional, real network, manual

- `--update-check https://api.github.com` against the real repo (read-only, harmless).
- A throwaway **public** sandbox repo (e.g. `BoThomas/now-updates-test`) with real
  releases → exercises GitHub's real API/CDN/redirects end to end
  (`--update-check`/`--update-smoke` take the repo slug too: `--update-repo owner/name`,
  default `BoThomas/now`). Private repo testing would need a token header
  (`NOW_UPDATE_TOKEN`) — test-only env, only read when `NOW_UPDATE_API_BASE` is set.
- The first real production update after shipping is the final validation.

## Rollout

- First release containing the updater (target v1.5.0) is the **last manual download**
  for every machine — say so in the release notes.
- **Every release runs `scripts/update-smoke.sh` as a hard release.sh preflight**
  (Q3 resolved) — invoked after build + selftest, *before* the commit/tag, with the
  same gate status as `--require-identity`. The smoke accepts `--app <path>` to reuse
  the freshly built `outputs/now.app` instead of compiling twice. For v1.5.0 this is
  existential: the updater-introducing release is unflyable until it flies, and
  Tiers 1–3 are the only proxy for that.
- **v1.5.1 = deliberate canary**: a small, safe release a few days after v1.5.0 whose
  only job is proving the OTA path in production — don't wait for the next feature
  release to find out.
- Bad-release brake stays: delete the GitHub release within the 24 h age-gate window;
  already-updated installs wait for the next good release (no OTA rollback).
- `build-app.sh` untouched; `release.sh` gains only the smoke-preflight invocation.
  Asset name + version bumps already conform. Optional nicety later:
  `release.sh --notes` reminder that users now auto-update.
- AGENTS.md updates with the implementation: new CLI flags, updater invariants (env-only
  helper params, pinned fingerprints list ↔ signing identity rotation procedure,
  staging-sibling rule, quit-bypass, multi-instance guard, Trash-on-update,
  `NOW_UPDATE_ERROR` relaunch contract).

## Decisions (resolved during planning)

- `automaticUpdateChecks = true` by default (opt-out in Settings).
- Old bundle → **Finder Trash** (timestamped name, no "Put Back" metadata — acceptable).
- Age gate: automatic checks ignore releases < **24 h** old; manual checks bypass.
- **Multi-instance guard**: no update while any other now instance runs (any path).
- Check also on **wake** — throttled: success 24 h / failure ≥ 1 h, ≤ 3/day.
- Update notification = escalation (Q1): auto-checks light menu + About only; the
  window auto-shows once per version after ~3 days uninstalled
  (`firstSeenUpdateDate`); manual checks show immediately.
- Helper failures never exit silent: restore → relaunch old app with
  `NOW_UPDATE_ERROR` → browser last ditch.
- `release.sh` runs the update smoke as a hard preflight (Q3) — the gate can't be
  forgotten.

## Out of scope (v2 candidates)

Silent auto-install (`SUAutomaticallyUpdate`-style), "Skip this version" UI (model field
already reserved), beta channel via prereleases (`/releases` + prerelease filter),
delta updates, Homebrew cask, notarization, update-progress UI during download.

---

## Review — second pass (2026-08-30)

Overall the architecture is right: separate-process installer, signature-anchored trust,
staging-as-sibling, env-only helper params — all the correct copies from Sparkle. What
follows is gaps first, UI second, then the short list of what to lock before building.

### Gaps & problems

1. **The helper's failure paths strand the user (biggest concrete hole).** After
   "Install & Relaunch" the app quits and the detached shell owns the story — but it
   can't show UI. The failure table promises "app stays old, error + releases-page
   link," yet nothing implements that: on any failure the script just `exit 1`s and the
   user is left with *no app relaunched* and no message. Fix: every failure exit first
   restores a valid bundle at `$NOW_APP_PATH` if needed, then
   `open "$NOW_APP_PATH" --env NOW_UPDATE_ERROR=<reason>` so the relaunched old app
   shows the error + releases link itself. Same mechanism covers the rollback-after-
   failed-relaunch case (re-open the restored bundle with the flag, not bare).
2. **No bad-release brake.** The day this ships, every client fetches whatever
   `/releases/latest` points at. A broken release (crashes on launch, eats state)
   auto-installs fleet-wide within a day. Cheap mitigations, no infra needed:
   - Age gate: `published_at` is in the API payload — only offer releases ≥ 24–48 h old
     on automatic checks. That window is the maintainer's chance to delete a bad
     release; `/latest` then falls back to the previous one, and the strictly-greater
     version rule means no downgrade is ever offered. Write down explicitly: **deleting
     the GitHub release is the rollback mechanism.**
   - The helper trashes the old bundle on `open` success, but `open` succeeding ≠ the
     new app surviving its first minute. The age gate is the real mitigation; accepted.
3. **The updater-introducing release is unflyable until it flies.** Tiers 1–3 test
   everything except the one thing that matters: v1.5.0's updater only runs for real
   when v1.5.1 ships. Treat the smoke script as a release gate for v1.5.0 (like
   `--require-identity`), and plan v1.5.1 as a deliberate small canary a few days later
   rather than waiting for the next feature release.
4. **Cert rotation strands laggards — state it.** Clients pin the fingerprint list
   compiled into *their* binary. Once signing switches to a new cert, every client
   older than the first release that *added* the new fingerprint refuses all further
   updates (hard abort → manual download). Fine for this user base, but the rotation
   procedure needs the explicit rule: add the new fingerprint, keep signing with the
   old cert for a generous window (several releases), then switch. Corollary worth two
   sentences: a *compromised* signing key is unrecoverable over the air (self-signed =
   no revocation) — GitHub 2FA and the 1Password key custody are the actual perimeter;
   the signature gate only protects against a compromised *GitHub account*.
5. **Decision-before-download ordering is unspecified.** As written, every auto-check
   that finds a new version downloads + extracts + verifies it — even when
   `lastNotifiedVersion` will suppress the window. Run `decide()` on the manifest
   *first*; a non-manual check whose version equals `lastNotifiedVersion` should stop
   before downloading. Also define staging lifetime: what happens to the staged bundle
   on "Later" (delete vs. keep-for-session so a manual "Check for Updates…" re-offers
   instantly), and note that a check firing while the update window is already open is
   a no-op.
6. **`lastNotifiedVersion` must be set when the window is *shown*, not when the check
   lands.** Otherwise a deferred window (alert open, see below) suppresses itself
   forever and the user is never told.
7. **Failed checks shouldn't throttle like successful ones.** "Each attempt records
   `lastCheckDate`" means a transient network blip at launch+10 s silences checks for
   24 h. Record success and failure separately (retry a failure after ~1 h, cap the
   silent retries per day), keep the 24 h cadence for successes.
8. **Multi-instance guard has a same-path hole.** `open -n` runs a second instance of
   the *same* bundle path; the guard as specified (different `bundleURL`) misses it,
   and that instance keeps the old binary mapped through the swap. Tighten to: refuse
   if any `NSRunningApplication` has our bundle identifier with pid ≠ self. CLI runs
   (`--parse` etc.) never register there, so the tighter rule stays false-positive-free.
9. **Backup litter.** If the Trash `mv` fails (root-owned bundle from a DMG install),
   the helper still exits 0 — correct — but `now.app.old-<uuid>` sits next to the app
   forever: launch cleanup only matches `.now-update-*`. Add `now.app.old-*` to the
   launch cleanup patterns (safe: a backup only exists after a successful swap).
10. **Two small verify additions.** (a) Assert the staging dir contains *exactly one*
    top-level `now.app` after `ditto` — catches malformed/adversarial zips regardless
    of extractor path handling. (b) Check the staged `LSMinimumSystemVersion` against
    the running OS, so a future release that bumps the deployment target refuses
    instead of installing an app that can't launch. (The dot-prefix of `.now-update-*`
    has a nice side effect worth noting: LaunchServices doesn't index hidden dirs, so
    the staged copy never gets registered mid-update.)
11. **Platform assumption to name out loud.** The whole design rests on "URLSession
    downloads carry no quarantine xattr → Gatekeeper never assesses the updated app."
    That's been macOS behavior forever, but it's *the* assumption an OS update could
    change; it belongs in the risk list, and the signature verify + staged-launch
    smoke are what degrade gracefully if it ever does.

### Smaller corrections & nits

- `UpdateManifest.build` is a field that by its own comment doesn't belong there — the
  build number only exists once the bundle is staged. Drop it; the staged-verify step
  produces its own value.
- `/releases/latest` returns **404 when a repo has no releases** — map that to silent
  "up to date", not an error.
- GitHub's API 403s on requests without a `User-Agent`. URLSession sends one by
  default, but set `now/<version>` explicitly so a future change can't silently break
  checks (a UA-403 is indistinguishable from rate limiting otherwise).
- The `--update-check` / `--update-smoke` CLIs must be **read-only** on
  `local.tboch.now.updates.v1` — a terminal run recording `lastCheckDate` would
  suppress the real app's next auto-check (and the smoke install shares the dev's
  UserDefaults).
- Helper hardening: bound the `kill -0` poll (~60 s, then give up — a stuck quit
  otherwise leaks a spinning helper forever; PID-reuse after death is the theoretical
  residual, accepted), redirect the helper's stdio to `/dev/null`, set `PATH`
  explicitly inside the script.
- Smoke script: (a) put a **space in the test path** — cheapest possible quoting-bug
  net for the shell helper; (b) the re-sign step must mirror build-app.sh's exact
  `codesign` invocation — either source it or leave a "keep in sync" comment pair,
  because they *will* drift.
- Cross-check the download against the API's `assets[].size` — one-line sanity next to
  the 100 MB cap.

### UI — detailing the plan

The menu bar itself stays meeting-only (no badge, no dot — the countdown owns that
space). Updates are discoverable in three places, escalating in intrusiveness:

1. **Menu dropdown.** One slot after Settings reads "Check for Updates…" normally and
   is replaced by "Update to v1.5.0…" when an update is known. Selecting it opens the
   staged update or a preparation failure with direct retry. No shortcut in v1.
2. **The menu-title feedback problem.** The plan shows "Checking…"/"Up to date" as the
   item's title — but clicking a menu item *dismisses the menu*, so the user who asked
   never sees the answer. Rule: a **manual check always answers with the small window**
   (update-available / up-to-date / couldn't-check variants). The transient menu title
   is still fine as a hint for the *next* open, but it's never the feedback channel.
3. **Update window.** Small fixed-size `NSWindow` (`[.titled, .closable]`, ~460 pt
   wide, centered, no autosave — it's transient), built like a mini-Settings card:
   - Header row: AppIcon (64) + "**now 1.5.0**" (semibold) over a secondary caption
     "Released Aug 30, 2026 · you have 1.4.0".
   - "What's new" caption (same small-semibold-secondary style as the menu's day
     headers), then the release body as plain `Text` in a fixed-height (~160 pt)
     `ScrollView`, `.textSelection(.enabled)`, inside the same
     `Color.primary.opacity(0.05)` rounded card the Settings sections use. Strip the
     trailing "Full changelog: …" line release.sh appends; put a quiet "View on
     GitHub…" link button at the bottom-left instead.
   - Footer caption: `checkmark.seal` + "Signature verified · ready to install" —
     honest, and it explains why Install is instant (download+verify already happened).
   - Buttons bottom-right: **Later** (`.cancelAction`, Esc) / **Install & Relaunch**
     (`.defaultAction`, Return, prominent). Both always exist, so SwiftUI keyboard
     shortcuts are safe here — the alert's vanishing-button/keyMonitor machinery is
     *not* needed; Full Keyboard Access users get the standard Return=default /
     Space=focused behavior for free.
   - **Up-to-date variant** (manual checks): same shell, "You're up to date — now
     1.4.0 is the latest version.", single OK (default + cancel). **Error variant**:
     reason caption + Try Again / Cancel. One window class, three content states.
   - No sound, no bounce, no progress UI (pre-staged).
4. **Settings.** General: "Check for updates automatically" toggle + "Check Now"
   button + "Last checked \(Fmt.ago(…))" caption; when an update is staged the caption
   becomes "v1.5.0 is ready to install" + an "Install…" button that opens the window.
   About: append "· v1.5.0 available →" to the version badge row (the `BadgeLink`
   pattern) — update state belongs where the version lives. `SettingsSection` stays
   untouched, as planned.
5. **Choreography (the actual hard part).**
   - `syncActivationPolicy()`'s `wantRegular` gains a third term
     (`updateWindow?.isVisible`) — same single-policy rule, and the existing
     `windowWillClose` + async re-sync hardening covers it by making AppDelegate the
     window's delegate too.
   - **Never show the update window while a reminder is open**: the alert is a
     `.screenSaver`-level fullscreen panel whose key monitor eats Return/Esc — the
     update window would sit underneath it, invisible and unfocusable. Defer; show
     when the alert closes.
   - ⌘Q with the update window key: bare terminate is fine. Staging is discarded on
     next launch and the offer returns on the next eligible/manual check. Don't grow a
     third confirm dialog.
   - ⌘W/⌘M work for free from the Window menu once `.regular`.
6. **Escalation instead of popup (the one taste call I'd make).** The plan pops the
   window on the first auto-check that finds a new version (once per version). For an
   app whose whole personality is "silent until a meeting," I'd flip it: automatic
   checks only light up the menu item + About link, and the window appears on its own
   only if the same version has sat uninstalled for ~3 days (track a
   `firstSeenUpdateDate` in the updates defaults) — once per version, set
   `lastNotifiedVersion` at show time. Manual checks always show it immediately. Fleet
   still converges, focus is never stolen for a non-meeting. (The plan's once-per-
   version popup is defensible — this app does fullscreen-takeover reminders, after
   all — but escalation is the more now-like behavior.)

### If you only change five things

1. Helper failure paths relaunch the old app with `NOW_UPDATE_ERROR` — never exit silent.
2. Add the `published_at` age gate + document "delete the release" as the rollback.
3. Decide-before-download, staging lifetime on "Later", `lastNotifiedVersion` at show time.
4. Manual checks answer in a window, never in the (dismissed) menu.
5. Defer the update window while a reminder is showing; add the third term to
   `syncActivationPolicy()`.

## Review disposition (2026-08-30 — processed before the next session)

All findings reviewed against the source material (Sparkle internals, GitHub API
behavior, this codebase). **Nothing dismissed outright**; everything integrated into
the plan body above except the single deferred product call (Q1). Two places where
the review's own fixes were corrected:

- **Helper restore was later hardened beyond this review's `rm -rf` fix** — the failed
  new app is now renamed aside, the backup is restored, and only then is the failed
  copy removed. Rollback never deletes the sole bundle at the install path first.
- **Failed-update relaunch must suppress re-offering that version** — without setting
  `lastNotifiedVersion` on the `NOW_UPDATE_ERROR` path, the popup variant would
  immediately re-nag about a version that just failed to install. Added as install
  flow step 7.

Integrated, with any choices the review left open resolved:

- Gap 1 → helper never exits silent: restore → relaunch old app with
  `NOW_UPDATE_ERROR` (+ browser last ditch), app-side step 7.
- Gap 2 → age gate 24 h (review offered 24–48; picked 24 since the maintainer is the
  primary user and manual checks bypass anyway), delete-release brake documented with
  precise semantics (stops the spread, not an undo).
- Gap 3 → smoke as hard release.sh preflight + v1.5.1 canary (Q3 since resolved:
  wired in, `--app` reuse flag so it doesn't compile twice).
- Gap 4 → rotation procedure + compromised-key reality in the trust-model section.
- Gap 5 → decide-before-download; staging is session-scoped (cleaned on launch,
  re-downloaded on demand); check-while-window-open is a no-op.
- Gap 6 → `lastNotifiedVersion` set at window-show time.
- Gap 7 → retry policy split: success 24 h / failure ≥ 1 h, ≤ 3/day.
- Gap 8 → instance guard tightened to pid ≠ self (catches `open -n`).
- Gap 9 → `now.app.old-*` joins launch cleanup.
- Gap 10 → exactly-one-`now.app` check + `LSMinimumSystemVersion` gate; hidden-dir
  LaunchServices note kept.
- Gap 11 → no-quarantine assumption promoted to the Risks section.
- Nits → `UpdateManifest.build` dropped (`assetSize` + `publishedAt` added), 404 →
  up to date, explicit `now/<version>` User-Agent, CLI modes read-only on the updates
  defaults, helper PATH/stdio/60 s poll bound (timeout env-overridable for smoke
  variant (e)), smoke installs at a path with a space, re-sign mirrors build-app.sh
  with a keep-in-sync comment pair, download size cross-checked against
  `assets[].size`.
- UI section → replaced with the review's spec (menu placement + dynamic update item,
  window-always-answers rule, three-state window, Settings/About surfaces,
  activation-policy third term, defer-while-alert-open, ⌘Q bare terminate) + the
  escalation choreography, which Q1 has since resolved in the reviewer's favor.
- Q2 (age gate 24 h vs 48 h) also resolved after this disposition was written:
  kept at 24 h.

---

## Final production-readiness review (2026-08-30)

This section supersedes the initial production-readiness review after two independent
challenge passes and a source-level revalidation of every item.

**Status at review time: do not ship.** The review identified six implementation/
release-path findings. Their implementation disposition and current gate status are
recorded at the end of this section.

### Challenge disposition

1. **Revised: Critical → High; release blocker.** The first helper `mv` is unchecked,
   but the old app normally remains rather than being deleted. The real failure is a
   false-success install that can nest the staged app inside the old signed bundle.
   `codesign --verify --deep --strict` then reports unsealed bundle-root contents. The
   existing `fail()` already handles the pre-backup state; the required code fix is
   `mv "$NOW_APP_PATH" "$NOW_BACKUP_PATH" || fail "backup move failed"`, plus a test.
2. **Kept: High; release blocker.** The download/extraction resource-exhaustion finding
   stands. Rejecting a manifest-declared oversize asset is only an early optimization;
   a lying response still requires streaming with an enforced byte limit. Extraction
   also needs a time and disk-growth budget before unsigned input reaches `ditto`.
3. **Revised: High → Medium; release blocker.** Stale staging completion is a real race,
   but `install()` checks `stagedVersion == available.version`, so no mismatched version
   can be installed. The impact is unavailable/misleading state and litter, not a trust
   bypass.
4. **Revised: High/permanent → Medium/recoverable; release blocker.** A later Settings
   “Check Now” or eligible automatic cycle retries. The defect is that an automatic
   stage failure is hidden and the opened offer remains labelled “Preparing…” with no
   failure reason or direct retry.
5. **Revised: High → Medium; release blocker.** The promised mandatory smoke still
   fails open when its script is absent or non-executable.
6. **Revised: Medium → Low; pre-release correctness.** Notification bookkeeping is
   recorded on request rather than actual visibility. The narrow failure requires an
   escalation while a reminder is open followed by quitting before dismissal; only
   future automatic popup is lost, not the menu/manual offer. The documented show-time
   invariant should still be implemented while this state flow is being fixed.
7. **Revised: Medium → Low product/spec decision.** Re-downloading a previously notified
   update is bounded by the 24-hour successful-check throttle, not every launch. It
   contradicts the explicit decide-before-download plan, but eager staging also keeps
   Install instant. Choose and document one behavior; it is not independently unsafe.
8. **Withdrawn as a defect.** Recording GitHub discovery as a successful check is
   defensible, and the failure table says archive failures retry “next cycle.” The
   broad one-hour wording is ambiguous and specifically motivates network/API failure.
   Direct retry belongs in finding 4; changing automatic preparation retry cadence is
   an optional product policy.
9. **Withdrawn as a defect.** Treating GitHub `/latest` as authoritative and clearing
   an older offer when a newer release is still age-gated is consistent with the
   documented `.upToDate` semantics. Preserving the older release could keep offering
   a superseded or known-bad build. Revisit only as an explicit product decision.
10. **Revised: Medium → Low; pre-release defensive correctness.** Only 404 is handled
    specially; another non-2xx body is parsed if it happens to match the schema. GitHub
    does not normally return release JSON on errors, but final 2xx should be required.
11. **Revised: Medium → Low hardening.** The code allows loopback non-HTTPS based only
    on hostname and does not control redirects, but the production
    `browser_download_url` is GitHub-generated and the operation is a blind GET whose
    bytes still face the signature gate. Bind loopback HTTP to an explicit test
    override. If redirect enforcement is added, use a URLSession delegate to reject a
    disallowed redirect *before following it*: allow HTTPS redirects to GitHub's CDN
    hosts without a brittle fixed-host list, and allow loopback HTTP only in test mode.
12. **Revised: Medium → Low maintainer-error guard.** Lenient parsing is real, but this
    check follows the pinned signature gate. Parse the whole value as one to three
    nonnegative decimal components. Missing `LSMinimumSystemVersion` is valid in macOS
    generally and currently has an explicit passing selftest; decide separately whether
    this project's release invariant requires it. This plist check alone does not prove
    the Mach-O can launch.
13. **Kept: Low; pre-release correctness.** The client accepts negative components and
    the release script accepts leading-zero versions the client rejects. Use one
    canonical ASCII-decimal validator in both paths.
14. **Kept with narrower wording: Low future hardening.** Empty flags still validate
    the main executable, sealed resources, and pinned requirement. Strict structure,
    all-architecture, and nested-code flags add useful coverage, but are not exactly
    equivalent to `codesign --deep --strict`; no current arm64 single-binary bypass is
    known.
15. **Revised: Medium → Low UX follow-up.** First-run Settings can cover the failed-
    install window, but the failure window still exists and remains recoverable.
16. **Replaced: Low duplicate-owner claim → Medium broken wake handling; release
    blocker.** Both observers register on `NotificationCenter.default`. Apple QA1340
    explicitly states that `NSWorkspace` sleep/wake notifications use
    `NSWorkspace.shared.notificationCenter` and are not received through the default
    center. Register one owner on the workspace center, remove it from that same center,
    and have it refresh calendars and invoke the throttled updater once.
17. **Revised: High → Low future tooling debt.** Fixed `9.9.9` safely supports the
    current 1.5.x release and fails closed once no longer newer. Eventually derive both
    a guaranteed-newer semantic version and a build greater than the tested app; the
    fixed build `999999` is a second future ceiling.
18. **Revised: Medium assurance requirement.** Keep focused helper fault injection for
    old→backup and at least one post-backup failure proving restore/relaunch. Test the
    `NOW_UPDATE_ERROR` controller bookkeeping separately; the ad-hoc signature case
    never reaches it. A restore failure can only assert attempted restore and browser
    fallback, not successful rollback.
19. **Revised and narrowed: Medium assurance tied to changed guards.** Do not turn every
    guard into a full swap smoke. Add deterministic coverage at the cheapest correct
    layer for the archive byte/extraction limits, response-size mismatch, asset HTTP
    failure, malformed archive layout, build/OS rejection, API status, and any redirect
    policy changed above. The current smoke summary falsely says it verifies age gating:
    `--update-smoke` uses `minAge: 0`; age gating is covered only by pure selftest.
20. **Kept: Low test flake.** The child report can arrive before the helper finishes its
    Trash move. Poll final filesystem state or add a completion marker.
21. **Kept: Low test-tooling debt.** Literal `/now.app/` matching misses renamed copies,
    and whitespace-delimited `lsof` parsing loses paths containing spaces. This fails
    the smoke closed or fails to reopen a developer app; use path-safe bundle-aware
    discovery.
22. **Kept: Low test defect.** The fixed-date, one-sided missing-`published_at`
    assertion becomes vacuous. Bound the result by real timestamps captured around
    parsing or inject the clock.
23. **Revised: focused assurance, not a blanket GUI-test mandate.** The ad-hoc smoke
    does test one `UpdateStaging.stage` failure, but not controller retry/supersession/
    stale-completion transitions. Add regression coverage for state transitions changed
    by findings 3, 4, and 6 and explicitly assert legacy defaults for the new settings.
    External-close and activation policy can remain targeted GUI/manual coverage unless
    extracted into pure decisions.
24. **Partly withdrawn.** The reproduced forged-app leak is valid: cleanup only knows
    the pre-install PID, so the relaunched demo can survive Ctrl-C. Resetting the
    separate ephemeral updater defaults is deliberate and documented; backing them up
    is optional developer ergonomics, not a production finding.
25. **Revised documentation drift.** Final documentation must say: one menu slot;
    staging files may survive ordinary quit but are discarded on next launch and are
    not reusable; every failure *after filesystem mutation* attempts restore/report;
    pre-mutation PID timeout and post-success Trash failure are deliberate exceptions.
    The current claim that an offer simply returns next launch is also false: manifest
    state is not persisted and the successful-check throttle can hide it until the next
    eligible check or manual Check Now.
26. **Kept but separated as pre-existing release tooling.** `--repo` is inconsistent,
    but adding it only to `gh release create` is insufficient because checks/pushes use
    `origin`. Either remove `--repo`, or validate and apply one selected repository and
    remote consistently. The sandbox updater test does not require `release.sh --repo`.
27. **Kept but separated as pre-existing release tooling.** The process is not
    resumable; exact retry behavior depends on the failed phase. Atomically push branch
    and tag where supported, record completed phases, and print phase-specific
    idempotent recovery commands. GitHub release creation cannot be transactional with
    Git publication.

### Final release findings

1. **[High] Unchecked old→backup move can falsely succeed**
   (`Sources/Updater.swift:502-517`). Guard the first `mv` with the existing `fail()`
   path and add injected first-move failure coverage.
2. **[High] Unauthenticated archive handling has no effective resource bound**
   (`Sources/Updater.swift:341-342,382-417`). Reject declared oversize early, stream
   with a real byte cap, and bound extraction time/disk growth.
3. **[Medium] Staging tasks have no generation/version ownership**
   (`Sources/Updater.swift:721-723,790-825`). Discard stale completions and ensure the
   current manifest starts after supersession.
4. **[Medium] Automatic preparation failures are hidden with no direct retry**
   (`Sources/Updater.swift:806-813`, `Sources/UpdateUI.swift:32-69`,
   `Sources/SettingsUI.swift:1541-1552`). Show the failure and retry action.
5. **[Medium] The mandatory release smoke fails open** (`release.sh:190-197`). Missing
   or non-executable smoke must fail the release.
6. **[Medium] Wake handling never receives real workspace wake notifications**
   (`Sources/App.swift:64-69`, `Sources/Updater.swift:619-645`). Consolidate on
   `NSWorkspace.shared.notificationCenter`.

Required assurance for those fixes:

- Inject old→backup and post-backup helper failures; verify restore, relaunch, and the
  failed-version bookkeeping contract at the appropriate helper/controller layers.
- Add focused state-machine tests for supersession, cancellation/stale completion,
  automatic stage failure, direct retry, and actual-show notification bookkeeping.
- Add bounded-download/extraction tests, plus deterministic tests for guards changed by
  the fix. Correct the smoke's age-gate overclaim.

Small pre-release correctness fixes that should ride with the blocker pass:

- Record `lastNotifiedVersion` only when the window is actually made visible.
- Require final 2xx API status (preserving intentional 404 behavior).
- Align canonical nonnegative semantic-version validation in Swift and `release.sh`.
- Fix the missing-`published_at` wall-clock assertion.
- Reconcile the authoritative plan text with final behavior.

Non-blocking decisions/hardening:

- Decide whether already-notified versions restage automatically or only on explicit
  action; current code and plan disagree.
- Decide whether staging failure should alter the one-hour API-failure throttle; current
  “next cycle” behavior is defensible.
- Keep `/latest` authoritative across the age gate unless product requirements change.
- Bind loopback HTTP to test mode and consider pre-follow redirect policy.
- Tighten `LSMinimumSystemVersion` parsing, signature flags, and first-run window order.
- Fix the optional UI demo's relaunched-process cleanup and future-proof the fixed
  smoke version/build and path discovery.
- Track `release.sh --repo` consistency and resumable publishing separately from this
  branch's runtime gate.

### Verification performed

- `./build-app.sh` and `--selftest` passed with the stable designated requirement.
- The current five-case signed updater smoke passed: swap/relaunch, ad-hoc rejection,
  downgrade refusal, no-release 404, and pre-mutation stuck-PID bailout.
- Live GitHub `--update-check`, `git diff --check`, and shell syntax checks passed.
- A staged-app directory nested into a signed copy reproduced strict signature failure:
  `unsealed contents present in the bundle root`.
- Apple QA1340 and `NSWorkspace.notificationCenter` documentation confirm that wake
  notifications registered on `NotificationCenter.default` are not delivered.
- `release.sh --dry-run` correctly refused the feature branch; rerun it from clean,
  synchronized `main` after the release blockers are fixed and merged.

### Implementation closure (2026-08-30)

All six release findings and the agreed small pre-release correctness work are now
implemented:

- Installer checks old→backup, uses rename-aside rollback instead of delete-first,
  cleans staging on stuck-PID timeout, and preserves the active backup until the helper
  owns its Trash move.
- Archives stream directly to disk under a real 100 MB byte cap. Unsigned extraction is
  terminated at 60 seconds, 500 MB logical/allocated size, or 50k entries.
- Staging has version/generation ownership; stale completions are discarded and cleaned.
  Preparation failures retain their reason and retry the known manifest directly.
- `lastNotifiedVersion` is recorded only after actual window presentation; deferred
  reminder choreography and retry-window ordering are covered by the corrected state
  flow. First-run Settings waits until an update problem is dismissed.
- The release smoke fails closed and now covers twelve signed end-to-end cases, including
  streaming overflow, size mismatch, asset 404, old→backup failure, post-swap rollback,
  and acknowledged stuck-PID cleanup.
- Wake handling has one owner on `NSWorkspace.shared.notificationCenter`. API status and
  canonical semver validation are strict and shared with diagnostics/release tooling.
- Pure selftests cover generation invalidation, install-failure/show bookkeeping,
  canonical versions, HTTP status, legacy update-setting defaults, deterministic
  `published_at` fallback, and extraction timeout/size monitoring.

Current verification: production build/signature passed, selftest passed, the expanded
12-case updater smoke passed, live GitHub `--update-check` passed, shell syntax passed,
and `git diff --check` passed. `release.sh --dry-run` remains intentionally unexecutable
on this feature branch and must be rerun from clean synchronized `main`.

The updater is now clear of the review's original must-fix and should-fix release gate.
The remaining decisions were reviewed immediately afterward and selected for rollout:

1. Add a new-app health acknowledgement before moving the old bundle to Trash; restore
   the old version if the new process does not confirm healthy startup.
2. Stage an already-notified version only after explicit user action, avoiding repeated
   background downloads after session staging was discarded.
3. Enforce HTTPS-only production redirects before following them; permit loopback HTTP
   only under the explicit local test override.
4. Require strict project `LSMinimumSystemVersion` parsing and add strict,
   all-architecture, and nested-code Security-framework validation flags.
5. Generate smoke/demo version and build dynamically, use path-safe running-app
   discovery, and clean the UI demo's relaunched process.
6. Remove `release.sh --repo`, validate the origin-only release target, atomically push
   branch/tag where supported, and provide phase-specific resumable recovery guidance.
7. Match exact updater UUID artifacts, age-bound stale staging cleanup, and retry moving
   valid old backups to Trash instead of deleting them.

### Selected hardening closure (2026-08-30)

All seven selected items above are implemented. The helper launches the real executable
and retains the rollback backup until the normal app finishes initialization, survives
on the main run loop, and emits an exact PID/token acknowledgement; child exit or
timeout restores the old bundle. All updater API/asset/CLI traffic uses a redirect-
gated session with HTTPS production policy and explicit-loopback-only HTTP. Staged apps
require canonical one-to-three-component `LSMinimumSystemVersion` and strict/all-
architectures/nested signature validation. Cleanup matches exact canonical UUIDs,
excludes active paths, age-bounds staging removal, and retries verified backups to
Trash. Already-notified updates restage only after explicit action. Smoke/demo fixtures
are dynamically newer, process handling is path-safe, and demo cleanup owns the
relaunched copy. Releases are origin-only, publish branch/tag atomically, and print
phase-specific recovery instructions. Pure selftests and the 12-case signed smoke cover
these invariants, including child-exit and health-timeout rollback before Trash. No open
blocker or deferred review item remains.
