#!/bin/zsh
set -euo pipefail

REPO_SLUG="BoThomas/now"
VERSION_SPEC=""
NOTES=""
ASSUME_YES=false
DRY_RUN=false

usage() {
  cat <<EOF
Usage: ./release.sh [patch|minor|major|X.Y.Z] [options]

  patch|minor|major   version bump (default: patch; first release uses the current version)
  X.Y.Z               explicit version
  --notes "..."       changelog entry, one bullet per line
  --yes               skip the confirmation prompt
  --dry-run           verify prerequisites and print the plan, change nothing
EOF
}

die() { print -u2 "release: $*"; exit 1 }

while [[ $# -gt 0 ]]; do
  case "$1" in
    patch|minor|major) VERSION_SPEC="$1" ;;
    --notes) NOTES="${2:-}"; shift ;;
    --yes|-y) ASSUME_YES=true ;;
    --dry-run) DRY_RUN=true ;;
    --help|-h) usage; exit 0 ;;
    -*) print -u2 "Unknown option: $1"; usage; exit 1 ;;
    *) VERSION_SPEC="$1" ;;
  esac
  shift
done

is_version() { [[ "$1" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]] }

version_gt() {
  local candidate="$1" current="$2" cmaj cmin cpat omaj omin opat
  IFS='.' read -r cmaj cmin cpat <<< "$candidate"
  IFS='.' read -r omaj omin opat <<< "$current"
  (( cmaj > omaj ||
     (cmaj == omaj && cmin > omin) ||
     (cmaj == omaj && cmin == omin && cpat > opat) ))
}

bump() {
  local type="$1" current="$2"
  IFS='.' read -r MAJ MIN PAT <<< "$current"
  case "$type" in
    major) print "$((MAJ + 1)).0.0" ;;
    minor) print "$MAJ.$((MIN + 1)).0" ;;
    *) print "$MAJ.$MIN.$((PAT + 1))" ;;
  esac
}

[[ -f Info.plist ]] || die "run this from the repository root"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository"
command -v gh >/dev/null 2>&1 || die "gh CLI missing (brew install gh)"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (gh auth login)"
[[ "$(git branch --show-current)" == main ]] || die "releases must be run from main"
[[ -z "$(git status --porcelain)" ]] || die "working tree not clean — commit first"
[[ "$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" == origin/main ]] ||
  die "main must track origin/main"
ORIGIN_URL=$(git remote get-url origin 2>/dev/null) || die "origin remote missing"
case "$ORIGIN_URL" in
  https://github.com/${REPO_SLUG}|https://github.com/${REPO_SLUG}.git|git@github.com:${REPO_SLUG}|git@github.com:${REPO_SLUG}.git|ssh://git@github.com/${REPO_SLUG}|ssh://git@github.com/${REPO_SLUG}.git) ;;
  *) die "origin must be the default repository $REPO_SLUG (found $ORIGIN_URL)" ;;
esac
GH_REPO=$(gh repo view "$REPO_SLUG" --json nameWithOwner --jq .nameWithOwner 2>/dev/null) ||
  die "could not access GitHub repository $REPO_SLUG"
[[ "${(L)GH_REPO}" == "${(L)REPO_SLUG}" ]] || die "GitHub repository mismatch: expected $REPO_SLUG, found $GH_REPO"
LOCAL_HEAD=$(git rev-parse HEAD)
TRACKING_HEAD=$(git rev-parse refs/remotes/origin/main 2>/dev/null) || die "origin/main tracking ref missing; fetch it first"
[[ "$LOCAL_HEAD" == "$TRACKING_HEAD" ]] || die "main is not synchronized with the local origin/main ref"
REMOTE_HEAD=$(git ls-remote --exit-code origin refs/heads/main 2>/dev/null | awk 'NR == 1 { print $1 }') ||
  die "could not read origin/main"
[[ "$LOCAL_HEAD" == "$REMOTE_HEAD" ]] || die "main is not synchronized with the live origin/main; fetch/reconcile first"

