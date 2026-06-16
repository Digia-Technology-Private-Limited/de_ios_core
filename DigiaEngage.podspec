Pod::Spec.new do |s|
  s.name             = 'DigiaEngage'
  s.version          = '2.4.2'
  s.summary          = 'Digia Engage iOS SDK — SDUI native rendering layer.'
  s.homepage         = 'https://github.com/Digia-Technology-Private-Limited/digia_engage_iOS'
  s.license          = { :type => 'BUSL-1.1', :file => 'LICENSE' }
  s.authors          = { 'Digia Engineering' => 'engg@digia.tech' }
  s.source           = { :git => 'https://github.com/Digia-Technology-Private-Limited/digia_engage_iOS.git', :tag => s.version.to_s }

  s.ios.deployment_target = '17.0'
  s.swift_versions   = ['6.0']

  s.source_files = 'Sources/**/*.swift'

  s.dependency 'lottie-ios', '~> 4.5'
  s.dependency 'SDWebImageSVGCoder', '>= 1.7.0'
  s.dependency 'SDWebImageSwiftUI', '~> 3.1'
end
