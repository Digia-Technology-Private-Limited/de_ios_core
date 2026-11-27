#!/bin/bash
# Prints total and per-folder line coverage of the iOS SDK measured from the
# shared YAML suite only (testkit/sdk-tests/...), with the same exclusion
# categories as flutter/core-yaml-poc/tool/yaml_coverage.sh:
#   - generated files (none in Sources/; verified)
#   - debug-only tooling (test kit, debug settings/timeline/recorded-session UI,
#     recording badge, settings toggle, capture, component registry, live test,
#     test view, debug/)
#   - vendored third-party code (none in Sources/; Lottie/SDWebImage are SPM
#     dependencies outside Sources/)
#
# The YAML tests run app-hosted with code coverage enabled (one `xcodebuild
# test` per shard, sequentially); each shard's result bundle holds an xccov
# coverage archive, merged and restricted to the SDK sources under Sources/.
# Usage:
#   tool/yaml_coverage.sh                                          # all YAML tests (2 sequential shards)
#   tool/yaml_coverage.sh tests/nudge/                             # one area
#   tool/yaml_coverage.sh tests/survey/sv35_plain_nav_buttons.yaml # one test
# Wrap it in the buildlock: .yaml-migration/buildlock.sh ios tool/yaml_coverage.sh
set -u
cd "$(dirname "$0")/.."

FILTER="${1:-}"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro Max}"
# An explicit derived-data dir: the shared machine's default DerivedData holds
# other agents' concurrent builds, so resolving the newest .xctestrun there can
# pick up a foreign (non-coverage) build. This isolates the coverage build.
DERIVED_DATA="$PWD/.derivedData/yaml-coverage"
if [ -n "${YAML_SHARDS:-}" ]; then
  SHARDS="$YAML_SHARDS"
elif [ -z "$FILTER" ]; then
  SHARDS=2
else
  SHARDS=1
fi

LOG_DIR="$(mktemp -d -t yaml-ios-coverage)"
LOG="$LOG_DIR/full.log"
COV_DIR="$LOG_DIR/coverage"
mkdir -p "$COV_DIR"
XCRESULTS=()

cleanup() {
  for r in ${XCRESULTS[@]+"${XCRESULTS[@]}"}; do
    rm -rf "$r" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

find_sim_udid() {
  xcrun simctl list devices available | awk -v name="$1" '
    index($0, name " (") {
      match($0, /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/)
      if (RSTART > 0) {
        udid = substr($0, RSTART, RLENGTH)
        if (index($0, "(Booted)")) { print udid; exit }
        if (!first) first = udid
      }
    }
    END { if (first) print first }
  '
}

BASE_UDID="$(find_sim_udid "$SIM_NAME")"
if [ -z "$BASE_UDID" ]; then
  echo "No available iOS simulator named '$SIM_NAME'." >&2
  exit 1
fi

# 1. Build for testing with coverage (timed separately). The later `test`
# actions reuse this build; the explicit derived-data dir isolates the
# coverage build from other agents' concurrent builds on this machine.
build_start=$(date +%s)
BUILD_LOG="$LOG_DIR/build.log"
xcodebuild build-for-testing \
  -project SampleApp/DigiaEngageSample.xcodeproj \
  -scheme DigiaEngageSample \
  -destination "platform=iOS Simulator,id=$BASE_UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -enableCodeCoverage YES \
  > "$BUILD_LOG" 2>&1
build_rc=$?
build_secs=$(( $(date +%s) - build_start ))
cat "$BUILD_LOG" > "$LOG"
if [ "$build_rc" -ne 0 ]; then
  echo "Build failed (exit $build_rc)." >&2
  printf 'Build time: %dm %02ds\n' $((build_secs / 60)) $((build_secs % 60))
  echo "Full log: $LOG"
  exit "$build_rc"
fi

# NOTE: `test-without-building` (used by the normal YAML runner) does not
# merge statically-linked SPM package (SDK) regions into the result bundle's
# coverage archive — verified: its archive holds app/tests/deps only. The
# unified `test` action does, so each shard runs `test` here.
# Shards run sequentially: concurrent `test` actions would fight over the
# build database in the shared derived data.

# 2. Boot the simulator(s), then run one `xcodebuild test` per shard,
# sequentially (concurrent `test` actions would fight over the build database
# in the shared derived data).
test_start=$(date +%s)
UDIDS=("$BASE_UDID")
if [ "$SHARDS" -gt 1 ]; then
  need_clone=()
  for ((i = 1; i < SHARDS; i++)); do
    worker_name="${SIM_NAME} (YAML Worker $((i + 1)))"
    worker_id="$(find_sim_udid "$worker_name")"
    if [ -n "$worker_id" ]; then
      UDIDS+=("$worker_id")
    else
      need_clone+=("$worker_name")
    fi
  done
  if [ -n "${need_clone[0]:-}" ]; then
    xcrun simctl shutdown "$BASE_UDID" 2>/dev/null || true
    for worker_name in "${need_clone[@]}"; do
      clone_id="$(xcrun simctl clone "$BASE_UDID" "$worker_name")"
      [ -n "$clone_id" ] && UDIDS+=("$clone_id")
    done
  fi
fi
booted_list="$(xcrun simctl list devices booted)"
to_boot=()
for u in "${UDIDS[@]}"; do
  case "$booted_list" in
    *"$u"*) ;;
    *) to_boot+=("$u") ;;
  esac