SIGNING_IDENTITY_SHA1="${NOW_SIGNING_IDENTITY_SHA1:-A505B08900C56A28709479297A049525A2A187C6}"
[[ "$SIGNING_IDENTITY_SHA1" =~ '^[[:xdigit:]]{40}$' ]] || die "NOW_SIGNING_IDENTITY_SHA1 must be a 40-digit SHA-1 fingerprint"
SIGNING_IDENTITY_SHA1="${(U)SIGNING_IDENTITY_SHA1}"
AVAILABLE_IDENTITIES=$(security find-identity -v -p codesigning)
[[ "$AVAILABLE_IDENTITIES" == *"$SIGNING_IDENTITY_SHA1"* ]] || die "required signing identity $SIGNING_IDENTITY_SHA1 not found"
[[ -x scripts/update-smoke.sh ]] || die "mandatory scripts/update-smoke.sh is missing or not executable"

CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
if [[ "$CURRENT" =~ ^[0-9]+\.[0-9]+$ ]]; then CURRENT="$CURRENT.0"; fi
is_version "$CURRENT" || die "bad version in Info.plist: $CURRENT"

if [[ -n "$VERSION_SPEC" ]]; then
  if is_version "$VERSION_SPEC"; then
    version_gt "$VERSION_SPEC" "$CURRENT" || die "explicit version must be greater than $CURRENT"
    VERSION="$VERSION_SPEC"
  else
    case "$VERSION_SPEC" in
      patch|minor|major) VERSION="$(bump "$VERSION_SPEC" "$CURRENT")" ;;
      *) die "invalid version spec: $VERSION_SPEC" ;;
    esac
  fi
elif [[ -z "$(git tag --list 'v*')" ]]; then
  VERSION="$CURRENT"
else
  VERSION="$(bump patch "$CURRENT")"
fi

TAG="v$VERSION"
git show-ref --verify --quiet "refs/tags/$TAG" && die "local tag $TAG already exists"
REMOTE_TAGS=$(git ls-remote --tags origin "refs/tags/$TAG" "refs/tags/$TAG^{}") ||
  die "could not check remote tag $TAG"
[[ -z "$REMOTE_TAGS" ]] || die "remote tag $TAG already exists"

if [[ -z "$NOTES" && "$DRY_RUN" == false && -t 0 ]]; then
  print -n "Changelog notes for v$VERSION (single line, empty to skip): "
  read -r "NOTES?"
fi

NOTES_ENTRY=""
if [[ -n "${NOTES// }" ]]; then
  while IFS= read -r line; do
    [[ -z "${line// }" ]] && continue
    if [[ "$line" == "#"* ]]; then
      NOTES_ENTRY+="$line"$'\n'
    elif [[ "$line" == -* ]]; then
      NOTES_ENTRY+="$line"$'\n'
    else
      NOTES_ENTRY+="- $line"$'\n'
    fi
  done <<< "$NOTES"
fi

BUILD=$(( $(git rev-list --count HEAD) + 1 ))
DATE=$(date +%Y-%m-%d)
PREV_TAG=$(git tag --list 'v*' --sort=-v:refname | head -n 1)
if [[ -n "$PREV_TAG" ]]; then
  CHANGE_URL="https://github.com/$REPO_SLUG/compare/$PREV_TAG...$TAG"
else
  CHANGE_URL="https://github.com/$REPO_SLUG/releases/tag/$TAG"
fi

print ""
print "Release plan:"
print "  version : $CURRENT → $VERSION (build $BUILD)"
print "  tag     : $TAG"
print "  repo    : $REPO_SLUG"
print "  notes   :"
if [[ -n "$NOTES_ENTRY" ]]; then
  printf '%s' "$NOTES_ENTRY" | sed 's/^/    /'
else
  print "    (none)"
fi
print "  asset   : outputs/now-$TAG.zip"
print ""

if [[ "$DRY_RUN" == true ]]; then
  print "Dry run — prerequisites OK, nothing was changed."
  exit 0
fi

if [[ "$ASSUME_YES" != true ]]; then
  read -r "REPLY?Proceed with release? [y/N] "
  [[ "$REPLY" == [yY]* ]] || die "aborted"
fi

