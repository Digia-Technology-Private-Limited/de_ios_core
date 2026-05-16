Pod::Spec.new do |s|
  s.name             = 'DigiaEngage'
  s.version          = '1.0.0'
  s.summary          = 'Dynamic in-app experience SDK for iOS.'
  s.description      = <<-DESC
    Digia Engage is an iOS SDK for rendering Digia-managed experiences inside
    host applications. It provides dynamic page rendering, slots, overlays,
    dialogs, toasts, action execution, and cached raster/SVG image loading for
    SwiftUI-based integrations.
  DESC

  s.homepage         = 'https://github.com/Digia-Technology-Private-Limited/digia_engage_ios'
  s.license          = { :type => 'BSL 1.1', :file => 'LICENSE' }
  s.author           = { 'Digia Engg' => 'engg@digia.tech' }
  s.source           = { :git => 'https://github.com/Digia-Technology-Private-Limited/digia_engage_ios.git', :tag => s.version.to_s }

  s.platform         = :ios, '16.0'
  s.swift_versions   = ['5.10', '6.0']

  s.source_files     = 'Sources/DigiaEngage/**/*.swift'
  s.resource_bundles = {
    'DigiaEngageResources' => ['Sources/DigiaEngage/Resources/**/*']
  }

  s.dependency 'DigiaExpr', '0.1.0'
  s.dependency 'lottie-ios', '~> 4.5'
  s.dependency 'SDWebImageSwiftUI', '~> 3.1'
  # Keep aligned with Expo / expo-image (`~> 1.7.0`) so host apps can resolve pods without conflict.
  s.dependency 'SDWebImageSVGCoder', '~> 1.7.0'
end
