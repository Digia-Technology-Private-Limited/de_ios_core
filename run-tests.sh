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
#
# Allure: every run converts the Xcode result bundle into raw results in allure-results/ (cleared first) and
# builds the HTML report in reports/allure-report/ whenever results exist, even if tests failed. The exit code
# is always the tests'. Needs the Allure CLI (`brew install allure`) and python3.
#   ALLURE_KEEP_RESULTS=true ./run-tests.sh unit   keep existing allure-results/ and add to them, to
#                                                  aggregate several runs into one report
#   ./run-tests.sh --report                        rebuild the HTML report from allure-results/ without running tests
#   ./run-tests.sh --open                          serve reports/allure-report/ in the browser
#                                                  (a report must be served; file:// shows nothing)
# Failed snapshot tests carry their expected / actual / diff images in the report.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLURE_RESULTS="$SCRIPT_DIR/allure-results"
ALLURE_REPORT="$SCRIPT_DIR/reports/allure-report"

# Builds the HTML report from the raw results. A failure here is reported, not fatal: it must not change
# the exit code of the test run.
generate_allure_report() {
  if ! command -v allure >/dev/null 2>&1; then
    echo "Allure: CLI not found, so no HTML report. Install it with 'brew install allure'; raw results are in allure-results/" >&2
    return 1
  fi
  if ! compgen -G "$ALLURE_RESULTS/*-result.json" >/dev/null; then
    echo "Allure: no results in allure-results/, so no HTML report. Run the tests first." >&2
    return 1
  fi
  mkdir -p "$(dirname "$ALLURE_REPORT")"
  allure generate "$ALLURE_RESULTS" --clean -o "$ALLURE_REPORT" >/dev/null &&
    echo "Allure report: reports/allure-report/index.html (open it with ./run-tests.sh --open)"
}

case "${1:-}" in
  --report)
    generate_allure_report && exit 0 || exit 1
    ;;
  --open)
    if [[ ! -f "$ALLURE_REPORT/index.html" ]]; then
      echo "No report at reports/allure-report/. Run the tests, or ./run-tests.sh --report." >&2
      exit 1
    fi
    command -v allure >/dev/null 2>&1 || { echo "Allure CLI not found. Install it with 'brew install allure'." >&2; exit 1; }
    exec allure open "$ALLURE_REPORT"
    ;;
esac

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
RESULT_BUNDLE="$DERIVED_DATA/allure.xcresult"
# xcodebuild refuses to overwrite a result bundle, and stale Allure results would be mixed into this run's report.
rm -rf "$RESULT_BUNDLE"
[[ "${ALLURE_KEEP_RESULTS:-false}" == "true" ]] || rm -rf "$ALLURE_RESULTS"
set +e
TEST_RUNNER_RECORD_SNAPSHOTS="$RECORD" xcodebuild test \
  -scheme DigiaEngage \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -enableCodeCoverage YES \
  -resultBundlePath "$RESULT_BUNDLE" \
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

# 7. Allure: convert the result bundle, then build the report. Neither may change the exit code.
if [[ -d "$RESULT_BUNDLE" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    python3 -I "$SCRIPT_DIR/Scripts/xcresult-to-allure.py" "$RESULT_BUNDLE" "$ALLURE_RESULTS" || echo "Warning: converting the result bundle to Allure results failed." >&2
  else
    echo "Allure: python3 not found, so the result bundle was not converted." >&2
  fi
fi
generate_allure_report || true

exit "$STATUS"
