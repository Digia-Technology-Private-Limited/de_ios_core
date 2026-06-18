#!/bin/bash
# Pure semver bump helper. Same algorithm as the digia_engage monorepo's
# scripts/bump-semver.sh and flutter/bump_version.sh, so iOS bumps versions
# the same way as the other platforms.
#
# Usage:   bump-semver.sh <current_version> <major|minor|patch|beta>
# Output:  the new version string, printed to stdout (nothing else).
set -euo pipefail

current="${1:?current version required}"
type="${2:?bump type required}"

major=$(echo "$current" | cut -d '.' -f 1)
minor=$(echo "$current" | cut -d '.' -f 2)
patch=$(echo "$current" | cut -d '.' -f 3 | cut -d '-' -f 1)
beta=$(echo "$current" | grep -o 'beta\.[0-9]*' | cut -d '.' -f 2 || true)
[ -z "${beta:-}" ] && beta=0

case "$type" in
  major) major=$((major + 1)); minor=0; patch=0; beta=0 ;;
  minor) minor=$((minor + 1)); patch=0; beta=0 ;;
  patch) patch=$((patch + 1)); beta=0 ;;
  beta)  beta=$((beta + 1)) ;;
  *) echo "Invalid version bump type: $type" >&2; exit 1 ;;
esac

if [ "$beta" -gt 0 ]; then
  echo "$major.$minor.$patch-beta.$beta"
else
  echo "$major.$minor.$patch"
fi
