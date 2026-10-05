#!/usr/bin/env bash
# ==============================================================================
# Digia Engage iOS Test Runner (Pinned to iPhone 17 Pro Max)
#
# Runs Apple Xcode Test Plans directly against the pinned reference simulator
# (iPhone 17 Pro Max, iOS 26.x, @3x retina scale, light appearance).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PLAN="${1:-Smoke}"
RECORD="${RECORD_SNAPSHOTS:-false}"

PINNED_DEVICE_NAME="iPhone 17 Pro Max"

# 1. Resolve Pinned Simulator
BOOTED_PINNED_ID=$(xcrun simctl list devices booted | grep "$PINNED_DEVICE_NAME" | grep -E -o '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -n 1 || true)

if [[ -n "$BOOTED_PINNED_ID" ]]; then
  DESTINATION="platform=iOS Simulator,id=$BOOTED_PINNED_ID"
else
  DESTINATION="platform=iOS Simulator,name=$PINNED_DEVICE_NAME"
fi

# 2. Capitalize first letter to match plan name (e.g. nudge -> Nudge, smoke -> Smoke)
PLAN_NAME="$(tr '[:lower:]' '[:upper:]' <<< "${PLAN:0:1}")${PLAN:1}"

echo "=================================================================="
echo " Digia Engage Test Runner"
echo " Pinned Reference Device : $PINNED_DEVICE_NAME"
echo " Destination Target      : $DESTINATION"
echo " Xcode Test Plan         : $PLAN_NAME"
echo " Snapshot Record Mode    : $RECORD"
echo "=================================================================="

cd "$SCRIPT_DIR"
SIMCTL_CHILD_RECORD_SNAPSHOTS="$RECORD" RECORD_SNAPSHOTS="$RECORD" exec xcodebuild test \
  -scheme DigiaEngage \
  -destination "$DESTINATION" \
  -testPlan "$PLAN_NAME"
