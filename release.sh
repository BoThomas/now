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
  --repo owner/name   GitHub repo (default: ${REPO_SLUG})
EOF
}

die() { print -u2 "release: $*"; exit 1 }

while [[ $# -gt 0 ]]; do
  case "$1" in
    patch|minor|major) VERSION_SPEC="$1" ;;
    --notes) NOTES="${2:-}"; shift ;;
    --yes|-y) ASSUME_YES=true ;;
    --dry-run) DRY_RUN=true ;;
    --repo) REPO_SLUG="${2:?}"; shift ;;
    --help|-h) usage; exit 0 ;;
    -*) print -u2 "Unknown option: $1"; usage; exit 1 ;;
    *) VERSION_SPEC="$1" ;;
  esac
  shift
done

is_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] }

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

CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
if [[ "$CURRENT" =~ ^[0-9]+\.[0-9]+$ ]]; then CURRENT="$CURRENT.0"; fi
is_version "$CURRENT" || die "bad version in Info.plist: $CURRENT"

if [[ -n "$VERSION_SPEC" ]]; then
  if is_version "$VERSION_SPEC"; then
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

if [[ -z "$NOTES" && "$DRY_RUN" == false && -t 0 ]]; then
  print -n "Changelog notes for v$VERSION (single line, empty to skip): "
  read -r "NOTES?"
fi

NOTES_ENTRY=""
if [[ -n "${NOTES// }" ]]; then
  while IFS= read -r line; do
    [[ -z "${line// }" ]] && continue
    if [[ "$line" == -* ]]; then
      NOTES_ENTRY+="$line"$'\n'
    else
      NOTES_ENTRY+="- $line"$'\n'
    fi
  done <<< "$NOTES"
fi

BUILD=$(( $(git rev-list --count HEAD) + 1 ))
DATE=$(date +%Y-%m-%d)
TAG="v$VERSION"
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

[[ -z "$(git status --porcelain)" ]] || die "working tree not clean — commit first"

if [[ "$ASSUME_YES" != true ]]; then
  read -r "REPLY?Proceed with release? [y/N] "
  [[ "$REPLY" == [yY]* ]] || die "aborted"
fi

trap 'print -u2 "release: failed — check git status and git tag to clean up"' ERR

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
./build-app.sh >/dev/null
./outputs/now.app/Contents/MacOS/now --selftest
cp outputs/now.zip "outputs/now-$TAG.zip"

print "• Committing and tagging"
git add Info.plist CHANGELOG.md
git commit -m "Release $TAG" --quiet
git tag "$TAG"

print "• Publishing"
if ! git remote get-url origin >/dev/null 2>&1; then
  gh repo create "$REPO_SLUG" --public --source=. --remote=origin \
    --description "Native macOS menu bar meeting reminders — fullscreen alert with one-click join" \
    || die "could not create $REPO_SLUG (already exists? add the remote manually)"
fi
git push -u origin HEAD
git push origin "$TAG"

print "• Creating GitHub release"
NOTES_FILE=$(mktemp)
{
  printf '%s' "$NOTES_ENTRY"
  if [[ -n "$PREV_TAG" ]]; then
    print ""
    print "Full changelog: $CHANGE_URL"
  fi
} > "$NOTES_FILE"
gh release create "$TAG" "outputs/now-$TAG.zip" --title "now $VERSION" --notes-file "$NOTES_FILE"
rm -f "$NOTES_FILE"

print ""
print "Released: https://github.com/$REPO_SLUG/releases/tag/$TAG"
