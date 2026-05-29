Pod::Spec.new do |s|
  s.name             = 'DigiaEngage'
  s.version          = '1.0.0'
  s.summary          = 'Digia Engage iOS SDK — SDUI native rendering layer.'
  s.homepage         = 'https://github.com/Digia-Technology-Private-Limited/digia_engage_iOS'
  s.license          = { :type => 'MIT' }
  s.authors          = { 'Digia Engineering' => 'engg@digia.tech' }
  s.source           = { :path => '.' }

  s.ios.deployment_target = '17.0'
  s.swift_versions   = ['5.9']

  s.source_files = 'Sources/**/*.swift'

  s.dependency 'DigiaExpr'
  s.dependency 'lottie-ios', '~> 4.5'
  s.dependency 'SDWebImageSVGCoder', '>= 1.7.0'
  s.dependency 'SDWebImageSwiftUI', '~> 3.1'
end