done
if [ -n "${to_boot[0]:-}" ]; then
  for u in "${to_boot[@]}"; do
    xcrun simctl boot "$u" 2>/dev/null &
  done
  wait
  for u in "${to_boot[@]}"; do
    xcrun simctl bootstatus "$u" -b >/dev/null 2>&1 &
  done
  wait
fi

SHARD_LOGS=()
code=0
for ((i = 0; i < SHARDS; i++)); do
  sim="${UDIDS[$(( i % ${#UDIDS[@]} ))]}"
  s_log="$LOG_DIR/shard-$i.log"
  s_res="$LOG_DIR/shard-$i.xcresult"
  SHARD_LOGS+=("$s_log")
  XCRESULTS+=("$s_res")
  env_args=("TEST_RUNNER_SWIFT_DETERMINISTIC_HASHING=1")
  [ -n "$FILTER" ] && env_args+=("TEST_RUNNER_YAML_FILTER=$FILTER")
  [ "$SHARDS" -gt 1 ] && env_args+=("TEST_RUNNER_YAML_SHARD=$i/$SHARDS")
  env ${env_args[@]+"${env_args[@]}"} xcodebuild test \
    -project SampleApp/DigiaEngageSample.xcodeproj \
    -scheme DigiaEngageSample \
    -destination "platform=iOS Simulator,id=$sim" \
    -derivedDataPath "$DERIVED_DATA" \
    -parallel-testing-enabled NO \
    -enableCodeCoverage YES \
    -resultBundlePath "$s_res" \
    "-only-testing:DigiaEngageSampleTests/YamlSdkTests" \
    > "$s_log" 2>&1 || code=1
done
test_secs=$(( $(date +%s) - test_start ))

for ((i = 0; i < SHARDS; i++)); do
  echo "===== SHARD $i/$SHARDS =====" >> "$LOG"
  cat "${SHARD_LOGS[$i]}" >> "$LOG"
done

# 3. Export SDK coverage: each shard's result bundle holds an xccov coverage
# archive with per-line execution counts. Dump one JSON archive per shard and
# merge them in Python (a line counts as covered if any shard hit it),
# restricted to the SDK sources under Sources/.
PARTS=()
for ((i = 0; i < SHARDS; i++)); do
  part="$COV_DIR/shard-$i.archive.json"
  if xcrun xccov view --archive --json "${XCRESULTS[$i]}" > "$part" 2>"$COV_DIR/shard-$i.err"; then
    PARTS+=("$part")
  else
    echo "Warning: xccov archive export failed for shard $i; see $COV_DIR/shard-$i.err." >&2
  fi
done

