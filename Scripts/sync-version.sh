#!/bin/bash
# Regenerates Sources/DigiaEngage/DigiaSdkVersion.swift from the podspec version
# so the SDK version reported to analytics (the `c`/core segment of sdk_version)
# always matches the released pod. Run this before tagging/publishing a release.
#
# Usage:
#   ./scripts/sync-version.sh            # read version from DigiaEngage.podspec
#   ./scripts/sync-version.sh 2.4.3      # set an explicit version (also bumps podspecs)
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE_PODSPEC="DigiaEngage.podspec"
BINARY_PODSPEC="DigiaEngage-binary.podspec"
VERSION_FILE="Sources/DigiaEngage/DigiaSdkVersion.swift"

if [ "${1:-}" != "" ]; then
  VERSION="$1"
  # Keep both podspecs unified on the requested version.
  sed -i '' "s/^\([[:space:]]*s.version[[:space:]]*=[[:space:]]*\).*/\1'$VERSION'/" "$SOURCE_PODSPEC"
  sed -i '' "s/^\([[:space:]]*s.version[[:space:]]*=[[:space:]]*\).*/\1'$VERSION'/" "$BINARY_PODSPEC"
else
  VERSION=$(grep -E "^[[:space:]]*s.version" "$SOURCE_PODSPEC" | head -1 | sed -E "s/.*'([^']+)'.*/\1/")
fi

cat > "$VERSION_FILE" <<EOF
// Generated code. Do not modify by hand.
// Kept in sync with the podspec version by scripts/sync-version.sh
// (run by the release workflow before tagging/publishing).
enum DigiaSdkVersion {
    static let value = "$VERSION"
}
EOF

echo "[sync-version] DigiaSdkVersion.value -> $VERSION"
