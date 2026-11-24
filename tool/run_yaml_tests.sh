#!/bin/bash
# Runs the shared YAML SDK tests on iOS and reports build time and test time separately.
# Usage:
#   tool/run_yaml_tests.sh                                          # all YAML tests (2 parallel simulator shards)
#   tool/run_yaml_tests.sh tests/nudge/                             # one area
#   tool/run_yaml_tests.sh tests/survey/sv35_plain_nav_buttons.yaml # one test
set -u
cd "$(dirname "$0")/.."

FILTER="${1:-}"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro Max}"
if [ -n "${YAML_SHARDS:-}" ]; then
  SHARDS="$YAML_SHARDS"
elif [ -z "$FILTER" ]; then
  SHARDS=2
else
  SHARDS=1
fi

LOG_DIR="$(mktemp -d -t yaml-ios-tests)"
LOG="$LOG_DIR/full.log"
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

# Resolve base simulator UDID (prefer already-booted match, else first available match).
BASE_UDID="$(find_sim_udid "$SIM_NAME")"
if [ -z "$BASE_UDID" ]; then
  echo "No available iOS simulator named '$SIM_NAME'." >&2
  exit 1
fi

# 1. Build for testing (timed separately).
build_start=$(date +%s)
BUILD_LOG="$LOG_DIR/build.log"
xcodebuild build-for-testing \
  -project SampleApp/DigiaEngageSample.xcodeproj \
  -scheme DigiaEngageSample \
  -destination "platform=iOS Simulator,id=$BASE_UDID" \
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

XCTESTRUN="$(ls -t "$HOME"/Library/Developer/Xcode/DerivedData/DigiaEngageSample-*/Build/Products/*.xctestrun 2>/dev/null | head -1)"
if [ -z "$XCTESTRUN" ]; then
  echo "Could not locate .xctestrun product after build-for-testing." >&2
  exit 1
fi

# 2. Prepare simulator(s) and run tests (timed separately).
test_start=$(date +%s)
UDIDS=("$BASE_UDID")

if [ "$SHARDS" -gt 1 ]; then
  # Reuse persistent worker simulator(s) so repeated runs avoid clone + cold-boot overhead.
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
    # simctl clone requires the source simulator to be Shutdown.
    xcrun simctl shutdown "$BASE_UDID" 2>/dev/null || true
    for worker_name in "${need_clone[@]}"; do
      clone_id="$(xcrun simctl clone "$BASE_UDID" "$worker_name")"
      [ -n "$clone_id" ] && UDIDS+=("$clone_id")
    done
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
else
  case "$(xcrun simctl list devices booted)" in
    *"$BASE_UDID"*) ;;
    *)
      xcrun simctl boot "$BASE_UDID" 2>/dev/null || true
      xcrun simctl bootstatus "$BASE_UDID" -b >/dev/null 2>&1 || true
      ;;
  esac
fi

ACTUAL_SHARDS=${#UDIDS[@]}
PIDS=()
SHARD_LOGS=()
for ((i = 0; i < ACTUAL_SHARDS; i++)); do
  s_log="$LOG_DIR/shard-$i.log"
  s_res="$LOG_DIR/shard-$i.xcresult"
  SHARD_LOGS+=("$s_log")
  XCRESULTS+=("$s_res")
  env_args=("TEST_RUNNER_SWIFT_DETERMINISTIC_HASHING=1")
  [ -n "$FILTER" ] && env_args+=("TEST_RUNNER_YAML_FILTER=$FILTER")
  [ "$ACTUAL_SHARDS" -gt 1 ] && env_args+=("TEST_RUNNER_YAML_SHARD=$i/$ACTUAL_SHARDS")
  env ${env_args[@]+"${env_args[@]}"} xcodebuild test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "platform=iOS Simulator,id=${UDIDS[$i]}" \
    -parallel-testing-enabled NO \
    -resultBundlePath "$s_res" \
    "-only-testing:DigiaEngageSampleTests/YamlSdkTests" \
    > "$s_log" 2>&1 &
  PIDS+=($!)
done

code=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || code=1
done
test_secs=$(( $(date +%s) - test_start ))

for ((i = 0; i < ACTUAL_SHARDS; i++)); do
  echo "===== SHARD $i/$ACTUAL_SHARDS =====" >> "$LOG"
  cat "${SHARD_LOGS[$i]}" >> "$LOG"
done

# Count runnable, pass, fail, and skipped from shard logs + testkit headers.
total_run=$(grep -hEo 'Test "runs the shared YAML file" with [0-9]+ test cases?' "${SHARD_LOGS[@]}" | awk '{s += $8} END {print s+0}')
fails=$(grep -hE '↳ FAIL tests/' "${SHARD_LOGS[@]}" | sed -E 's/.*↳ FAIL //' | sort -u)
if [ -n "$fails" ]; then
  fail_count=$(printf '%s\n' "$fails" | sed -E 's/:[0-9]+$//' | sort -u | wc -l | tr -d ' ')
else
  fail_count=0
fi
pass_count=$(( total_run - fail_count ))
[ "$pass_count" -lt 0 ] && pass_count=0

# Count files skipped on iOS (matching the filter, if any).
skip_count=$(python3 - "$FILTER" <<'PY'
import glob, re, sys
flt = sys.argv[1]
parts = [p for p in flt.split(",") if p] if flt else []
n = 0
for f in glob.glob("../../testkit/sdk-tests/tests/**/*.yaml", recursive=True):
    rel = "tests/" + f.split("testkit/sdk-tests/tests/", 1)[1]
    if parts and not any(p in rel for p in parts):
        continue
    head = open(f, encoding="utf-8", errors="ignore").read().split("---", 1)[0]
    in_skip = False
    for line in head.splitlines():
        if re.match(r"^skip\s*:", line):
            in_skip = True
            continue
        if in_skip:
            if line.startswith((" ", "\t")):
                if re.match(r"^\s+ios\s*:", line):
                    n += 1
                    break
            elif line.strip() and not line.lstrip().startswith("#"):
                in_skip = False
print(n)
PY
)

echo "Pass: $pass_count  Skip: ${skip_count:-0}  Fail: $fail_count"
if [ -n "$fails" ]; then
  echo "Failing:"
  printf '%s\n' "$fails" | sed 's/^/  /'
fi
printf 'Build time: %dm %02ds\n' $((build_secs / 60)) $((build_secs % 60))
printf 'Test time:  %dm %02ds\n' $((test_secs / 60)) $((test_secs % 60))
echo "Full log: $LOG"
exit "$code"
