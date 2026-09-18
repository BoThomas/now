#!/bin/zsh
# Bump the Homebrew tap cask after a published release.
#
# Clones the tap repository into a temporary directory at its default branch,
# updates Casks/now.rb (version, sha256, versioned asset URL), commits, and
# pushes. Called by release.sh AFTER `gh release create` — the release is
# already live, so the only failure state is a briefly stale cask and this
# script is safe to rerun for recovery (idempotent when the cask is already
# at the requested version).
#
# Ordering rationale (plan/homebrew-tap.md): publishing first means brew users
# at worst see the update seconds later; bumping first would expose fresh
# installs to an asset URL that 404s until the release exists.
#
# The tap repository is created in plan/homebrew-tap.md slice 1; until it
# exists this exits with code 3 and release.sh skips the bump with a notice.
#
# Usage: ./scripts/tap-bump.sh <X.Y.Z> <path/to/now-vX.Y.Z.zip>
#   NOW_TAP_REPO / NOW_TAP_CASK override the destination (tests).

set -euo pipefail

TAP_REPO="${NOW_TAP_REPO:-BoThomas/homebrew-tap}"
TAP_CASK="${NOW_TAP_CASK:-Casks/now.rb}"
# Explicit remote override (local path/URL) skips the GitHub repository gate —
# for local testing of the bump logic against a scratch tap.
TAP_URL="${NOW_TAP_URL:-}"

VERSION="${1:-}"
ZIP_PATH="${2:-}"
[[ "$VERSION" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]] ||
  { print -u2 "tap-bump: version must be X.Y.Z (got '${VERSION}')"; exit 1; }
[[ -n "$ZIP_PATH" && -f "$ZIP_PATH" ]] ||
  { print -u2 "tap-bump: release zip not found: '${ZIP_PATH}'"; exit 1; }

if [[ -z "$TAP_URL" ]]; then
  command -v gh >/dev/null 2>&1 || { print -u2 "tap-bump: gh CLI missing (brew install gh)"; exit 1 }
  gh auth status >/dev/null 2>&1 || { print -u2 "tap-bump: gh not authenticated (gh auth login)"; exit 1 }
  gh repo view "$TAP_REPO" --json nameWithOwner >/dev/null 2>&1 ||
    { print -u2 "tap-bump: tap repository $TAP_REPO not found"; exit 3; }
  TAP_URL="https://github.com/$TAP_REPO.git"
fi

SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
[[ ${#SHA256} -eq 64 ]] || { print -u2 "tap-bump: could not hash $ZIP_PATH"; exit 1; }

WORK="$(mktemp -d "${TMPDIR%/}/now tap bump.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

print "• Cloning $TAP_REPO"
git clone -q "$TAP_URL" "$WORK/tap" ||
  { print -u2 "tap-bump: could not clone $TAP_URL"; exit 1; }
CASK_FILE="$WORK/tap/$TAP_CASK"
[[ -f "$CASK_FILE" ]] ||
  { print -u2 "tap-bump: $TAP_CASK missing in $TAP_REPO — complete the tap setup first (plan/homebrew-tap.md slice 1)"; exit 1; }

OLD_VERSION=$(sed -n 's/^[[:space:]]*version "\(.*\)"[[:space:]]*$/\1/p' "$CASK_FILE" | head -n 1)
[[ -n "$OLD_VERSION" ]] || { print -u2 "tap-bump: no version stanza found in $TAP_CASK"; exit 1; }
if [[ "$OLD_VERSION" == "$VERSION" ]]; then
  print "• Tap already at $VERSION — nothing to do"
  exit 0
fi

print "• Bumping cask $OLD_VERSION → $VERSION (sha256 ${SHA256:0:12}…)"
# A fully literal url gets version, sha256, and both URL spellings bumped;
# the substitutions are no-ops for a `#{version}`-interpolated url stanza.
/usr/bin/sed -i '' \
  -e "s/^\([[:space:]]*version \)\".*\"/\1\"$VERSION\"/" \
  -e "s/^\([[:space:]]*sha256 \)\".*\"/\1\"$SHA256\"/" \
  -e "s/now-v${OLD_VERSION}.zip/now-v${VERSION}.zip/g" \
  -e "s|/v${OLD_VERSION}/|/v${VERSION}/|g" \
  "$CASK_FILE"
grep -qE "^[[:space:]]*version \"$VERSION\"$" "$CASK_FILE" || { print -u2 "tap-bump: version stanza not updated"; exit 1; }
grep -qE "^[[:space:]]*sha256 \"$SHA256\"$" "$CASK_FILE" || { print -u2 "tap-bump: sha256 stanza not updated"; exit 1; }

git -C "$WORK/tap" add "$TAP_CASK"
git -C "$WORK/tap" commit -qm "now $VERSION"
if ! git -C "$WORK/tap" push -q origin HEAD; then
  print -u2 "tap-bump: push failed — if this is an authentication error, configure the"
  print -u2 "              gh CLI as git credential helper once: gh auth setup-git"
  exit 1
fi
print "• Tap $TAP_REPO bumped to $VERSION"
