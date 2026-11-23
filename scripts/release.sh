#!/bin/bash
# Cuts a release: sets the version, commits, tags and pushes. GitHub then
# builds the app and publishes it on the Releases page.
#
# usage: scripts/release.sh <version>      e.g. scripts/release.sh 0.2.0
#
# Before running it, describe the release in CHANGELOG.md under "## <version>".
set -euo pipefail

die() { echo "release: $*" >&2; exit 1; }

version="${1:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "give a version like 0.2.0"
tag="v$version"

cd "$(dirname "$0")/.."

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "switch to main first"
[ -z "$(git status --porcelain)" ] || die "commit or stash your changes first"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "$tag already exists"
scripts/release-notes.sh "$version" >/dev/null || die "add a \"## $version\" section to CHANGELOG.md"

# The version lives in project.yml; the Xcode project is generated from it.
sed -i '' "s/^\( *MARKETING_VERSION: \)\".*\"/\1\"$version\"/" project.yml
grep -q "MARKETING_VERSION: \"$version\"" project.yml || die "could not set the version in project.yml"
xcodegen generate >/dev/null

git add project.yml TaskCtrl.xcodeproj
git diff --cached --quiet || git commit -q -m "Release $version"
git tag -a "$tag" -m "TaskCtrl $version"
git push origin main "$tag"

echo "Pushed $tag. The release appears on GitHub once the build finishes:"
echo "  $(git remote get-url origin | sed 's/\.git$//')/actions"
