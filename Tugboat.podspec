# The Swift host (`Tugboat`): the engine host, the UIKit and SwiftUI adapter,
# capture and the network helpers. Unpublished: the React Native SDK uses it
# from a local path (sdks/react-native/README.md). The same sources as the
# `Tugboat` target in Package.swift; the version is `TugboatVersion.current`.
Pod::Spec.new do |s|
  s.name             = 'Tugboat'
  s.version          = '0.1.0'
  s.summary          = 'Tugboat session capture for iOS apps.'
  s.homepage         = 'https://github.com/blendto/tugboat-mobile-sdk'
  s.license          = { :type => 'AGPL-3.0-only', :file => 'LICENSE' }
  s.author           = { 'Tugboat' => 'dev@bijatech.com' }
  s.source           = { :git => 'https://github.com/blendto/tugboat-mobile-sdk.git', :tag => "apple-host-v#{s.version}" }
  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.9'
  s.static_framework = true
  s.source_files     = 'platforms/apple/Sources/Tugboat/**/*.swift'
  s.resource_bundles = { 'TugboatPrivacy' => ['platforms/apple/Sources/Tugboat/PrivacyInfo.xcprivacy'] }
  s.dependency 'TugboatSessionEngine'
  s.dependency 'TugboatCaptureRuntime'
  s.frameworks       = 'UIKit', 'SwiftUI'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }
end
