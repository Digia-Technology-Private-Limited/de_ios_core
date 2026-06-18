# Production podspec — FAT binary distribution.
#
# Ships the FAT DigiaEngage.xcframework (built by Scripts/build-fat-xcframework.sh).
# Lottie, SDWebImageSwiftUI, and SDWebImageSVGCoder are statically folded into the
# framework binary — consumers do NOT need to add those pods themselves and there are
# no s.dependency lines here.
#
# Release flow:
#   1. Scripts/build-fat-xcframework.sh  →  dist/DigiaEngage.xcframework.zip
#   2. gh release create <version> dist/DigiaEngage.xcframework.zip
#   3. pod lib lint DigiaEngage.podspec --allow-warnings
#   4. pod trunk push DigiaEngage.podspec --allow-warnings

Pod::Spec.new do |s|
  s.name             = 'DigiaEngage'
  s.version          = '3.0.0'
  s.summary          = 'Digia Engage iOS SDK — SDUI native rendering layer.'
  s.homepage         = 'https://github.com/Digia-Technology-Private-Limited/digia_engage_iOS'
  s.license          = { :type => 'BUSL-1.1', :file => 'LICENSE' }
  s.authors          = { 'Digia Engineering' => 'engg@digia.tech' }

  s.source           = {
    :http => "https://github.com/Digia-Technology-Private-Limited/digia_engage_iOS/releases/download/#{s.version}/DigiaEngage.xcframework.zip"
  }

  s.ios.deployment_target = '17.0'

  # Fat binary — Lottie + SDWebImage + SDWebImageSVGCoder are baked in.
  # No s.dependency lines: deps are already inside the binary.
  #
  # Local :path => testing: the build script symlinks DigiaEngage.xcframework at
  # the iOS/ root → dist/DigiaEngage.xcframework after each build.
  # HTTP consumers: the zip extracts DigiaEngage.xcframework/ at its root.
  s.vendored_frameworks = 'DigiaEngage.xcframework'
end
