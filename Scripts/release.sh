#!/bin/bash
set -Eeuo pipefail

# End-to-end Digia Engage iOS release workflow.
#
# Usage: ./Scripts/release.sh [--dry-run] <new_version>
# Examples:
#   ./Scripts/release.sh --dry-run 3.7.0
#   ./Scripts/release.sh 3.7.0
#
# This script intentionally performs external, irreversible actions: it commits
# and pushes the three release files, pushes a git tag, creates a GitHub Release,
# uploads the fat XCFramework, and publishes the pod to CocoaPods trunk.

readonly EXPECTED_BRANCH="main"
readonly POD_NAME="DigiaEngage"
readonly PODSPEC="DigiaEngage.podspec"
readonly SDK_VERSION_FILE="Sources/DigiaEngage/SdkVersion.swift"
readonly CHANGELOG="CHANGELOG.md"
readonly BUILD_SCRIPT="Scripts/build-fat-xcframework.sh"
readonly XCFRAMEWORK="dist/DigiaEngage.xcframework"
readonly ZIP_PATH="dist/DigiaEngage.xcframework.zip"
readonly -a RELEASE_FILES=(
  "$CHANGELOG"
  "$PODSPEC"
  "$SDK_VERSION_FILE"
)

VERSION=""
VERSION_REGEX=""
DRY_RUN=0
TOTAL_STEPS=12
BRANCH=""
GH_REPO=""
BASE_VERSION=""
LATEST_RELEASED_TAG=""
PODSPEC_SOURCE_URL=""
RELEASE_COMMIT=""
RELEASE_URL=""
RUN_DIR=""
NOTES_FILE=""
ORIGINAL_REPO_ROOT=""
VALIDATION_REPO=""
ORIGINAL_STATUS=""
ORIGINAL_HEAD=""
ORIGINAL_REFS=""
ORIGINAL_FILE_HASHES=""
ORIGINAL_INDEX_HASH=""
CURRENT_STEP="Startup"
NEXT_STEP="Fix the reported problem and rerun the release command."
FAILURE_REASON=""
STEP_NUMBER=0
REPORTING_FAILURE=0
PASSED_STEPS=()

usage() {
  cat <<'EOF'
Usage:
  ./Scripts/release.sh <new_version>
  ./Scripts/release.sh --dry-run <new_version>

Examples:
  ./Scripts/release.sh 3.7.0
  ./Scripts/release.sh --dry-run 3.7.0

Before running:
  - Commit the release tooling itself.
  - Keep release notes in the top CHANGELOG.md [Unreleased] section (or use an
    already-bumped top section when resuming before the release commit).
  - Ensure main matches origin/main.
  - Authenticate GitHub CLI and CocoaPods trunk.

The script commits only:
  CHANGELOG.md
  DigiaEngage.podspec
  Sources/DigiaEngage/SdkVersion.swift

Dry-run mode:
  Performs the version simulation, tests, XCFramework build, artifact checks,
  and pod lint inside a disposable temporary clone. It never modifies the real
  checkout/index/refs or performs a commit, push, tag, GitHub Release creation,
  upload, CocoaPods publication, or other remote write. Temporary compiler and
  validation files are deleted automatically at exit.
EOF
}

cleanup() {
  if [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ]; then
    rm -rf "$RUN_DIR"
  fi
}

print_passed_steps() {
  if [ "${#PASSED_STEPS[@]}" -eq 0 ]; then
    echo "  None — the release stopped before the first step completed." >&2
    return
  fi

  local passed
  for passed in "${PASSED_STEPS[@]}"; do
    echo "  ✓ $passed" >&2
  done
}

on_error() {
  local status=$1
  local command=$2

  if [ "$REPORTING_FAILURE" -eq 1 ]; then
    exit "$status"
  fi
  REPORTING_FAILURE=1

  echo "" >&2
  echo "============================================================" >&2
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN FAILED (no release was performed)" >&2
  else
    echo "RELEASE FAILED" >&2
  fi
  echo "Step: $CURRENT_STEP" >&2
  if [ -n "$FAILURE_REASON" ]; then
    echo "Why: $FAILURE_REASON" >&2
  else
    echo "Why: command exited with status $status: $command" >&2
  fi
  echo "" >&2
  echo "Steps that passed:" >&2
  print_passed_steps
  echo "" >&2
  echo "Suggested next step:" >&2
  echo "  $NEXT_STEP" >&2
  echo "============================================================" >&2
  exit "$status"
}

on_signal() {
  FAILURE_REASON="The release was interrupted by a signal."
  on_error 130 "signal"
}

trap cleanup EXIT
trap 'on_error "$?" "$BASH_COMMAND"' ERR
trap on_signal INT TERM

fail() {
  FAILURE_REASON=$1
  return 1
}

require_live_mode() {
  local operation=$1
  [ "$DRY_RUN" -eq 0 ] || fail "Internal safety guard blocked '$operation' because --dry-run is active."
}

run_step() {
  local label=$1
  local next_step=$2
  local success_reason=$3
  shift 3

  STEP_NUMBER=$((STEP_NUMBER + 1))
  CURRENT_STEP="$label"
  NEXT_STEP="$next_step"
  FAILURE_REASON=""

  echo ""
  echo "[$STEP_NUMBER/$TOTAL_STEPS] $label"
  "$@"
  PASSED_STEPS+=("$label — $success_reason")
  echo "✓ Passed: $success_reason"
}