if [[ ${#PARTS[@]} -eq 0 ]]; then
  echo "error: no coverage data exported." >&2
  echo "Result bundles kept for inspection:" >&2
  printf '  %s\n' "${XCRESULTS[@]}" >&2
  XCRESULTS=()
  exit 1
fi

# Coverage is exported; drop the bulky result bundles.
for r in "${XCRESULTS[@]}"; do
  rm -rf "$r" 2>/dev/null || true
done
XCRESULTS=()

# 4. Report: SDK sources only, with the cross-stack exclusions.
python3 - "$LOG_DIR" "$FILTER" <<'PY'
import fnmatch
import glob
import json
import os
import re
import sys
from collections import defaultdict

log_dir, filter_arg = sys.argv[1], sys.argv[2]
part_paths = sorted(glob.glob(os.path.join(log_dir, "coverage", "shard-*.archive.json")))
shard_logs = sorted(glob.glob(os.path.join(log_dir, "shard-*.log")))

SDK_MARKER = "ios/core-yaml-poc/Sources/DigiaEngage/"
EXCLUSIONS = [
    # Generated files: none in Sources/ (verified). Category kept for comparability.
    # Debug-only tooling (mirrors flutter's yaml_coverage.sh exclusions):
    ("debug-only", "api/DigiaTestKit.swift"),                 # lib/api/digia_test_kit.dart
    ("debug-only", "api/internal/canvas/TestView.swift"),     # lib/api/internal/test_view.dart
    ("debug-only", "api/internal/debug/*"),                   # lib/src/debug/* (+ debug deeplink handling)
    ("debug-only", "api/widgets/DigiaDebugSettingsView.swift"),     # lib/api/widgets/digia_debug_settings_screen.dart
    ("debug-only", "api/widgets/DigiaCampaignTimelineView.swift"),  # lib/api/widgets/digia_campaign_timeline_screen.dart
    ("debug-only", "api/widgets/DigiaRecordedSessionScreen.swift"),  # lib/api/widgets/digia_recorded_session_screen.dart
    ("debug-only", "api/widgets/RecordingBadgeView.swift"),          # lib/api/widgets/digia_recording_badge.dart
    ("debug-only", "api/widgets/SettingsToggleRow.swift"),           # lib/src/debug/settings_toggle_row.dart
    ("debug-only", "capture/*"),                              # lib/src/capture/*
    ("debug-only", "api/internal/componentregistry/*"),      # lib/src/component_registry/*
    ("debug-only", "api/internal/livetest/*"),               # lib/src/live_test/*
    # Vendored third-party code: none in Sources/ (verified; Lottie/SDWebImage
    # are SPM dependencies outside Sources/).
]

def exclusion_reason(path):
    for reason, pattern in EXCLUSIONS:
        if fnmatch.fnmatch(path, pattern):
            return reason
    return None

line_exec = {}  # rel path -> set of executable line numbers
line_hit = {}   # rel path -> {line number: covered in any shard}
for part in part_paths:
    with open(part, encoding="utf-8") as f:
        archive = json.load(f)
    for abspath, entries in archive.items():
        if SDK_MARKER not in abspath:
            continue
        rel = abspath.split(SDK_MARKER, 1)[1]
        execs = line_exec.setdefault(rel, set())
        hits = line_hit.setdefault(rel, {})
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not entry.get("isExecutable", False):
                continue
            ln = entry.get("line")
            execs.add(ln)
            if entry.get("executionCount", 0) > 0:
                hits[ln] = True
            else:
                hits.setdefault(ln, False)

files = {}
for rel, execs in line_exec.items():
    hits = line_hit.get(rel, {})
    files[rel] = [sum(1 for ln in execs if hits.get(ln, False)), len(execs)]

included_folders = defaultdict(lambda: [0, 0])
excluded_files = []
total_hit = total_found = 0
for path in sorted(files):
    hit, found = files[path]
    if found == 0:
        continue
    reason = exclusion_reason(path)
    if reason is not None:
        excluded_files.append((path, reason, hit, found))
        continue
    total_hit += hit
    total_found += found
    folder = os.path.dirname(path) or "."
    included_folders[folder][0] += hit
    included_folders[folder][1] += found

total_pct = (100.0 * total_hit / total_found) if total_found else 100.0
total_unc = total_found - total_hit
print(f"Total coverage (YAML suite only, with exclusions): {total_pct:.2f}% ({total_hit}/{total_found} lines, {total_unc} uncovered)")
print()
print(f"{'Folder':<48} {'Hit':>6} {'Total':>6} {'Uncov':>6} {'Cov%':>7}")
print("-" * 77)
rows = []
for folder, (h, f) in included_folders.items():
    unc = f - h
    pct = (100.0 * h / f) if f else 100.0
    rows.append((unc, folder, h, f, pct))
for unc, folder, h, f, pct in sorted(rows, key=lambda r: (-r[0], r[1])):
    print(f"{folder:<48} {h:>6} {f:>6} {unc:>6} {pct:>6.2f}%")

print()
print(f"Excluded paths ({len(excluded_files)} files in export):")
for path, reason, h, f in excluded_files:
    pct = (100.0 * h / f) if f else 100.0
    print(f"  [{reason}] {path} ({h}/{f} = {pct:.1f}%)")

# Test counts from the shard logs + skip headers (mirrors run_yaml_tests.sh).
total_run = 0
fails = set()
for s_log in shard_logs:
    try:
        text = open(s_log, encoding="utf-8", errors="replace").read()
    except FileNotFoundError:
        continue
    for m in re.finditer(r"Test \"runs the shared YAML file\" with ([0-9]+) test cases?", text):
        total_run += int(m.group(1))
    for m in re.finditer(r"↳ FAIL (tests/\S+)", text):
        fails.add(re.sub(r":[0-9]+$", "", m.group(1)))
fail_count = len(fails)
pass_count = max(total_run - fail_count, 0)

skip_count = 0
parts = [p for p in filter_arg.split(",") if p] if filter_arg else []
for path in glob.glob("../../testkit/sdk-tests/tests/**/*.yaml", recursive=True):
    rel = "tests/" + path.split("testkit/sdk-tests/tests/", 1)[1]
    if parts and not any(p in rel for p in parts):
        continue
    head = open(path, encoding="utf-8", errors="ignore").read().split("---", 1)[0]
    in_skip = False
    for line in head.splitlines():
        if re.match(r"^skip\s*:", line):
            in_skip = True
            continue
        if in_skip:
            if line.startswith((" ", "\t")):
                if re.match(r"^\s+ios\s*:", line):
                    skip_count += 1
                    break
            elif line.strip() and not line.lstrip().startswith("#"):
                in_skip = False

print()
print(f"Tests: Pass: {pass_count}  Skip: {skip_count}  Fail: {fail_count}  (Total run: {total_run})")
if fails:
    print("Failing:")
    for name in sorted(fails):
        print(f"  {name}")
PY

printf 'Build time: %dm %02ds\n' $((build_secs / 60)) $((build_secs % 60))
printf 'Test time:  %dm %02ds\n' $((test_secs / 60)) $((test_secs % 60))
echo "Full log: $LOG"
exit "$code"
