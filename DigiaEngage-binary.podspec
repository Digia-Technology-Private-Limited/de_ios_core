# Binary podspec — SHARED-DEPS distribution.
#
# Ships the SLIM DigiaEngage.xcframework (built by Scripts/build-shared-xcframework.sh,
# deps NOT embedded) and declares Lottie/SDWebImage as normal pod dependencies so
# CocoaPods pulls them from their SOURCE pods and shares ONE copy with the host app
# (no duplicate-class conflicts).
#
# Release flow:
#   1. Scripts/build-shared-xcframework.sh
#   2. Attach dist/DigiaEngage.xcframework.zip to the GitHub Release tag = s.version
#   3. Publish this podspec (rename to DigiaEngage.podspec when you cut over).
#
# IMPORTANT: these dependency versions MUST match SharedBuild/Podfile (what the
# binary was compiled against).

Pod::Spec.new do |s|
  s.name             = 'DigiaEngage'
  s.version          = '2.4.2'
  s.summary          = 'Digia Engage iOS SDK — SDUI native rendering layer.'
  s.homepage         = 'https://github.com/Digia-Technology-Private-Limited/digia_engage_iOS'
  s.license          = { :type => 'BUSL-1.1', :file => 'LICENSE' }
  s.authors          = { 'Digia Engineering' => 'engg@digia.tech' }

  s.source           = {
    :http => "https://github.com/Digia-Technology-Private-Limited/digia_engage_iOS/releases/download/#{s.version}/DigiaEngage.xcframework.zip"
  }

  s.ios.deployment_target = '17.0'

  # Slim binary — deps are NOT inside; they come from the dependencies below.
  s.vendored_frameworks = 'DigiaEngage.xcframework'

  # Pulled from source by CocoaPods, shared with the host app.
  s.dependency 'lottie-ios', '~> 4.5'
  s.dependency 'SDWebImageSwiftUI', '~> 3.1'
  s.dependency 'SDWebImageSVGCoder', '>= 1.7.0'
end