validate_semver() {
  local version=$1
  local core prerelease major minor patch extra identifier
  local -a identifiers=()

  if [[ "$version" == *+* ]]; then
    return 1
  fi

  core=${version%%-*}
  if [[ "$version" == *-* ]]; then
    prerelease=${version#*-}
  else
    prerelease=""
  fi

  IFS='.' read -r major minor patch extra <<< "$core"
  if [ -n "${extra:-}" ] || [ -z "${major:-}" ] || [ -z "${minor:-}" ] || [ -z "${patch:-}" ]; then
    return 1
  fi

  for identifier in "$major" "$minor" "$patch"; do
    if ! [[ "$identifier" =~ ^(0|[1-9][0-9]*)$ ]]; then
      return 1
    fi
  done

  if [[ "$version" == *-* ]]; then
    if [ -z "$prerelease" ]; then
      return 1
    fi
    IFS='.' read -ra identifiers <<< "$prerelease"
    for identifier in "${identifiers[@]}"; do
      if ! [[ "$identifier" =~ ^[0-9A-Za-z-]+$ ]]; then
        return 1
      fi
      if [[ "$identifier" =~ ^[0-9]+$ ]] && [[ "$identifier" =~ ^0[0-9]+$ ]]; then
        return 1
      fi
    done
  fi

  return 0
}

semver_is_greater() {
  local candidate=$1
  local current=$2
  local candidate_core current_core candidate_pre current_pre
  local candidate_major candidate_minor candidate_patch
  local current_major current_minor current_patch
  local candidate_id current_id
  local index max
  local -a candidate_ids=() current_ids=()

  candidate_core=${candidate%%-*}
  current_core=${current%%-*}
  if [[ "$candidate" == *-* ]]; then candidate_pre=${candidate#*-}; else candidate_pre=""; fi
  if [[ "$current" == *-* ]]; then current_pre=${current#*-}; else current_pre=""; fi

  IFS='.' read -r candidate_major candidate_minor candidate_patch <<< "$candidate_core"
  IFS='.' read -r current_major current_minor current_patch <<< "$current_core"

  if ((10#$candidate_major != 10#$current_major)); then
    ((10#$candidate_major > 10#$current_major))
    return
  fi
  if ((10#$candidate_minor != 10#$current_minor)); then
    ((10#$candidate_minor > 10#$current_minor))
    return
  fi
  if ((10#$candidate_patch != 10#$current_patch)); then
    ((10#$candidate_patch > 10#$current_patch))
    return
  fi

  if [ -z "$candidate_pre" ] && [ -n "$current_pre" ]; then return 0; fi
  if [ -n "$candidate_pre" ] && [ -z "$current_pre" ]; then return 1; fi
  if [ -z "$candidate_pre" ] && [ -z "$current_pre" ]; then return 1; fi

  IFS='.' read -ra candidate_ids <<< "$candidate_pre"
  IFS='.' read -ra current_ids <<< "$current_pre"
  max=${#candidate_ids[@]}
  if [ "${#current_ids[@]}" -gt "$max" ]; then max=${#current_ids[@]}; fi

  for ((index = 0; index < max; index++)); do
    if [ "$index" -ge "${#candidate_ids[@]}" ]; then return 1; fi
    if [ "$index" -ge "${#current_ids[@]}" ]; then return 0; fi
    candidate_id=${candidate_ids[$index]}
    current_id=${current_ids[$index]}
    if [ "$candidate_id" = "$current_id" ]; then continue; fi

    if [[ "$candidate_id" =~ ^[0-9]+$ ]] && [[ "$current_id" =~ ^[0-9]+$ ]]; then
      ((10#$candidate_id > 10#$current_id))
      return
    fi
    if [[ "$candidate_id" =~ ^[0-9]+$ ]]; then return 1; fi
    if [[ "$current_id" =~ ^[0-9]+$ ]]; then return 0; fi
    (
      export LC_ALL=C
      [[ "$candidate_id" > "$current_id" ]]
    )
    return
  done

  return 1
}

greatest_semver_tag() {
  local ls_remote_output=$1
  local object_id ref tag latest=""

  while IFS=$'\t' read -r object_id ref; do
    [ -n "${object_id:-}" ] && [ -n "${ref:-}" ] || continue
    tag=${ref#refs/tags/}
    validate_semver "$tag" || continue
    if [ -z "$latest" ] || semver_is_greater "$tag" "$latest"; then
      latest=$tag
    fi
  done <<< "$ls_remote_output"

  printf '%s\n' "$latest"
}

validate_pre_bump_version() {
  local label=$1
  local value=$2

  case "$value" in
    "$BASE_VERSION"|"$VERSION")
      return 0
      ;;
    *)
      fail "$label version is $value; expected the current released version $BASE_VERSION or requested version $VERSION so the release bump can update it safely."
      ;;
  esac
}

extract_podspec_version() {
  sed -nE "s/^[[:space:]]*s[.]version[[:space:]]*=[[:space:]]*'([^']+)'[[:space:]]*$/\1/p" "$1"
}

extract_sdk_version() {
  sed -nE 's/^[[:space:]]*static let value[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' "$1"
}

extract_top_changelog_version() {
  sed -nE 's/^## \[([^]]+)\].*/\1/p' "$1" | sed -n '1p'
}

extract_latest_released_version() {
  sed -nE 's/^## \[([0-9]+[.][0-9]+[.][0-9]+(-[0-9A-Za-z.-]+)?)\].*/\1/p' "$1" | sed -n '1p'
}

is_release_file() {
  local path=$1
  case "$path" in
    "$CHANGELOG"|"$PODSPEC"|"$SDK_VERSION_FILE") return 0 ;;
    *) return 1 ;;
  esac
}

is_allowed_generated_path() {
  local path=$1
  case "$path" in
    DigiaEngage.xcframework|FatBuild/DigiaEngageFat.xcodeproj/*) return 0 ;;
    *) return 1 ;;
  esac
}

assert_no_unrelated_changes() {
  local path

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if ! is_release_file "$path"; then
      fail "Tracked change '$path' is outside the three release files. Commit, stash, or restore it first."
    fi
  done < <(git diff --name-only HEAD --)

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if ! is_release_file "$path"; then
      fail "Staged change '$path' would contaminate the release commit. Commit or unstage it first."
    fi
  done < <(git diff --cached --name-only --)

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if ! is_allowed_generated_path "$path"; then
      fail "Untracked path '$path' could affect the build. Commit, move, or remove it first."
    fi
  done < <(git ls-files --others --exclude-standard)

  for path in "${RELEASE_FILES[@]}"; do
    [ -f "$path" ] || fail "Required release file '$path' is missing or is not a regular file."
  done

  git diff --check HEAD -- "${RELEASE_FILES[@]}"
}

assert_exact_release_changes() {
  local path
  local -a changed=()

  while IFS= read -r path; do
    [ -z "$path" ] || changed+=("$path")
  done < <(git diff --name-only HEAD --)

  if [ "${#changed[@]}" -ne "${#RELEASE_FILES[@]}" ]; then
    fail "Expected exactly three changed release files; found ${#changed[@]}: ${changed[*]:-(none)}."
  fi

  for path in "${changed[@]}"; do
    is_release_file "$path" || fail "Unexpected tracked change '$path' appeared during the release."
  done
  for path in "${RELEASE_FILES[@]}"; do
    if git diff --quiet HEAD -- "$path"; then
      fail "Release file '$path' is unchanged from HEAD; every release must update all three files."
    fi
  done

  git diff --check HEAD -- "${RELEASE_FILES[@]}"
}

assert_paths_are_exact_release_files() {
  local description=$1
  shift
  local path
  local -a paths=("$@")

  if [ "${#paths[@]}" -ne "${#RELEASE_FILES[@]}" ]; then
    fail "$description contains ${#paths[@]} files instead of exactly three: ${paths[*]:-(none)}."
  fi
  for path in "${paths[@]}"; do
    is_release_file "$path" || fail "$description contains unauthorized file '$path'."
  done
  for path in "${RELEASE_FILES[@]}"; do
    local found=0
    local candidate
    for candidate in "${paths[@]}"; do
      if [ "$candidate" = "$path" ]; then found=1; break; fi
    done
    [ "$found" -eq 1 ] || fail "$description is missing '$path'."
  done
}

capture_original_state() {
  local index_path

  ORIGINAL_STATUS=$(git status --porcelain=v2 --untracked-files=all)
  ORIGINAL_HEAD=$(git rev-parse HEAD)
  ORIGINAL_REFS=$(git show-ref || true)
  ORIGINAL_FILE_HASHES=$(shasum -a 256 "${RELEASE_FILES[@]}")
  index_path=$(git rev-parse --git-path index)
  [ -f "$index_path" ] || fail "Could not locate the real checkout's git index for dry-run protection."
  ORIGINAL_INDEX_HASH=$(shasum -a 256 "$index_path" | awk '{print $1}')
}

prepare_dry_run_clone() {
  local path

  VALIDATION_REPO="$RUN_DIR/repository"
  git clone --quiet --no-local "$ORIGINAL_REPO_ROOT" "$VALIDATION_REPO"

  for path in "${RELEASE_FILES[@]}"; do
    mkdir -p "$VALIDATION_REPO/$(dirname "$path")"
    cp -p "$ORIGINAL_REPO_ROOT/$path" "$VALIDATION_REPO/$path"
  done

  cd "$VALIDATION_REPO"
  [ "$(git rev-parse HEAD)" = "$ORIGINAL_HEAD" ] || fail "Temporary validation clone does not match the real checkout's HEAD."
}

verify_dry_run_non_mutation() {
  local current_status current_head current_refs current_hashes current_index_hash index_path

  assert_exact_release_changes
  git diff --cached --quiet -- || fail "Dry-run unexpectedly staged files inside the temporary clone."
  [ -d "$XCFRAMEWORK" ] && [ -s "$ZIP_PATH" ] || fail "Dry-run validation artifact is missing from the temporary clone."
  [ -s "$NOTES_FILE" ] || fail "Dry-run release notes were not generated."

  cd "$ORIGINAL_REPO_ROOT"
  current_status=$(git status --porcelain=v2 --untracked-files=all)
  current_head=$(git rev-parse HEAD)
  current_refs=$(git show-ref || true)
  current_hashes=$(shasum -a 256 "${RELEASE_FILES[@]}")
  index_path=$(git rev-parse --git-path index)
  current_index_hash=$(shasum -a 256 "$index_path" | awk '{print $1}')

  [ "$current_status" = "$ORIGINAL_STATUS" ] || fail "Dry-run changed the real checkout's worktree status."
  [ "$current_head" = "$ORIGINAL_HEAD" ] || fail "Dry-run changed the real checkout's HEAD."
  [ "$current_refs" = "$ORIGINAL_REFS" ] || fail "Dry-run changed git refs in the real checkout."
  [ "$current_hashes" = "$ORIGINAL_FILE_HASHES" ] || fail "Dry-run changed one of the three real release files."
  [ "$current_index_hash" = "$ORIGINAL_INDEX_HASH" ] || fail "Dry-run changed the real checkout's git index."
}

validate_preflight() {
  local command path remote_head remote_tag top_version current_pod current_sdk
  local base_pod base_sdk base_changelog origin_url repo_hint pod_info remote_tags
  local -a required_commands=(
    awk cp curl dirname find gh git grep head ln mkdir mktemp nm pod rm ruby sed
    shasum swift unzip xcodebuild xcodegen zip
  )

  for command in "${required_commands[@]}"; do
    command -v "$command" >/dev/null 2>&1 || fail "Required command '$command' is not installed or not on PATH."
  done
  [ -x /usr/libexec/PlistBuddy ] || fail "Required macOS tool /usr/libexec/PlistBuddy is unavailable."
  [ -x "$BUILD_SCRIPT" ] || fail "$BUILD_SCRIPT is missing or not executable."

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "This is not a git worktree."
  BRANCH=$(git branch --show-current)
  [ "$BRANCH" = "$EXPECTED_BRANCH" ] || fail "Releases must run from '$EXPECTED_BRANCH'; current branch is '${BRANCH:-detached HEAD}'."
  origin_url=$(git remote get-url origin) || fail "Git remote 'origin' is not configured."
  git var GIT_AUTHOR_IDENT >/dev/null 2>&1 || fail "Git author identity is not configured."
  git var GIT_COMMITTER_IDENT >/dev/null 2>&1 || fail "Git committer identity is not configured."

  for path in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    if [ -e "$(git rev-parse --git-path "$path")" ]; then
      fail "A git operation is in progress ($path). Finish or abort it before releasing."
    fi
  done

  assert_no_unrelated_changes

  git show "HEAD:$PODSPEC" > "$RUN_DIR/head-podspec"
  git show "HEAD:$SDK_VERSION_FILE" > "$RUN_DIR/head-sdk-version"
  git show "HEAD:$CHANGELOG" > "$RUN_DIR/head-changelog"

  base_pod=$(extract_podspec_version "$RUN_DIR/head-podspec")
  base_sdk=$(extract_sdk_version "$RUN_DIR/head-sdk-version")
  base_changelog=$(extract_latest_released_version "$RUN_DIR/head-changelog")
  [ -n "$base_pod" ] || fail "Could not read the podspec version from HEAD."
  [ -n "$base_sdk" ] || fail "Could not read the SDK version from HEAD."
  [ -n "$base_changelog" ] || fail "Could not read the latest released changelog version from HEAD."
  if [ "$base_pod" != "$base_sdk" ] || [ "$base_pod" != "$base_changelog" ]; then
    fail "HEAD versions are already inconsistent: podspec=$base_pod, SDK=$base_sdk, changelog=$base_changelog."
  fi
  BASE_VERSION=$base_pod
  validate_semver "$BASE_VERSION" || fail "Current version '$BASE_VERSION' in HEAD is not valid semantic versioning."
  semver_is_greater "$VERSION" "$BASE_VERSION" || fail "New version $VERSION must be greater than current version $BASE_VERSION."

  current_pod=$(extract_podspec_version "$PODSPEC")
  current_sdk=$(extract_sdk_version "$SDK_VERSION_FILE")
  top_version=$(extract_top_changelog_version "$CHANGELOG")
  [ -n "$current_pod" ] && [ -n "$current_sdk" ] && [ -n "$top_version" ] || fail "Could not read all three working-tree versions."
  validate_pre_bump_version "Working podspec" "$current_pod"
  validate_pre_bump_version "Working SDK" "$current_sdk"

  case "$top_version" in
    Unreleased)
      ;;
    "$VERSION")
      ;;
    *)
      fail "Top changelog section is [$top_version]; expected [Unreleased] or [$VERSION]."
      ;;
  esac

  if grep -Eq "^## \\[$VERSION_REGEX\\]([[:space:]]|$)" "$RUN_DIR/head-changelog"; then
    fail "Version $VERSION already exists in the committed changelog."
  fi
  if git show-ref --verify --quiet "refs/tags/$VERSION"; then
    fail "Local git tag $VERSION already exists."
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    git fetch --quiet origin "$BRANCH"
  fi
  remote_head=$(git ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')
  [ -n "$remote_head" ] || fail "Could not resolve origin/$BRANCH after fetching."
  [ "$(git rev-parse HEAD)" = "$remote_head" ] || fail "Local $BRANCH does not exactly match origin/$BRANCH. Pull/push pending commits before releasing."

  remote_tags=$(git ls-remote --tags --refs origin)
  LATEST_RELEASED_TAG=$(greatest_semver_tag "$remote_tags")
  [ -n "$LATEST_RELEASED_TAG" ] || fail "Origin has no valid SemVer release tag to compare against."
  [ "$LATEST_RELEASED_TAG" = "$BASE_VERSION" ] \
    || fail "Latest remote SemVer tag is $LATEST_RELEASED_TAG, but committed podspec/SDK/changelog version is $BASE_VERSION. Reconcile release history before continuing."
  semver_is_greater "$VERSION" "$LATEST_RELEASED_TAG" \
    || fail "New version $VERSION must be greater than latest released tag $LATEST_RELEASED_TAG."
  echo "    Latest released SemVer tag: $LATEST_RELEASED_TAG"

  remote_tag=$(git ls-remote --tags origin "refs/tags/$VERSION")
  [ -z "$remote_tag" ] || fail "Remote git tag $VERSION already exists."

  gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run 'gh auth login' and retry."
  repo_hint=$(printf '%s\n' "$origin_url" | sed -E 's#^(git@[^:]+:|ssh://git@[^/]+/|https?://[^/]+/)##; s#[.]git$##')
  [[ "$repo_hint" == */* ]] || fail "Could not derive a GitHub OWNER/REPO from origin URL '$origin_url'."
  GH_REPO=$(gh repo view "$repo_hint" --json nameWithOwner --jq '.nameWithOwner')
  [ -n "$GH_REPO" ] || fail "Could not resolve the GitHub repository from the current checkout."
  if gh release view "$VERSION" --repo "$GH_REPO" >/dev/null 2>&1; then
    fail "GitHub Release $VERSION already exists in $GH_REPO."
  fi

  if ! pod trunk me > "$RUN_DIR/pod-trunk-me.out" 2>&1; then
    fail "CocoaPods trunk is not authenticated. Run: pod trunk register engg@digia.tech 'Digia Engineering'"
  fi

  pod_info=$(pod trunk info "$POD_NAME" 2>/dev/null || true)
  if printf '%s\n' "$pod_info" | grep -Eq "^[[:space:]]*-[[:space:]]+$VERSION_REGEX([[:space:]]|$)"; then
    fail "CocoaPods trunk already contains $POD_NAME $VERSION."
  fi
}

bump_release_files() {
  local podspec_pattern sdk_pattern podspec_count sdk_count
  local top_heading top_version target_heading_count release_heading
  local staged_podspec="$RUN_DIR/bumped-podspec"
  local staged_sdk="$RUN_DIR/bumped-sdk-version"
  local staged_changelog="$RUN_DIR/bumped-changelog"

  podspec_pattern="^[[:space:]]*s\\.version[[:space:]]*=[[:space:]]*'[^']*'[[:space:]]*$"
  sdk_pattern='^[[:space:]]*static let value[[:space:]]*=[[:space:]]*"[^"]*"[[:space:]]*$'

  podspec_count=$(grep -Ec "$podspec_pattern" "$PODSPEC" || true)
  [ "$podspec_count" -eq 1 ] || fail "Expected exactly one s.version assignment in $PODSPEC; found $podspec_count."
  sdk_count=$(grep -Ec "$sdk_pattern" "$SDK_VERSION_FILE" || true)
  [ "$sdk_count" -eq 1 ] || fail "Expected exactly one DigiaSdkVersion value in $SDK_VERSION_FILE; found $sdk_count."

  top_heading=$(grep -m 1 -E '^## \[[^]]+\]' "$CHANGELOG" || true)
  [ -n "$top_heading" ] || fail "No version heading found in $CHANGELOG."
  top_version=$(printf '%s\n' "$top_heading" | sed -E 's/^## \[([^]]+)\].*/\1/')
  target_heading_count=$(grep -Ec "^## \\[$VERSION_REGEX\\]([[:space:]]|$)" "$CHANGELOG" || true)

  case "$top_version" in
    Unreleased)
      [ "$target_heading_count" -eq 0 ] || fail "Version $VERSION already exists below the [Unreleased] section in $CHANGELOG."
      ;;
    "$VERSION")
      [ "$target_heading_count" -eq 1 ] || fail "Expected exactly one $VERSION heading in $CHANGELOG; found $target_heading_count."
      ;;
    *)
      fail "Top changelog section is [$top_version], not [Unreleased] or [$VERSION]."
      ;;
  esac

  release_heading="## [$VERSION] - $(date +'%Y-%m-%d')"

  awk -v version="$VERSION" '
    /^[[:space:]]*s[.]version[[:space:]]*=/ {
      sub(/\047[^\047]*\047/, "\047" version "\047")
    }
    { print }
  ' "$PODSPEC" > "$staged_podspec"

  awk -v version="$VERSION" '
    /^[[:space:]]*static let value[[:space:]]*=/ {
      sub(/"[^"]*"/, "\"" version "\"")
    }
    { print }
  ' "$SDK_VERSION_FILE" > "$staged_sdk"

  awk -v heading="$release_heading" '
    !updated && /^## \[[^]]+\]/ {
      print heading
      updated = 1
      next
    }
    { print }
    END {
      if (!updated) exit 1
    }
  ' "$CHANGELOG" > "$staged_changelog"

  [ "$(grep -Ec "^[[:space:]]*s\\.version[[:space:]]*=[[:space:]]*'$VERSION_REGEX'[[:space:]]*$" "$staged_podspec" || true)" -eq 1 ] \
    || fail "Failed to stage version $VERSION in $PODSPEC."
  [ "$(grep -Ec "^[[:space:]]*static let value[[:space:]]*=[[:space:]]*\"$VERSION_REGEX\"[[:space:]]*$" "$staged_sdk" || true)" -eq 1 ] \
    || fail "Failed to stage version $VERSION in $SDK_VERSION_FILE."
  [ "$(grep -Fxc "$release_heading" "$staged_changelog" || true)" -eq 1 ] \
    || fail "Failed to stage release heading '$release_heading' in $CHANGELOG."
  if grep -q '^## \[Unreleased\]' "$staged_changelog"; then
    fail "An [Unreleased] section remained after staging the changelog bump."
  fi

  cp "$staged_podspec" "$PODSPEC"
  cp "$staged_sdk" "$SDK_VERSION_FILE"
  cp "$staged_changelog" "$CHANGELOG"
}

create_release_notes() {
  local expected_heading="## [$VERSION] - $(date +'%Y-%m-%d')"

  NOTES_FILE="$RUN_DIR/release-notes.md"
  awk -v heading="$expected_heading" '
    $0 == heading { in_release = 1; found = 1; next }
    in_release && /^## \[[^]]+\]/ { in_release = 0 }
    in_release { lines[++count] = $0 }
    END {
      if (!found) exit 2
      first = 1
      while (first <= count && lines[first] == "") first++
      last = count
      while (last >= first && lines[last] == "") last--
      for (line_number = first; line_number <= last; line_number++) print lines[line_number]
    }
  ' "$CHANGELOG" > "$NOTES_FILE" || fail "Could not extract release notes below '$expected_heading'."

  [ -s "$NOTES_FILE" ] || fail "The $VERSION changelog section is empty; refusing to create an empty GitHub Release."
  grep -q '^### ' "$NOTES_FILE" || fail "The $VERSION changelog section has no release-note category heading."
  grep -q '^- ' "$NOTES_FILE" || fail "The $VERSION changelog section has no release-note bullets."
}

validate_podspec_metadata() {
  local spec_name spec_version vendored_frameworks

  pod ipc spec "$PODSPEC" > "$RUN_DIR/podspec.json"
  spec_name=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["name"]' "$RUN_DIR/podspec.json")
  spec_version=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["version"]' "$RUN_DIR/podspec.json")
  PODSPEC_SOURCE_URL=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("source").fetch("http")' "$RUN_DIR/podspec.json")
  vendored_frameworks=$(ruby -rjson -e 'puts Array(JSON.parse(File.read(ARGV[0]))["vendored_frameworks"]).join("\n")' "$RUN_DIR/podspec.json")

  [ "$spec_name" = "$POD_NAME" ] || fail "Podspec name is '$spec_name', expected '$POD_NAME'."
  [ "$spec_version" = "$VERSION" ] || fail "Parsed podspec version is '$spec_version', expected '$VERSION'."
  [[ "$PODSPEC_SOURCE_URL" == https://*"/$VERSION/$POD_NAME.xcframework.zip" ]] || fail "Podspec source URL does not point to the $VERSION XCFramework zip: $PODSPEC_SOURCE_URL"
  printf '%s\n' "$vendored_frameworks" | grep -Fxq "$POD_NAME.xcframework" || fail "Podspec does not vendor $POD_NAME.xcframework."
}

validate_release_versions() {
  local pod_version sdk_version changelog_version expected_heading target_count unreleased_count

  bump_release_files

  pod_version=$(extract_podspec_version "$PODSPEC")
  sdk_version=$(extract_sdk_version "$SDK_VERSION_FILE")
  changelog_version=$(extract_top_changelog_version "$CHANGELOG")
  if [ "$pod_version" != "$VERSION" ] || [ "$sdk_version" != "$VERSION" ] || [ "$changelog_version" != "$VERSION" ]; then
    fail "Release versions differ after bump: requested=$VERSION, podspec=$pod_version, SDK=$sdk_version, changelog=$changelog_version."
  fi

  expected_heading="## [$VERSION] - $(date +'%Y-%m-%d')"
  [ "$(grep -m 1 -E '^## \[[^]]+\]' "$CHANGELOG")" = "$expected_heading" ] || fail "Top changelog heading must be '$expected_heading'."
  target_count=$(grep -Ec "^## \\[$VERSION_REGEX\\]([[:space:]]|$)" "$CHANGELOG" || true)
  [ "$target_count" -eq 1 ] || fail "Expected exactly one changelog section for $VERSION; found $target_count."
  unreleased_count=$(grep -Ec '^## \[Unreleased\]' "$CHANGELOG" || true)
  [ "$unreleased_count" -eq 0 ] || fail "An [Unreleased] section remains after the release bump."

  assert_exact_release_changes
  create_release_notes
  validate_podspec_metadata
}

validate_swift_package() {
  swift package dump-package > "$RUN_DIR/package.json"
  swift test
  assert_exact_release_changes
}

validate_swift_package_dry() {
  local cache_path="$RUN_DIR/swift-cache"
  local config_path="$RUN_DIR/swift-config"
  local security_path="$RUN_DIR/swift-security"
  local scratch_path="$RUN_DIR/swift-scratch"

  swift package \
    --cache-path "$cache_path" \
    --config-path "$config_path" \
    --security-path "$security_path" \
    --scratch-path "$scratch_path" \
    dump-package > "$RUN_DIR/package.json"
  swift test \
    --cache-path "$cache_path" \
    --config-path "$config_path" \
    --security-path "$security_path" \
    --scratch-path "$scratch_path"
  assert_exact_release_changes
}

validate_artifacts() {
  local framework plist framework_version binary device_binary=""
  local framework_count=0 sdwebimage_symbols lottie_symbols checksum

  [ -d "$XCFRAMEWORK" ] || fail "Build completed without producing $XCFRAMEWORK."
  [ -s "$ZIP_PATH" ] || fail "Build completed without producing a non-empty $ZIP_PATH."
  unzip -tq "$ZIP_PATH" > "$RUN_DIR/unzip-test.out"

  while IFS= read -r framework; do
    [ -z "$framework" ] && continue
    framework_count=$((framework_count + 1))
    plist="$framework/Info.plist"
    binary="$framework/$POD_NAME"
    [ -f "$plist" ] || fail "Framework slice is missing Info.plist: $framework"
    [ -f "$binary" ] || fail "Framework slice is missing its binary: $framework"
    [ -f "$framework/PrivacyInfo.xcprivacy" ] || fail "Framework slice is missing PrivacyInfo.xcprivacy: $framework"
    framework_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
    [ "$framework_version" = "$VERSION" ] || fail "Framework slice $framework reports version $framework_version instead of $VERSION."
    if [[ "$framework" == *ios-arm64/$POD_NAME.framework ]]; then
      device_binary=$binary
    fi
  done < <(find "$XCFRAMEWORK" -type d -name "$POD_NAME.framework" -print)

  [ "$framework_count" -ge 2 ] || fail "Expected at least device and simulator framework slices; found $framework_count."
  [ -n "$device_binary" ] || fail "Could not locate the ios-arm64 framework binary for dependency checks."

  nm -gU "$device_binary" > "$RUN_DIR/device-symbols.txt"
  sdwebimage_symbols=$(grep -c 'SDWebImage' "$RUN_DIR/device-symbols.txt" || true)
  lottie_symbols=$(grep -c 'Lottie' "$RUN_DIR/device-symbols.txt" || true)
  [ "$sdwebimage_symbols" -gt 0 ] || fail "The fat framework contains no visible SDWebImage symbols."
  [ "$lottie_symbols" -gt 0 ] || fail "The fat framework contains no visible Lottie symbols."

  checksum=$(swift package compute-checksum "$ZIP_PATH")
  [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || fail "SwiftPM returned an invalid artifact checksum: '$checksum'."
  printf '%s\n' "$checksum" > "$RUN_DIR/artifact-checksum.txt"

  assert_exact_release_changes
}

build_and_validate_framework() {
  "$BUILD_SCRIPT"
  validate_artifacts
}

build_and_validate_framework_dry() {
  mkdir -p "$RUN_DIR/home" "$RUN_DIR/tmp"
  HOME="$RUN_DIR/home" TMPDIR="$RUN_DIR/tmp" "$BUILD_SCRIPT"
  validate_artifacts
}

commit_release_files() {
  local path subject
  local -a staged=() committed=()

  require_live_mode "git commit" || return 1
  assert_exact_release_changes
  git add -- "${RELEASE_FILES[@]}"

  while IFS= read -r path; do
    [ -z "$path" ] || staged+=("$path")
  done < <(git diff --cached --name-only --)
  assert_paths_are_exact_release_files "Staged release commit" "${staged[@]}"
  git diff --cached --check

  if ! git diff --quiet --; then
    fail "Unstaged tracked changes remain after staging the three release files."
  fi

  git commit -m "chore: version bump to $VERSION"
  RELEASE_COMMIT=$(git rev-parse HEAD)
  subject=$(git log -1 --format=%s)
  [ "$subject" = "chore: version bump to $VERSION" ] || fail "Release commit subject is '$subject', not the required version-bump message."

  while IFS= read -r path; do
    [ -z "$path" ] || committed+=("$path")
  done < <(git diff-tree --no-commit-id --name-only -r "$RELEASE_COMMIT")
  assert_paths_are_exact_release_files "Release commit $RELEASE_COMMIT" "${committed[@]}"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || fail "Tracked changes remain after creating the release commit."
}

push_release_commit() {
  local remote_head
  require_live_mode "git push" || return 1
  git push origin "$BRANCH"
  remote_head=$(git ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')
  [ "$remote_head" = "$RELEASE_COMMIT" ] || fail "origin/$BRANCH points to $remote_head instead of release commit $RELEASE_COMMIT."
}

create_and_push_tag() {
  local remote_tag
  require_live_mode "git tag and tag push" || return 1
  git tag "$VERSION" "$RELEASE_COMMIT"
  [ "$(git rev-list -n 1 "$VERSION")" = "$RELEASE_COMMIT" ] || fail "Local tag $VERSION does not resolve to the release commit."
  git push origin "refs/tags/$VERSION"
  remote_tag=$(git ls-remote origin "refs/tags/$VERSION" | awk '{print $1}')
  [ "$remote_tag" = "$RELEASE_COMMIT" ] || fail "Remote tag $VERSION points to $remote_tag instead of $RELEASE_COMMIT."
}

create_github_release() {
  require_live_mode "GitHub Release creation and asset upload" || return 1
  gh release create "$VERSION" "$ZIP_PATH" \
    --repo "$GH_REPO" \
    --title "$VERSION" \
    --notes-file "$NOTES_FILE" \
    --verify-tag
}

verify_github_release() {
  local release_title release_tag release_body asset_count asset_size
  local expected_hash remote_hash

  RELEASE_URL=$(gh release view "$VERSION" --repo "$GH_REPO" --json url --jq '.url')
  release_title=$(gh release view "$VERSION" --repo "$GH_REPO" --json name --jq '.name')
  release_tag=$(gh release view "$VERSION" --repo "$GH_REPO" --json tagName --jq '.tagName')
  release_body=$(gh release view "$VERSION" --repo "$GH_REPO" --json body --jq '.body')
  asset_count=$(gh release view "$VERSION" --repo "$GH_REPO" --json assets --jq '[.assets[] | select(.name == "DigiaEngage.xcframework.zip")] | length')
  asset_size=$(gh release view "$VERSION" --repo "$GH_REPO" --json assets --jq '[.assets[] | select(.name == "DigiaEngage.xcframework.zip")][0].size // 0')

  [ "$release_title" = "$VERSION" ] || fail "GitHub Release title is '$release_title', expected '$VERSION'."
  [ "$release_tag" = "$VERSION" ] || fail "GitHub Release tag is '$release_tag', expected '$VERSION'."
  [ "$release_body" = "$(<"$NOTES_FILE")" ] || fail "GitHub Release body does not exactly match the $VERSION changelog section."
  [ "$asset_count" -eq 1 ] || fail "GitHub Release must contain exactly one DigiaEngage.xcframework.zip asset; found $asset_count."
  [ "$asset_size" -gt 0 ] || fail "The uploaded GitHub Release asset has zero size."

  curl -fsSL --retry 5 --retry-delay 3 "$PODSPEC_SOURCE_URL" -o "$RUN_DIR/remote-xcframework.zip"
  unzip -tq "$RUN_DIR/remote-xcframework.zip" > "$RUN_DIR/remote-unzip-test.out"
  expected_hash=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
  remote_hash=$(shasum -a 256 "$RUN_DIR/remote-xcframework.zip" | awk '{print $1}')
  [ "$remote_hash" = "$expected_hash" ] || fail "Downloaded release asset checksum differs from the local zip."
}

lint_podspec() {
  pod lib lint "$PODSPEC" --allow-warnings
}

lint_podspec_dry() {
  mkdir -p "$RUN_DIR/home" "$RUN_DIR/cocoapods-home" "$RUN_DIR/pod-validation"
  HOME="$RUN_DIR/home" \
    CP_HOME_DIR="$RUN_DIR/cocoapods-home" \
    pod lib lint "$PODSPEC" \
      --allow-warnings \
      --validation-dir="$RUN_DIR/pod-validation"
  assert_exact_release_changes
}

push_cocoapods_trunk() {
  require_live_mode "CocoaPods trunk publication" || return 1
  if ! pod trunk me > "$RUN_DIR/pod-trunk-me-final.out" 2>&1; then
    fail "CocoaPods authentication expired. Run: pod trunk register engg@digia.tech 'Digia Engineering'"
  fi
  pod trunk push "$PODSPEC" --allow-warnings
}

verify_final_state() {
  local remote_head remote_tag

  remote_head=$(git ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')
  remote_tag=$(git ls-remote origin "refs/tags/$VERSION" | awk '{print $1}')
  [ "$remote_head" = "$RELEASE_COMMIT" ] || fail "Final branch verification failed for origin/$BRANCH."
  [ "$remote_tag" = "$RELEASE_COMMIT" ] || fail "Final tag verification failed for $VERSION."
  gh release view "$VERSION" --repo "$GH_REPO" >/dev/null
  [ -z "$(git status --porcelain --untracked-files=no)" ] || fail "The release left tracked worktree changes behind."
}

print_success() {
  local passed

  echo ""
  echo "============================================================"
  echo "RELEASE PASSED: Digia Engage iOS $VERSION"
  echo "Why it passed:"
  for passed in "${PASSED_STEPS[@]}"; do
    echo "  ✓ $passed"
  done
  echo ""
  echo "Release commit: $RELEASE_COMMIT"
  echo "Previous released tag: $LATEST_RELEASED_TAG"
  echo "GitHub Release: $RELEASE_URL"
  echo "CocoaPods: pod trunk push completed successfully"
  echo ""
  echo "Suggested next step: wait 2–5 minutes for CocoaPods propagation, then run:"
  echo "  pod search $POD_NAME"
  echo "============================================================"
}

print_dry_run_success() {
  local passed

  echo ""
  echo "============================================================"
  echo "DRY RUN PASSED: Digia Engage iOS $VERSION is ready to release"
  echo "Why it passed:"
  for passed in "${PASSED_STEPS[@]}"; do
    echo "  ✓ $passed"
  done
  echo ""
  echo "No persistent write was performed:"
  echo "  - real release files, git index, HEAD, and refs are unchanged"
  echo "  - no commit, push, or tag was created"
  echo "  - no GitHub Release or asset upload was created"
  echo "  - nothing was published to CocoaPods trunk"
  echo "  - temporary validation files were removed at exit"
  echo "Validated against latest released tag: $LATEST_RELEASED_TAG"
  echo ""
  echo "Suggested next step:"
  echo "  ./Scripts/release.sh $VERSION"
  echo "============================================================"
}

validate_dry_run_preflight() {
  capture_original_state
  validate_preflight
}

run_dry_run() {
  TOTAL_STEPS=7

  run_step \
    "Read-only release preflight" \
    "Correct the reported prerequisite and rerun ./Scripts/release.sh --dry-run $VERSION; the real checkout and remotes remain unchanged." \
    "tools/auth/git state are valid and the input is greater than the latest remote SemVer tag" \
    validate_dry_run_preflight

  run_step \
    "Create disposable validation clone" \
    "Check temporary-disk capacity and local git readability, then rerun the dry-run; the real checkout remains unchanged." \
    "all simulated writes are isolated from the real checkout and will be deleted at exit" \
    prepare_dry_run_clone

  run_step \
    "Simulate and cross-check release versions" \
    "Fix the real release-file inputs, then rerun the dry-run; no real file was modified by the simulation." \
    "the simulated podspec, SDK constant, dated changelog, and GitHub Release body are consistent" \
    validate_release_versions

  run_step \
    "Validate the Swift package in isolation" \
    "Fix the manifest or failing tests and rerun the dry-run; compiler outputs exist only in the disposable clone." \
    "Package.swift parses and the complete Swift test suite passes using temporary caches" \
    validate_swift_package_dry

  run_step \
    "Build and validate the fat XCFramework in isolation" \
    "Fix the build or artifact validation error and rerun the dry-run; no release artifact was uploaded." \
    "temporary device/simulator slices, versions, privacy manifests, dependencies, zip, and checksum are valid" \
    build_and_validate_framework_dry

  run_step \
    "Lint the podspec in isolation" \
    "Fix the CocoaPods lint error and rerun the dry-run; nothing was pushed to trunk." \
    "CocoaPods accepts the simulated local binary podspec using a temporary validation directory" \
    lint_podspec_dry

  run_step \
    "Prove dry-run non-mutation" \
    "Inspect the reported state mismatch before releasing; do not run the live workflow until resolved." \
    "the planned three-file diff is exact and the real files, index, HEAD, refs, and status are unchanged" \
    verify_dry_run_non_mutation

  print_dry_run_success
}

main() {
  local script_dir repo_root

  if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    return 0
  fi
  case "$#" in
    1)
      VERSION=$1
      ;;
    2)
      if [ "$1" = "--dry-run" ]; then
        DRY_RUN=1
        VERSION=$2
      elif [ "$2" = "--dry-run" ]; then
        DRY_RUN=1
        VERSION=$1
      else
        usage >&2
        return 2
      fi
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac

  if [ "$VERSION" = "--dry-run" ]; then
    usage >&2
    return 2
  fi
  if ! validate_semver "$VERSION"; then
    echo "Invalid version '$VERSION'. Expected SemVer such as 3.7.0 or 3.7.0-beta.1 (build metadata is not supported)." >&2
    return 2
  fi
  VERSION_REGEX=${VERSION//./\\.}

  script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
  cd "$repo_root"
  ORIGINAL_REPO_ROOT=$repo_root
  if [ "$DRY_RUN" -eq 1 ]; then
    export GIT_OPTIONAL_LOCKS=0
  fi
  RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/digia-engage-release.XXXXXX")

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "Digia Engage iOS release dry-run $VERSION"
  else
    echo "Digia Engage iOS release $VERSION"
  fi
  echo "Repository: $repo_root"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "The real checkout and all remotes are read-only; build/test writes are confined to a disposable temporary clone."
    run_dry_run
    return 0
  fi

  echo "This will commit, push, tag, create a GitHub Release, and publish to CocoaPods trunk."

  run_step \
    "Preflight validation" \
    "Correct the reported prerequisite. No release files were changed by this script yet; rerun ./Scripts/release.sh $VERSION." \
    "tools/auth/git state are valid and the input is greater than the latest remote SemVer tag" \
    validate_preflight

  run_step \
    "Bump and cross-check release versions" \
    "Fix the three release files, keeping only the requested version, then rerun ./Scripts/release.sh $VERSION." \
    "podspec, SDK constant, and dated changelog all contain the same new version" \
    validate_release_versions

  run_step \
    "Validate the Swift package" \
    "Fix the manifest or failing tests; the release is not committed yet, so rerun ./Scripts/release.sh $VERSION afterward." \
    "Package.swift parses and the complete Swift test suite passes" \
    validate_swift_package

  run_step \
    "Build and validate the fat XCFramework" \
    "Fix the build/artifact error; no release commit exists yet, then rerun ./Scripts/release.sh $VERSION." \
    "device and simulator slices, embedded versions, privacy manifests, dependencies, zip, and checksum are valid" \
    build_and_validate_framework

  run_step \
    "Commit exactly the release files" \
    "Inspect git status and 'git log -1'. If no release commit was created, fix the issue and rerun; otherwise continue from that commit manually." \
    "the release commit uses the requested message and contains only the three authorized files" \
    commit_release_files

  run_step \
    "Push the release commit" \
    "Resolve the push failure, then run: git push origin $EXPECTED_BRANCH" \
    "origin/$EXPECTED_BRANCH points to the verified release commit" \
    push_release_commit

  run_step \
    "Create and push tag $VERSION" \
    "Inspect local and remote tag $VERSION; if only local, run: git push origin refs/tags/$VERSION" \
    "the local and remote version tag both point to the release commit" \
    create_and_push_tag

  run_step \
    "Create the GitHub Release" \
    "Inspect 'gh release view $VERSION --repo $GH_REPO'; create it or re-upload $ZIP_PATH before CocoaPods validation." \
    "the release uses the version title, changelog body, verified tag, and fat-framework asset" \
    create_github_release

  run_step \
    "Verify the GitHub Release asset" \
    "Repair the GitHub Release or run 'gh release upload $VERSION $ZIP_PATH --clobber --repo $GH_REPO', then verify the podspec URL." \
    "release metadata matches and the public artifact downloads with the same checksum" \
    verify_github_release

  run_step \
    "Validate the podspec" \
    "Read the CocoaPods lint error, repair the release safely, and rerun: pod lib lint $PODSPEC --allow-warnings" \
    "CocoaPods local lint accepts the published binary podspec" \
    lint_podspec

  run_step \
    "Push to CocoaPods trunk" \
    "If authentication failed, register with CocoaPods; otherwise resolve the trunk error and rerun: pod trunk push $PODSPEC --allow-warnings" \
    "CocoaPods trunk accepted $POD_NAME $VERSION" \
    push_cocoapods_trunk

  run_step \
    "Final state verification" \
    "Inspect the remote branch, tag, GitHub Release, and local worktree before announcing the release." \
    "remote release state is internally consistent and no tracked changes remain" \
    verify_final_state

  print_success
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
