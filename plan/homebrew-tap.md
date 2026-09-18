# Plan: Homebrew tap with brew-managed updates

Status: proposed, not started. Written from a user feature request ("a homebrew repo which
automatically runs xattr after an update and also provides updates") and the accompanying design
discussion. No release is part of this plan; each slice lands behind the required checks in
`AGENTS.md`. Homebrew behavior was verified against current documentation and changelogs and an
isolated local probe (docs.brew.sh; brew 7.0.1, September 2026).

## Motivation and current distribution

- Release ZIPs are published on GitHub Releases. Builds are signed with the self-signed "now
  Developer" identity but are not notarized (no paid Apple Developer Program membership).
- Gatekeeper therefore blocks the first launch. The README documents "Open Anyway", right-click
  Open, or manual `xattr -dr com.apple.quarantine /Applications/now.app`.
- The in-app updater (`UpdateLogic`, `UpdateController`, `UpdateFetch`, `UpdateStaging`,
  `UpdateInstaller`) downloads, stages, validates against the pinned certificate fingerprint, and
  performs the health-checked swap. This remains the update path for manual installations.

## Decisions

1. **Dedicated tap repository.** The cask lives in a small `homebrew-*` repository (for example
   `BoThomas/homebrew-tap`). The tap is referenced as `BoThomas/tap`, because
   `brew tap <user>/<repo>` clones `github.com/<user>/homebrew-<repo>` and the `homebrew-` prefix is
   omitted in tap and cask names. Official `homebrew/cask` is out: its casks must pass Gatekeeper
   checks, must not bypass them, and Homebrew ended support for Gatekeeper-failing casks on
   2026-09-01. Hosting the cask inside the `now` repository is technically possible through an
   explicit `brew tap` URL but is rejected: every `brew update` would clone the full app history,
   automated version bumps would commit to `main`, and release automation would couple across
   purposes.
2. **Brew-managed update UX.** On Homebrew installations the app keeps discovery and presentation
   (version comparison, throttle, menu/About indication, Check for Updates) but replaces the install
   path with a copyable `brew upgrade --cask <user>/tap/now` command. Homebrew owns the
   installation; the app never stages or swaps its own bundle there. This also removes the
   two-updater hazard where an in-app swap desyncs Caskroom metadata.
3. **No `auto_updates` stanza.** The stanza's meaning changed in 2026: for a versioned cask with a
   readable app bundle, Homebrew now compares the installed bundle's version metadata and a default
   `brew upgrade` includes the cask when the app reads older (skipping it when same-or-newer, or
   when no reliable comparison is possible; `brew outdated` still lists such casks only with
   `--greedy`/`--greedy-auto-updates`). Declaring it would still be dishonest — in brew mode the
   in-app installer is disabled, so the app does not update itself there — and a cask Homebrew
   cannot compare may be skipped entirely. Without the stanza, brew upgrades purely by cask version,
   which is the behavior brew users should get.
4. **TCC stability carries over.** Calendar permission survives `brew upgrade` because the stable
   "now Developer" identity anchors the designated requirement to the certificate hash. Identity
   rotation must continue to coordinate the updater pins and would now also affect tap users.
5. **Quarantine removal is cask-owned and is the only mechanism.** `--no-quarantine` no longer
   exists: deprecated in brew 4.7.0, the switch disabled in 5.1.0, remaining code removed in 6.0.14
   — Homebrew now quarantines cask downloads unconditionally. Removing the attribute in the cask's
   postflight is therefore not an alternative to a flag but the only way to an unblocked first
   launch. This is the established third-party-tap pattern for non-notarized apps: the signing audit
   that would reject it runs only for official taps unless explicitly requested, and the Gatekeeper
   deprecation deadline applies to `homebrew/cask`, not to private taps. The responsibility for the
   bypass sits with this tap.

## Slice 1: tap repository and cask

- [ ] Create the dedicated tap repository with `Casks/now.rb` and a README describing
      `brew tap <user>/tap` (for the `homebrew-tap` repository) and the fully qualified
      `brew install --cask <user>/tap/now`. Fully qualified names install with item-level trust; the
      short name `now` requires `brew trust --cask <user>/tap/now` first, so the README leads with
      the full form.
- [ ] Cask stanzas: `version` (plain `X.Y.Z`, no `v`), `sha256` of the published release ZIP,
      versioned release-asset `url`, `name "now"` (required stanza), `desc`, `homepage`,
      `app "now.app"` (the ZIP contains exactly one top-level `now.app`), and requirements
      `depends_on macos: :ventura` for the macOS 13 minimum (symbol form) plus
      `depends_on arch: :arm64` because builds are arm64-only (`scripts/swiftpm.sh` passes
      `--arch arm64`).
- [ ] Quarantine handling, in the form the probe verified: `postflight_steps` with
      `run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/now.app"],     must_succeed: false`.
      On brew 7.0.1 this strips the attribute on install and upgrade — the absolute binary path, the
      `{{appdir}}` token, and the sandboxed step's write on the installed bundle all work. The
      legacy Ruby `postflight` block still functions but brew 7 prints an explicit deprecation
      warning for it, so only the structured form ships. `must_succeed: false` matters: `xattr -d`
      exits non-zero when the attribute is already absent, which would otherwise abort the install.
      Re-verify manually against the hosted tap that install and upgrade leave no quarantine
      attribute and that first launch is unblocked.
- [ ] Add a `livecheck` block with `url :url`, `strategy :github_latest`, and
      `regex(/^v?(\d+(?:\.\d+)+)$/i)` (strips the leading `v` from the release tag) so
      `brew livecheck` tracks upstream even before automation lands.
- [ ] Verify an upgrade over a running app: the running instance keeps the old binary until
      relaunch, Calendar permission is retained, and no re-prompt appears.

## Slice 2: release automation and ordering

- [ ] Bump the tap from the release pipeline after publication: `release.sh` keeps its existing
      sequence through `gh release create`, then computes the SHA-256 of the final local ZIP
      (byte-identical to the uploaded asset), commits and pushes the cask version bump to the tap
      repository. Ordering rationale: the release is already live, so the only transient state is a
      briefly stale cask — brew users see the update a few seconds later. The reverse order would
      expose fresh installs to an asset URL that 404s until the release exists, which is the
      strictly worse failure.
- [ ] The bump step clones the tap repository into a temporary directory at a pinned ref, never a
      durable local checkout (`release.sh` guarantees a clean tree only for `now`). Extend the
      `release_failed` trap with a recovery phase for the bump — "release published, cask stale:
      rerun the bump" — alongside the existing per-phase instructions.
- [ ] Extend `release.sh --dry-run` to print the planned tap bump (repository, cask path, version,
      SHA-256, commit message) without mutating anything; preflight continues to fetch or mutate
      nothing in either repository.
- [ ] Credentials: none beyond what `release.sh` already gates on. It already fails without
      `gh auth`, and `gh auth setup-git` configures git to use the gh CLI as credential helper,
      which covers the tap push. No secrets live in the `now` repository. Escape hatch if a push is
      ever needed where gh cannot serve as credential helper: a fine-grained PAT with
      `contents:write` limited to the tap repository, stored in the login keychain — never
      committed, never logged.
- [ ] Fallback automation if `release.sh` integration is deferred: a `repository_dispatch` (or
      scheduled) workflow in the tap repo that bumps after publish, authenticated with the tap
      repository's own `GITHUB_TOKEN` (the `now` repository is public, so reading releases needs no
      token). This lengthens the stale window and is therefore the fallback, not the default.

