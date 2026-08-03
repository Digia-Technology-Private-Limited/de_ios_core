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

# Primary (fat binary) podspec — the source of truth for the version when no arg is given.
SOURCE_PODSPEC="DigiaEngage.podspec"
# Every other podspec that must stay on the same version. -source = the local dev spec that
# compiles from source (DigiaEngage-source.podspec); -binary = the slim/dynamic spec (may not
# exist yet). Any that is absent is skipped, so this never fails on a missing file.
OTHER_PODSPECS=("DigiaEngage-source.podspec" "DigiaEngage-binary.podspec")
# The tracked, source-of-truth version constant. NB: the file is SdkVersion.swift — pointing this
# at a different name (e.g. DigiaSdkVersion.swift) makes this script CREATE A DUPLICATE `enum
# DigiaSdkVersion`, which then fails every build with "ambiguous use of 'value'".
VERSION_FILE="Sources/DigiaEngage/SdkVersion.swift"

set_version() {
  sed -i '' "s/^\([[:space:]]*s.version[[:space:]]*=[[:space:]]*\).*/\1'$1'/" "$2"
}

if [ "${1:-}" != "" ]; then
  VERSION="$1"
  # Keep every existing podspec unified on the requested version.
  set_version "$VERSION" "$SOURCE_PODSPEC"
  for spec in "${OTHER_PODSPECS[@]}"; do
    [ -f "$spec" ] && set_version "$VERSION" "$spec"
  done
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
