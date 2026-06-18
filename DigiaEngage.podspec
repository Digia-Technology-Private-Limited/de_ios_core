Pod::Spec.new do |s|
  s.name             = 'DigiaEngage'
  s.version          = '2.4.2'
  s.summary          = 'Digia Engage iOS SDK — fat self-contained build (test).'
  s.homepage         = 'https://github.com/Digia-Technology-Private-Limited/digia_engage_iOS'
  s.license          = { :type => 'BUSL-1.1', :file => 'LICENSE' }
  s.authors          = { 'Digia Engineering' => 'engg@digia.tech' }
  s.source           = { :git => 'https://github.com/Digia-Technology-Private-Limited/digia_engage_iOS.git', :tag => s.version.to_s }
  s.ios.deployment_target = '17.0'

  # FAT self-contained framework — Lottie/SDWebImage statically folded in.
  # No s.dependency: deps are baked into the binary.
  s.vendored_frameworks = 'dist/DigiaEngage.xcframework'
end
