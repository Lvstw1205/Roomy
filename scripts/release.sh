#!/bin/bash
# Tests, builds and packages Roomy, then publishes a GitHub release.
# Usage: scripts/release.sh <version> [gh release options, e.g. --prerelease]
#        DRY_RUN=1 scripts/release.sh <version>   # package only, publish nothing
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--prerelease]}"
shift

if [ -n "$(git status --porcelain)" ]; then
    echo "Commit your changes first." >&2
    exit 1
fi
git fetch -q origin
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "Push main first: the release must match the code on GitHub." >&2
    exit 1
fi

swift test
scripts/build-app.sh "$VERSION"

# Exact file names only, inside dist/ (ignored by git).
ZIP="Roomy-$VERSION.zip"
rm -f "dist/$ZIP" "dist/$ZIP.sha256"
ditto -c -k --keepParent dist/Roomy.app "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > "$ZIP.sha256")
echo "Packaged dist/$ZIP ($(cut -d' ' -f1 "dist/$ZIP.sha256"))"

if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "DRY_RUN: would publish v$VERSION with: $*"
    exit 0
fi
gh release create "v$VERSION" "dist/$ZIP" "dist/$ZIP.sha256" \
    --target main --title "Roomy $VERSION" --generate-notes "$@"
