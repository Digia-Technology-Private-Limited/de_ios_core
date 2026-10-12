#!/usr/bin/env bash
# ==============================================================================
# Digia Engage iOS Test Runner
#
# Runs Swift Testing suites by tag on the pinned reference simulator
# (iPhone 17 Pro Max) using xcodebuild's -only-testing-tags / -skip-testing-tags.
# No .xctestplan is involved; tags are declared in Tests/DigiaEngageTests/TestingTags.swift.
#
# Usage: ./run-tests.sh [tag|all|quick] [record]
#   tag     any tag from TestingTags.swift (e.g. golden, smoke, nudge)
#   all     every test under Tests/ (default)
#   quick   every test except those tagged `slow`
#   record  `record`/`true`/`1` records snapshot goldens (also: RECORD_SNAPSHOTS=true)
# Recording always fails the run by design; run again without `record` to verify.
#
# After the run, line coverage of Sources/ is exported as LCOV to coverage/lcov.info,
# plus an HTML report at coverage/html/index.html when genhtml (brew install lcov) is present.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${1:-all}"
RECORD_ARG="${2:-${RECORD_SNAPSHOTS:-false}}"
if [[ "$RECORD_ARG" == "1" || "$RECORD_ARG" == "true" || "$RECORD_ARG" == "record" ]]; then
  RECORD="true"
else
  RECORD="false"
fi

PINNED_DEVICE_NAME="iPhone 18 Pro"

# 1. Resolve Pinned Simulator
BOOTED_PINNED_ID=$(xcrun simctl list devices booted | grep "$PINNED_DEVICE_NAME" | grep -E -o '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -n 1 || true)
DESTINATION="platform=iOS Simulator,name=$PINNED_DEVICE_NAME"
[[ -n "$BOOTED_PINNED_ID" ]] && DESTINATION="platform=iOS Simulator,id=$BOOTED_PINNED_ID"

# 2. Normalize tag to lowercase and validate it against TestingTags.swift so a typo
#    cannot silently run zero tests.
TAG_NAME="$(tr '[:upper:]' '[:lower:]' <<< "$TAG")"
VALID_TAGS=($(grep -E '@Tag static var' "$SCRIPT_DIR/Tests/DigiaEngageTests/TestingTags.swift" | awk '{print $4}' | tr -d ':'))
MODES=("all" "quick")

if [[ "$TAG_NAME" != "all" && "$TAG_NAME" != "quick" ]]; then
  FOUND=false
  for valid in "${VALID_TAGS[@]}"; do
    [[ "$TAG_NAME" == "$valid" ]] && FOUND=true
  done
  if [[ "$FOUND" != "true" ]]; then
    echo "Error: unknown test tag '$TAG'." >&2
    echo "Valid: ${MODES[*]} ${VALID_TAGS[*]}" >&2
    exit 1
  fi
fi

# 3. Translate the tag into xcodebuild's native filter flags.
TAG_FLAGS=()
case "$TAG_NAME" in
  all)   ;;
  quick) TAG_FLAGS=(-skip-testing-tags slow) ;;
  *)     TAG_FLAGS=(-only-testing-tags "$TAG_NAME") ;;
esac

echo "=================================================================="
echo " Digia Engage Test Runner"
echo " Pinned Reference Device : $PINNED_DEVICE_NAME"
echo " Destination Target      : $DESTINATION"
echo " Test Selection          : $TAG_NAME"
echo " Snapshot Record Mode    : $RECORD"
echo "=================================================================="

# 4. Run. `TEST_RUNNER_`-prefixed variables are the ones xcodebuild forwards to the test process.
LOG="$(mktemp -t digia-tests)"
trap 'rm -f "$LOG"' EXIT
DERIVED_DATA="$SCRIPT_DIR/.derivedData/tests"
COVERAGE_DIR="$SCRIPT_DIR/coverage"
cd "$SCRIPT_DIR"
set +e
TEST_RUNNER_RECORD_SNAPSHOTS="$RECORD" xcodebuild test \
  -scheme DigiaEngage \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -enableCodeCoverage YES \
  ${TAG_FLAGS[@]+"${TAG_FLAGS[@]}"} 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e

# 5. xcodebuild reports success when a filter matches nothing; treat that as a failure.
if ! grep -qE '^◇ Test .* started|^Test Case .* started' "$LOG"; then
  echo "Error: no tests ran for '$TAG_NAME'. Is the tag applied to any suite?" >&2
  exit 1
fi

# 6. Export coverage of Sources/ as LCOV, even when tests failed, so partial runs still report.
PROFDATA=$(find "$DERIVED_DATA/Build/ProfileData" -name Coverage.profdata -print0 2>/dev/null \
  | xargs -0 ls -t 2>/dev/null | head -n 1 || true)
TEST_BINARY="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/DigiaEngageTests.xctest/DigiaEngageTests"
COVERAGE_IGNORE='/(Tests|SourcePackages|\.build|\.derivedData)/'
if [[ -n "$PROFDATA" && -f "$TEST_BINARY" ]]; then
  mkdir -p "$COVERAGE_DIR"
  xcrun llvm-cov export -format=lcov \
    -instr-profile "$PROFDATA" "$TEST_BINARY" \
    -ignore-filename-regex "$COVERAGE_IGNORE" > "$COVERAGE_DIR/lcov.info"
  echo "=================================================================="
  xcrun llvm-cov report -instr-profile "$PROFDATA" "$TEST_BINARY" \
    -ignore-filename-regex "$COVERAGE_IGNORE" | tail -n 1
  echo " LCOV report: $COVERAGE_DIR/lcov.info"
  if command -v genhtml >/dev/null 2>&1; then
    rm -rf "$COVERAGE_DIR/html"
    genhtml "$COVERAGE_DIR/lcov.info" -o "$COVERAGE_DIR/html" --quiet >/dev/null
    echo " HTML report: $COVERAGE_DIR/html/index.html"
  else
    echo " HTML report skipped: install lcov (brew install lcov) for genhtml."
  fi
  echo "=================================================================="
else
  echo "Warning: coverage data not found; LCOV report not generated." >&2
fi

exit "$STATUS"
