# Local DEVELOPMENT podspec — compiles DigiaEngage from SOURCE.
#
# Purpose: fast iteration on the SDK's Swift sources WITHOUT rebuilding the fat
# xcframework (Scripts/build-fat-xcframework.sh). It lists `source_files` + the SPM
# dependencies as real pods (Lottie, SDWebImage*) instead of vendoring a prebuilt
# binary — so a consuming app compiles Sources/DigiaEngage directly and picks up
# edits on the next build.
#
# Same pod NAME ('DigiaEngage') and version as the production DigiaEngage.podspec (the
# FAT binary), so a consumer's `s.dependency 'DigiaEngage'` is satisfied by either spec.
# It is selected explicitly via CocoaPods `:podspec =>` — NOT by pod name resolution —
# so it never shadows the trunk/fat spec for anyone who doesn't opt in.
#
# Consumed by medihub-rn: link ios/core in local-packages.json and set
# DIGIA_IOS_SDK_MODE=source (the default). scripts/localIosPods.js then points the
# Podfile at THIS spec via `:podspec =>`. Switch DIGIA_IOS_SDK_MODE=fat to use the
# locally-built DigiaEngage.xcframework (DigiaEngage.podspec) for final testing.
#
# NOT for release/trunk — that is DigiaEngage.podspec (the fat binary). Because the
# deps are NOT baked in here, a consumer must let Lottie/SDWebImage* resolve as pods.

Pod::Spec.new do |s|
  s.name             = 'DigiaEngage'
  s.version          = '3.9.0'
  s.summary          = 'Digia Engage iOS SDK — SDUI native rendering layer (local source build).'
  s.homepage         = 'https://github.com/Digia-Technology-Private-Limited/digia_engage_iOS'
  s.license          = { :type => 'BUSL-1.1', :file => 'LICENSE' }
  s.authors          = { 'Digia Engineering' => 'engg@digia.tech' }

  # Only ever consumed as a LOCAL `:podspec =>` link, so `s.source` is never fetched;
  # a valid git source is kept for `pod lib lint` hygiene.
  s.source           = {
    :git => 'https://github.com/Digia-Technology-Private-Limited/digia_engage_iOS.git',
    :tag => s.version.to_s,
  }

  s.ios.deployment_target = '15.0'
  # MUST be 6.0 to match the SDK's own builds (FatBuild/SharedBuild project.yml SWIFT_VERSION,
  # Package.swift swift-tools 6.0) — the sources are written for Swift 6 LANGUAGE MODE. With this,
  # the source build has the SAME effective Swift settings as the FatBuild (verified via
  # `xcodebuild -showBuildSettings`: SWIFT_VERSION 6.0, no default-actor-isolation override).
  s.swift_version    = '6.0'

  # Compile from source (no vendored_frameworks). Sources/DigiaEngage is pure Swift —
  # no resource bundles (mirrors Package.swift, which declares none).
  s.source_files     = 'Sources/DigiaEngage/**/*.swift'

  # Deps as real pods (NOT baked in, unlike the fat binary). These MUST match SharedBuild/Podfile
  # (the SDK's own known-good pod set) so the source build co-exists with a host app that already
  # pulls SDWebImage* — e.g. expo-image pins SDWebImageSVGCoder '~> 1.7.0', which the open '>= 1.7.0'
  # here satisfies. NB the CocoaPods pod for Lottie is `lottie-ios` (module `Lottie`); the SPM
  # product name `Lottie` is not a trunk pod.
  s.dependency 'lottie-ios', '~> 4.5'
  s.dependency 'SDWebImageSwiftUI', '~> 3.1'
  s.dependency 'SDWebImageSVGCoder', '>= 1.7.0'
end
