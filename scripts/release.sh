#!/bin/sh
# Publish a release: notarized DMG, git tag, GitHub release. See docs/RELEASING.md.
#
#   ./scripts/release.sh 0.6.0           build, notarize, then ask before anything is pushed
#   ./scripts/release.sh 0.6.0 --check   preflight only: builds and publishes nothing
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:?usage: release.sh <version> [--check]}"
MODE="${2:-}"
TAG="v$VERSION"
fail() { echo "release: $1" >&2; exit 1; }

# Preflight: every one of these has bitten a release somewhere.
command -v gh >/dev/null || fail "gh is not installed"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in"
[ "$(git branch --show-current)" = "main" ] || fail "not on main"
[ -z "$(git status --porcelain)" ] || fail "working tree is not clean: commit first, the tag must describe what was built"
git fetch -q origin || fail "cannot reach origin (if git uses SSH, run ssh-add first)"
[ -z "$(git log --oneline main..origin/main)" ] || fail "origin/main has commits you don't have"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"
PROJECT=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' app/Inlet.xcodeproj/project.pbxproj | sort -u)
[ "$PROJECT" = "$VERSION" ] || fail "MARKETING_VERSION in the Xcode project is '$PROJECT', not $VERSION"
grep -q "^## $VERSION" CHANGELOG.md || fail "CHANGELOG.md has no '## $VERSION' section"
xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-inlet-notary}" >/dev/null 2>&1 \
  || fail "no notarytool profile '${NOTARY_PROFILE:-inlet-notary}' (docs/RELEASING.md, one-time setup)"
echo "preflight ok for $TAG"
[ "$MODE" = "--check" ] && exit 0

./scripts/package.sh | tee dist-release.log
grep -q "notarized and stapled: ready to publish" dist-release.log || { rm -f dist-release.log; fail "the build was not notarized: not publishing"; }
rm -f dist-release.log

# The README's download button points at releases/latest/download/Inlet.dmg, so the asset name never changes.
cp "dist/Inlet-$VERSION.dmg" dist/Inlet.dmg
(cd dist && shasum -a 256 Inlet.dmg > Inlet.dmg.sha256)
# Release notes: this version's CHANGELOG section.
awk -v v="$VERSION" '/^## /{on = index($0, "## " v) == 1} on && !/^## /' CHANGELOG.md > dist/notes.md

printf "Publish %s to GitHub (push main, push tag, create release)? [y/N] " "$TAG"
read -r answer
[ "$answer" = "y" ] || fail "stopped before publishing; the notarized DMG is in dist/"

git tag -a "$TAG" -m "Inlet $VERSION"
git push origin main "$TAG"
gh release create "$TAG" dist/Inlet.dmg dist/Inlet.dmg.sha256 --title "Inlet $VERSION" --notes-file dist/notes.md --verify-tag

# Trust nothing: fetch what people will actually download.
curl -sL -o dist/published.dmg "https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/latest/download/Inlet.dmg"
[ "$(shasum -a 256 dist/published.dmg | cut -c1-64)" = "$(cut -c1-64 dist/Inlet.dmg.sha256)" ] || fail "the published DMG does not match the one that was notarized"
xcrun stapler validate dist/published.dmg >/dev/null || fail "the published DMG has no valid notarization ticket"
rm -f dist/published.dmg
echo "released $TAG"
