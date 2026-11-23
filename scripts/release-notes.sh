#!/bin/bash
# Prints the notes for one version: its section of CHANGELOG.md followed by
# how to install the download.
#
# usage: scripts/release-notes.sh <version>
set -euo pipefail

version="${1:?usage: scripts/release-notes.sh <version>}"
cd "$(dirname "$0")/.."

notes=$(awk -v heading="## $version" '
    $0 == heading || index($0, heading " ") == 1 { found = 1; next }
    found && /^## / { exit }
    found { print }
' CHANGELOG.md)

if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
    echo "CHANGELOG.md has no section for $version" >&2
    exit 1
fi

printf '%s\n' "$notes"
cat <<NOTES

## Installing

Requires macOS 15 or later on Apple Silicon.

1. Download \`TaskCtrl-$version.zip\` below and unpack it.
2. Move \`TaskCtrl.app\` to Applications.
3. The app is not notarized, so macOS blocks the first launch. Clear the download flag once:

   \`\`\`bash
   xattr -dr com.apple.quarantine /Applications/TaskCtrl.app
   \`\`\`

This build is signed ad hoc, so the privileged helper is not available in it: CPU and memory of system processes stay hidden. Build from source with your own developer team to get the helper.
NOTES
