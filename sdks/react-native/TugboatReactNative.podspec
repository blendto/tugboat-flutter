require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# Autolinked into the app by React Native's CLI. The Swift host comes from the
# app's Podfile (local paths in this repository): see README.md.
Pod::Spec.new do |s|
  s.name         = "TugboatReactNative"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = "https://github.com/blendto/tugboat-mobile-sdk"
  s.license      = { :type => "AGPL-3.0-only" }
  s.author       = { "Tugboat" => "dev@bijatech.com" }
  s.platforms    = { :ios => "15.1" }
  s.source       = { :git => "https://github.com/blendto/tugboat-mobile-sdk.git", :tag => "react-native-v#{s.version}" }
  s.swift_version = "5.9"
  s.source_files = "ios/**/*.{h,m,mm,cpp,swift}"
  s.private_header_files = "ios/**/*.h"
  s.dependency "Tugboat"
  s.pod_target_xcconfig = { "DEFINES_MODULE" => "YES" }

  install_modules_dependencies(s)
end
