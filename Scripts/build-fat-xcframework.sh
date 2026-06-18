#!/usr/bin/env bash
#
# build-fat-xcframework.sh
#
# Builds a SINGLE self-contained DigiaEngage.xcframework whose binary statically
# folds in Lottie + SDWebImage + SDWebImageSVGCoder + SDWebImageSwiftUI.
# Consumers vendor one artifact and only `import DigiaEngage`.
#
# Pipeline:
#   1. xcodegen generates a wrapper Xcode project (FatBuild/DigiaEngageFat.xcodeproj)
#      whose dynamic DigiaEngage framework target links the SPM deps statically.
#   2. xcodebuild archives device + simulator slices (library evolution on).
#   3. xcodebuild -create-xcframework combines them.
#   4. zip + swift package compute-checksum for SPM/CocoaPods distribution.
#
# Requirements: Xcode 15+, xcodegen (brew install xcodegen), swift toolchain.
#
# Usage:  Scripts/build-fat-xcframework.sh

set -euo pipefail

# --- git config workaround --------------------------------------------------
# Some environments inject `safe.bareRepository=explicit` via GIT_CONFIG_* env
# vars (command-line precedence, overrides ~/.gitconfig). That blocks SwiftPM
# from reading its bare package cache -> "cannot use bare repository". Append a
# higher-index GIT_CONFIG entry setting it back to `all` (last index wins).
_N="${GIT_CONFIG_COUNT:-0}"
export "GIT_CONFIG_KEY_${_N}=safe.bareRepository"
export "GIT_CONFIG_VALUE_${_N}=all"
export "GIT_CONFIG_COUNT=$((_N + 1))"

# --- paths ------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FATDIR="$ROOT/FatBuild"
PROJECT="$FATDIR/DigiaEngageFat.xcodeproj"
DERIVED="$FATDIR/.derived"
ARCHIVES="$FATDIR/.archives"
OUT="$ROOT/dist"
SCHEME="DigiaEngage"

echo "==> Cleaning previous fat build"
rm -rf "$PROJECT" "$DERIVED" "$ARCHIVES" "$OUT"
mkdir -p "$ARCHIVES" "$OUT"

# --- 1. generate the wrapper project ---------------------------------------
echo "==> Generating Xcode project with xcodegen"
( cd "$FATDIR" && xcodegen generate --spec project.yml )

# Shared archive flags. SKIP_INSTALL=NO + library evolution are what make the
# archive emit a distributable .framework with a stable .swiftinterface.
COMMON=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration Release
  -derivedDataPath "$DERIVED"
  SKIP_INSTALL=NO
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES
  CODE_SIGNING_ALLOWED=NO
)

# --- 2. archive device + simulator -----------------------------------------
echo "==> Archiving device slice (iphoneos)"
xcodebuild archive "${COMMON[@]}" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVES/ios.xcarchive"

echo "==> Archiving simulator slice (iphonesimulator)"
xcodebuild archive "${COMMON[@]}" \
  -destination "generic/platform=iOS Simulator" \
  -archivePath "$ARCHIVES/sim.xcarchive"

DEVICE_FW="$ARCHIVES/ios.xcarchive/Products/Library/Frameworks/DigiaEngage.framework"
SIM_FW="$ARCHIVES/sim.xcarchive/Products/Library/Frameworks/DigiaEngage.framework"

for fw in "$DEVICE_FW" "$SIM_FW"; do
  [ -d "$fw" ] || { echo "ERROR: missing framework at $fw"; exit 1; }
done

# --- 2b. embed consolidated privacy manifest -------------------------------
# Statically merging the deps drops their individual PrivacyInfo.xcprivacy
# bundles, so ship ONE consolidated manifest at each framework root (Apple's
# expectation for a merged binary SDK). See FatBuild/PrivacyInfo.xcprivacy.
PRIVACY="$FATDIR/PrivacyInfo.xcprivacy"
[ -f "$PRIVACY" ] || { echo "ERROR: missing $PRIVACY"; exit 1; }
echo "==> Embedding consolidated PrivacyInfo.xcprivacy"
cp "$PRIVACY" "$DEVICE_FW/PrivacyInfo.xcprivacy"
cp "$PRIVACY" "$SIM_FW/PrivacyInfo.xcprivacy"

# --- 3. combine into one xcframework ---------------------------------------
echo "==> Creating DigiaEngage.xcframework"
DSYM_DEV="$ARCHIVES/ios.xcarchive/dSYMs/DigiaEngage.framework.dSYM"
DSYM_SIM="$ARCHIVES/sim.xcarchive/dSYMs/DigiaEngage.framework.dSYM"

CREATE_ARGS=(-create-xcframework)
CREATE_ARGS+=(-framework "$DEVICE_FW")
[ -d "$DSYM_DEV" ] && CREATE_ARGS+=(-debug-symbols "$DSYM_DEV")
CREATE_ARGS+=(-framework "$SIM_FW")
[ -d "$DSYM_SIM" ] && CREATE_ARGS+=(-debug-symbols "$DSYM_SIM")
CREATE_ARGS+=(-output "$OUT/DigiaEngage.xcframework")

xcodebuild "${CREATE_ARGS[@]}"

# --- 4. zip + checksum ------------------------------------------------------
echo "==> Zipping + checksum"
( cd "$OUT" && zip -r -q -y "DigiaEngage.xcframework.zip" "DigiaEngage.xcframework" )
CHECKSUM="$(swift package compute-checksum "$OUT/DigiaEngage.xcframework.zip")"

echo
echo "============================================================"
echo " Done. Single fat xcframework:"
echo "   $OUT/DigiaEngage.xcframework"
echo "   $OUT/DigiaEngage.xcframework.zip"
echo
echo " SPM binaryTarget checksum:"
echo "   $CHECKSUM"
echo "============================================================"
echo
echo " Sanity check the deps are baked in (should print >0 each):"
echo "   nm -gU '$DEVICE_FW/DigiaEngage' | grep -c SDWebImage"
echo "   nm -gU '$DEVICE_FW/DigiaEngage' | grep -c Lottie"
