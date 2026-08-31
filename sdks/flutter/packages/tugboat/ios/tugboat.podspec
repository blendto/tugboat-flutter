#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint tugboat.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'tugboat'
  s.version          = '0.8.12'
  s.summary          = 'Screenshot-based session replay with compact interaction anchors for Tugboat.'
  s.description      = <<-DESC
Flutter adapter for Tugboat session replay. Native CPU capture is experimental
opt-in on Android; Apple ships a capability stub in this milestone.
                       DESC
  s.homepage         = 'https://github.com/blendto/tugboat-flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Tugboat' => 'dev@bijatech.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
