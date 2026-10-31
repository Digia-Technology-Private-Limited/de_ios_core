#!/bin/bash
set -Eeuo pipefail

# Runs the SampleApp fixture-based test suite (actions, fixture behaviour, and the anchorless goldens, which
# need the app's window scene) on an iOS Simulator. Every other golden is a package test.
# The package tests (Tests/DigiaEngageTests) run through ./run-tests.sh instead.
#
#   ./run-sample-tests.sh                                run every test
#   ./run-sample-tests.sh actions                        run only tests tagged `actions` (any tag declared in
#                                                 Tests/DigiaEngageTests/TestingTags.swift, as for ./run-tests.sh)
#   RECORD_SNAPSHOTS=true ./run-sample-tests.sh          re-record the anchorless golden baselines instead of
#                                                 comparing
#
# The tests live in the DigiaEngageSampleTests target and run inside the sample app: the package's own
# test bundle has no UIApplication, so a surface that needs a window cannot be shown from it. They read
# the shared campaigns from ../../sdk_testing_fixtures and the media from ../../testkit/mock-server.
#
# A tag selects suites by their Swift Testing tags (`.tags(...)`), through `xcodebuild -only-testing-tags`.
# It is checked against TestingTags.swift first, and a tag that runs no test fails the run, so a typo is
# reported instead of silently matching nothing.
#
# The full xcodebuild output is kept in build/test-report/xcodebuild.log.
#
# Line coverage: the per-file summary is written as JSON to build/test-report/coverage.json.
#
# Allure: every run writes raw results to allure-results/ (cleared first) and builds the HTML report in
# reports/allure-report/ whenever results exist, even if tests failed. The exit code is always
# xcodebuild's. Needs the Allure CLI (`brew install allure`); without it the raw results are still written.
#
#   ALLURE_KEEP_RESULTS=true ./run-sample-tests.sh actions  keep existing allure-results/ and add to them
#   ./run-sample-tests.sh --report                          rebuild the HTML report from allure-results/
#                                                    without running tests
#   ./run-sample-tests.sh --open                            serve reports/allure-report/ in the browser

cd "$(dirname "$0")"

VALID_TAGS=" $(grep -E '@Tag static var' Tests/DigiaEngageTests/TestingTags.swift | awk '{print $4}' | tr -d ':' | tr '\n' ' ')"

# One pinned device and OS: goldens are rasterised by the simulator's own pipeline. Override with
# SIMULATOR_NAME / SIMULATOR_OS (e.g. SIMULATOR_NAME="iPhone 17e" SIMULATOR_OS=26.5).
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro Max}"
SIMULATOR_OS="${SIMULATOR_OS:-26.5}"

derived_data=.derivedData/tests
result_bundle=.derivedData/tests.xcresult
results_dir=allure-results
allure_report_dir=reports/allure-report
report_dir=build/test-report

generate_allure_report() {
  if ! command -v allure >/dev/null; then
    echo "Allure: CLI not found, so no HTML report. Install it with 'brew install allure'; raw results are in $results_dir/" >&2
    return 1
  fi
  if ! compgen -G "$results_dir/*-result.json" >/dev/null; then
    echo "Allure: no results in $results_dir/, so no HTML report. Run the tests first." >&2
    return 1
  fi
  mkdir -p "$(dirname "$allure_report_dir")"
  allure generate "$results_dir" --clean -o "$allure_report_dir" >/dev/null &&
    echo "Allure report: $allure_report_dir/index.html (open it with ./run-sample-tests.sh --open)"
}

case "${1:-}" in
  --report)
    generate_allure_report && exit 0 || exit 1
    ;;
  --open)
    if [[ ! -f "$allure_report_dir/index.html" ]]; then
      echo "No report at $allure_report_dir/. Run the tests, or ./run-sample-tests.sh --report." >&2
      exit 1
    fi
    command -v allure >/dev/null || { echo "Allure CLI not found. Install it with 'brew install allure'." >&2; exit 1; }
    exec allure open "$allure_report_dir"
    ;;
esac

# A tag narrows the run to the suites and tests that carry it.
only_testing=()
if [[ -n "${1:-}" ]]; then
  if [[ "$VALID_TAGS " != *" $1 "* ]]; then
    echo "Unknown tag '$1'. Valid tags:" >&2
    for tag in $VALID_TAGS; do echo "  $tag" >&2; done
    exit 2
  fi
  only_testing=(-only-testing-tags "$1")
fi

# The pinned simulator, created when this machine has none, and booted.
udid=$(xcrun simctl list devices available | grep -F "    $SIMULATOR_NAME (" | head -1 | grep -oE '[0-9A-F-]{36}' || true)
if [[ -z "$udid" ]]; then
  runtime="com.apple.CoreSimulator.SimRuntime.iOS-${SIMULATOR_OS//./-}"
  device_type="com.apple.CoreSimulator.SimDeviceType.${SIMULATOR_NAME// /-}"
  udid=$(xcrun simctl create "$SIMULATOR_NAME" "$device_type" "$runtime")
fi
xcrun simctl boot "$udid" 2>/dev/null || true

xcargs=()
if [[ "${RECORD_SNAPSHOTS:-false}" == "true" ]]; then
  # xcodebuild hands TEST_RUNNER_-prefixed variables to the test process, without the prefix.
  export TEST_RUNNER_RECORD_SNAPSHOTS=true
fi

# Stale results from an earlier run would be mixed into this run's report.
if [[ "${ALLURE_KEEP_RESULTS:-false}" != "true" ]]; then
  rm -rf "$results_dir"
fi
mkdir -p "$results_dir"
rm -rf "$result_bundle" "$report_dir"
mkdir -p "$report_dir"

set +e
xcodebuild test \
  -project SampleApp/DigiaEngageSample.xcodeproj \
  -scheme DigiaEngageSample \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -enableCodeCoverage YES \
  ${only_testing[@]+"${only_testing[@]}"} \
  2>&1 | tee "$report_dir/xcodebuild.log" | grep --line-buffered -E '^(✔|✘|↳|\*\* TEST|error:|.*: error:)'
status=${PIPESTATUS[0]}
set -e

# xcodebuild reports success when a tag matches nothing; treat that as a failure.
if [[ -n "${1:-}" && "$status" -eq 0 ]] && ! grep -qE '^◇ Test .* started|^Test Case .* started' "$report_dir/xcodebuild.log"; then
  echo "No test is tagged '$1' in DigiaEngageSampleTests." >&2
  status=1
fi

if [[ -d "$result_bundle" ]]; then
  python3 -I Scripts/xcresult-to-allure.py "$result_bundle" "$results_dir" || true
  xcrun xccov view --report --json "$result_bundle" >"$report_dir/coverage.json" 2>/dev/null &&
    echo "Coverage: $report_dir/coverage.json" || true
fi
generate_allure_report || true
exit "$status"
