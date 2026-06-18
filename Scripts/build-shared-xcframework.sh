#!/usr/bin/env bash
#
# build-shared-xcframework.sh
#
# Builds a SLIM DigiaEngage.xcframework that LINKS AGAINST Lottie + SDWebImage +
# SDWebImageSVGCoder + SDWebImageSwiftUI but does NOT embed them. The deps are
# pulled from their SOURCE pods via CocoaPods (SharedBuild/Podfile), built as
# DYNAMIC frameworks. DigiaEngage records them as external @rpath references; the
# CONSUMER supplies the actual copies (declared via s.dependency in the podspec),
# so the host app and DigiaEngage share ONE copy of each.
#
# Pair this with DigiaEngage.podspec:
#     s.vendored_frameworks = 'DigiaEngage.xcframework'
#     s.dependency 'lottie-ios', '~> 4.5'
#     s.dependency 'SDWebImageSwiftUI', '~> 3.1'
#     s.dependency 'SDWebImageSVGCoder', '>= 1.7.0'
#
# CONSUMER REQUIREMENT: the deps resolve at runtime as DYNAMIC frameworks
# (use_frameworks! :linkage => :dynamic, or per-pod :linkage => :dynamic).
#
# Requirements: Xcode 15+, xcodegen, CocoaPods, swift toolchain.
# Usage: Scripts/build-shared-xcframework.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDDIR="$ROOT/SharedBuild"
PROJECT="$BUILDDIR/DigiaEngageShared.xcodeproj"
WORKSPACE="$BUILDDIR/DigiaEngageShared.xcworkspace"
DERIVED="$BUILDDIR/.derived"
ARCHIVES="$BUILDDIR/.archives"
OUT="$ROOT/dist"
SCHEME="DigiaEngage"

echo "==> Cleaning previous shared build"
rm -rf "$PROJECT" "$WORKSPACE" "$DERIVED" "$ARCHIVES" "$OUT" \
       "$BUILDDIR/Pods" "$BUILDDIR/Podfile.lock"
mkdir -p "$ARCHIVES" "$OUT"

echo "==> Generating Xcode project (xcodegen)"
( cd "$BUILDDIR" && xcodegen generate --spec project.yml )

echo "==> Resolving dependencies from source pods (pod install)"
( cd "$BUILDDIR" && pod install )

COMMON=(
  -workspace "$WORKSPACE"
  -scheme "$SCHEME"
  -configuration Release
  -derivedDataPath "$DERIVED"
  SKIP_INSTALL=NO
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES
  CODE_SIGNING_ALLOWED=NO
)

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

# Strip any dep frameworks Xcode may have copied in — DigiaEngage must stay slim.
for fw in "$DEVICE_FW" "$SIM_FW"; do
  rm -rf "$fw/Frameworks"
done

# Embed DigiaEngage's own consolidated privacy manifest (deps ship their own).
PRIVACY="$BUILDDIR/PrivacyInfo.xcprivacy"
if [ -f "$PRIVACY" ]; then
  echo "==> Embedding PrivacyInfo.xcprivacy"
  cp "$PRIVACY" "$DEVICE_FW/PrivacyInfo.xcprivacy"
  cp "$PRIVACY" "$SIM_FW/PrivacyInfo.xcprivacy"
fi

echo "==> Creating DigiaEngage.xcframework"
DSYM_DEV="$ARCHIVES/ios.xcarchive/dSYMs/DigiaEngage.framework.dSYM"
DSYM_SIM="$ARCHIVES/sim.xcarchive/dSYMs/DigiaEngage.framework.dSYM"
CREATE_ARGS=(-create-xcframework -framework "$DEVICE_FW")
[ -d "$DSYM_DEV" ] && CREATE_ARGS+=(-debug-symbols "$DSYM_DEV")
CREATE_ARGS+=(-framework "$SIM_FW")
[ -d "$DSYM_SIM" ] && CREATE_ARGS+=(-debug-symbols "$DSYM_SIM")
CREATE_ARGS+=(-output "$OUT/DigiaEngage.xcframework")
xcodebuild "${CREATE_ARGS[@]}"

echo "==> Zipping + checksum"
( cd "$OUT" && zip -r -q -y "DigiaEngage.xcframework.zip" "DigiaEngage.xcframework" )
CHECKSUM="$(swift package compute-checksum "$OUT/DigiaEngage.xcframework.zip")"

echo
echo "============================================================"
echo " Done. Slim (shared-deps) xcframework:"
echo "   $OUT/DigiaEngage.xcframework  (deps NOT embedded)"
echo " SPM binaryTarget checksum:"
echo "   $CHECKSUM"
echo "============================================================"
echo
echo " External deps DigiaEngage expects at runtime (consumer provides these):"
otool -L "$DEVICE_FW/DigiaEngage" | grep -iE "lottie|sdweb" || echo "  (NONE FOUND — unexpected)"
echo
echo " Confirm deps NOT baked in (should be 0):"
echo "   defined SDWebImage symbols: $(nm -gU "$DEVICE_FW/DigiaEngage" 2>/dev/null | grep -c SDWebImage)"
echo "   defined Lottie symbols:     $(nm -gU "$DEVICE_FW/DigiaEngage" 2>/dev/null | grep -ci lottie)"