## Slice 3: brew-managed detection

- [ ] Pure, nonisolated helper beside the updater policy in the shell (the updater lives in the
      shell target, `Sources/Updater.swift`; NowCore has no updater, and
      `scripts/module-boundary-smoke.py` guards that ownership): decide brew management from the
      resolved bundle path. Probe-corrected model (brew 7.0.1): cask apps are real bundles in the
      app directory and the Caskroom holds a tracking symlink back to them
      (`<prefix>/Caskroom/now/<version>/now.app` → installed bundle), recreated under the new
      version directory on upgrade. Detection therefore checks whether any such symlink under the
      default prefixes (`/opt/homebrew`, `/usr/local`) resolves to the running bundle path; globbing
      the version directory keeps the check stable across upgrades. Symlink and path probing is the
      platform adapter, the match decision is the testable policy, and no `brew` CLI is invoked at
      runtime.
- [ ] Selftest coverage, deterministic and EventKit-free: both default prefixes, versioned Caskroom
      directories, matching versus unrelated symlink targets, absent Caskroom, and custom
      app-directory install locations.
- [ ] Accepted heuristic risks, documented as behavior: a non-default Homebrew prefix or a user
      manually copying the app elsewhere breaks the symlink match, and the app falls back to
      manual-updater behavior.

