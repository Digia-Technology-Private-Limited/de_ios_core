#!/bin/bash
set -Eeuo pipefail

# Runs the fixture-based test suite (goldens, actions, fixture behaviour) on an iOS Simulator.
#
#   ./run-tests.sh                                run every test
#   ./run-tests.sh golden                         run only tests tagged `golden` (any tag below:
#                                                 kind    - golden, action, widget
#                                                 surface - nudge, canvas, floater, survey, pip, guide, inline)
#   RECORD_SNAPSHOTS=true ./run-tests.sh golden   re-record every golden baseline instead of comparing
#                                                 (tolerance: VisualRegression/Support/GoldenHarness.swift)
#
# The tests live in the DigiaEngageSampleTests target and run inside the sample app: the package's own
# test bundle has no UIApplication, so a surface that needs a window cannot be shown from it. They read
# the shared campaigns from ../../sdk_testing_fixtures and the media from ../../testkit/mock-server.
#
# A test file declares its tags in a `// tags: golden nudge` line; this script runs the suites in the
# files that carry the tag. Declare a new tag in VALID_TAGS first, so a typo is reported instead of
# silently matching nothing.
#
# The full xcodebuild output is kept in build/test-report/xcodebuild.log.
#
# Line coverage: the per-file summary is written as JSON to build/test-report/coverage.json.
#
# Allure: every run writes raw results to allure-results/ (cleared first) and builds the HTML report in
# reports/allure-report/ whenever results exist, even if tests failed. The exit code is always
# xcodebuild's. Needs the Allure CLI (`brew install allure`); without it the raw results are still written.
#
#   ALLURE_KEEP_RESULTS=true ./run-tests.sh action   keep existing allure-results/ and add to them
#   ./run-tests.sh --report                          rebuild the HTML report from allure-results/
#                                                    without running tests
#   ./run-tests.sh --open                            serve reports/allure-report/ in the browser

cd "$(dirname "$0")"

VALID_TAGS="golden action widget nudge canvas floater survey pip guide inline"

# One pinned device and OS: goldens are rasterised by the simulator's own pipeline.
SIMULATOR_NAME="iPhone 18 Pro"
SIMULATOR_OS="27.0"

tests_dir=SampleApp/DigiaEngageSampleTests
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
    echo "Allure report: $allure_report_dir/index.html (open it with ./run-tests.sh --open)"
}

case "${1:-}" in
  --report)
    generate_allure_report && exit 0 || exit 1
    ;;
  --open)
    if [[ ! -f "$allure_report_dir/index.html" ]]; then
      echo "No report at $allure_report_dir/. Run the tests, or ./run-tests.sh --report." >&2
      exit 1
    fi
    command -v allure >/dev/null || { echo "Allure CLI not found. Install it with 'brew install allure'." >&2; exit 1; }
    exec allure open "$allure_report_dir"
    ;;
esac

# A tag narrows the run to the suites in the files that carry it.
only_testing=()
if [[ -n "${1:-}" ]]; then
  if [[ " $VALID_TAGS " != *" $1 "* ]]; then
    echo "Unknown tag '$1'. Valid tags:" >&2
    for tag in $VALID_TAGS; do echo "  $tag" >&2; done
    exit 2
  fi
  while IFS= read -r file; do
    while IFS= read -r suite; do
      only_testing+=("-only-testing:DigiaEngageSampleTests/$suite")
    done < <(grep -oE '^(final )?(struct|class) [A-Za-z0-9_]+' "$file" | awk '{print $NF}')
  done < <(grep -rlE "^// tags:.*\b$1\b" "$tests_dir" --include='*.swift' || true)
  if [[ ${#only_testing[@]} -eq 0 ]]; then
    echo "No test file is tagged '$1' yet." >&2
    exit 2
  fi
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

if [[ -d "$result_bundle" ]]; then
  python3 -I Scripts/xcresult-to-allure.py "$result_bundle" "$results_dir" || true
  xcrun xccov view --report --json "$result_bundle" >"$report_dir/coverage.json" 2>/dev/null &&
    echo "Coverage: $report_dir/coverage.json" || true
fi
generate_allure_report || true
exit "$status"