PHASE="preparing release files"
NOTES_FILE=""
release_failed() {
  local rc=$?
  print -u2 ""
  print -u2 "release: failed while $PHASE"
  case "$PHASE" in
    "preparing release files"|"building and testing")
      print -u2 "Recovery: fix the failure in this worktree, then resume the preflight and publication:"
      print -u2 "  ./build-app.sh --require-identity && ./outputs/now.app/Contents/MacOS/now --selftest"
      print -u2 "  ./scripts/update-smoke.sh --app outputs/now.app && cp outputs/now.zip 'outputs/now-$TAG.zip'"
      print -u2 "  git add Info.plist CHANGELOG.md && git commit -m 'Release $TAG' && git tag '$TAG'"
      print -u2 "  git push --atomic -u origin HEAD '$TAG'"
      print -u2 "Do not rerun release.sh until these generated release changes are committed or removed."
      ;;
    "committing release")
      print -u2 "Recovery: inspect git status, then complete the commit and continue:"
      print -u2 "  git add Info.plist CHANGELOG.md && git commit -m 'Release $TAG' && git tag '$TAG'"
      print -u2 "  git push --atomic -u origin HEAD '$TAG'"
      ;;
    "tagging release")
      print -u2 "Recovery: create the missing tag, then publish both refs atomically:"
      print -u2 "  git tag '$TAG' && git push --atomic -u origin HEAD '$TAG'"
      ;;
    "publishing branch and tag")
      print -u2 "Recovery: the atomic push left both refs published or neither; verify, then retry:"
      print -u2 "  git ls-remote origin refs/heads/main refs/tags/$TAG"
      print -u2 "  git push --atomic -u origin HEAD '$TAG'"
      ;;
    "creating GitHub release")
      print -u2 "Recovery: branch and tag are published. Retry only the GitHub release:"
      print -u2 "  gh release create '$TAG' 'outputs/now-$TAG.zip' --repo '$REPO_SLUG' --title 'now $VERSION' --notes-file '$NOTES_FILE'"
      ;;
  esac
  exit $rc
}
trap release_failed ERR

print "• Updating CHANGELOG.md"
CHANGELOG="CHANGELOG.md"
[[ -f "$CHANGELOG" ]] || print "# Changelog\n" > "$CHANGELOG"
ENTRY_FILE=$(mktemp)
{
  print "## [$VERSION] - $DATE"
  print ""
  if [[ -n "$NOTES_ENTRY" ]]; then
    printf '%s' "$NOTES_ENTRY"
  else
    print "- Release $VERSION."
  fi
  print ""
} > "$ENTRY_FILE"
awk -v entry="$ENTRY_FILE" 'NR == 2 { while ((getline line < entry) > 0) print line } { print }' "$CHANGELOG" > "$CHANGELOG.new"
mv "$CHANGELOG.new" "$CHANGELOG"
print "[$VERSION]: $CHANGE_URL" >> "$CHANGELOG"
rm -f "$ENTRY_FILE"

print "• Updating Info.plist → $VERSION (build $BUILD)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Info.plist

print "• Building"
PHASE="building and testing"
# Stable signing is mandatory for releases: an ad-hoc release zip would
# invalidate existing Calendar (TCC) grants on every update.
./build-app.sh --require-identity >/dev/null
./outputs/now.app/Contents/MacOS/now --selftest

# Hard preflight for every release: the update smoke exercises the real
# updater path (check → stage → signature gate → swap → relaunch) against a
# forged local release. For v1.5.0+ this is existential — the updater rides
# in the app being released. (Quits a running now for the test; re-opens it.)
print "• Running update smoke test"
./scripts/update-smoke.sh --app outputs/now.app
cp outputs/now.zip "outputs/now-$TAG.zip"

print "• Preparing release notes"
NOTES_FILE=$(mktemp)
{
  printf '%s' "$NOTES_ENTRY"
  if [[ -n "$PREV_TAG" ]]; then
    print ""
    print "Full changelog: $CHANGE_URL"
  fi
} > "$NOTES_FILE"

print "• Committing and tagging"
PHASE="committing release"
git add Info.plist CHANGELOG.md
git commit -m "Release $TAG" --quiet
PHASE="tagging release"
git tag "$TAG"

print "• Publishing"
PHASE="publishing branch and tag"
git push --atomic -u origin HEAD "$TAG"

print "• Creating GitHub release"
PHASE="creating GitHub release"
gh release create "$TAG" "outputs/now-$TAG.zip" --repo "$REPO_SLUG" --title "now $VERSION" --notes-file "$NOTES_FILE"
rm -f "$NOTES_FILE"
PHASE="complete"

print ""
print "Released: https://github.com/$REPO_SLUG/releases/tag/$TAG"