## Slice 4: brew mode in the updater

- [ ] In brew mode, skip `UpdateFetch` staging, `UpdateStaging` extraction, the nested signature
      validation path, `UpdateInstaller`, and the startup-health acknowledgment contract. The
      offered update action becomes a copyable command containing the exact tap/cask name.
- [ ] Keep version comparison, the six-hour spacing, and the offer presentation. Notifications that
      announce a staged or installed update must not fire in brew mode; the opt-in update-available
      notification can stay.
- [ ] Transition handling: when brew mode is first detected, discard any already-staged update and
      pending-install state instead of leaving a stale staged bundle or a pending marker that brew
      mode can never consume.
- [ ] UI copy states that the running instance stays on the old version until relaunch, and the
      copied command is written to the pasteboard only on explicit user action.
- [ ] "Update Complete", rollback, and backup flows remain in-app-updater-only and unreachable in
      brew mode.
- [ ] Extend `scripts/update-smoke.sh` with a brew-mode scenario proving no staging or install is
      attempted and the command presentation path is used.

## Slice 5: documentation

- [ ] README: Homebrew install alongside the manual ZIP path; keep the manual quarantine guidance
      for manual installs only.
- [ ] `docs/guide.md`: describe brew-mode update behavior and what differs from the in-app updater.
- [ ] Refresh the wiki through the AutoWiki skill (as `AGENTS.md` prescribes) once the feature
      lands: brew mode, detection, and the tap pipeline in `autowiki/development-and-updates.md`,
      referencing the signing notes for the TCC/identity coupling.
- [ ] Run `npm run format-docs` and `npm run check-docs` after the Markdown edits.

## Verification gates

Signed build (`./build-app.sh --require-identity`, outside the agent sandbox) and selftest after
every change set; `./scripts/analyze.sh` after Swift changes. Core suites and
`module-boundary-smoke.py` are required only if `NowCore` changes — the planned detection helper is
shell policy, so revisit this if the decision moves into core. `update-smoke.sh` covers updater
changes; GUI launch/liveness is checked because the updater touches startup paths. Tap-side changes
are verified manually on the signing Mac against current brew (install, upgrade, quarantine removal
— including that the chosen postflight form still works after brew updates — and permission
retention). The postflight mechanics and the Caskroom tracking-symlink model were probed on
2026-09-18 with a disposable local tap, dummy apps, a local HTTP server, and a custom `--appdir`
(brew 7.0.1, macOS 26.6, arm64); the hosted first-install flow (auto-tap plus item-level trust)
still needs the real GitHub tap and remains part of Slice 1 verification. No release is performed
unless explicitly requested; `release.sh` changes are exercised via `--dry-run` first.

## Open questions

- Tap repository name: `BoThomas/homebrew-tap` (generic, room for more packages; tap name
  `BoThomas/tap`) versus a now-specific name; the install command differs accordingly.
- Whether a cask named `now` collides with any official cask name in practice; in a third-party tap
  the fully qualified name disambiguates and short-name use requires `brew trust`, so the README
  documents the full form either way.
- Whether manual "Check for Updates" in brew mode should additionally offer a link to the releases
  page.
