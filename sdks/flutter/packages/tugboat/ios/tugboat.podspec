#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint tugboat.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'tugboat'
  s.version          = '0.8.13'
  s.summary          = 'Screenshot-based session replay with compact interaction anchors for Tugboat.'
  s.description      = <<-DESC
    Flutter adapter for Tugboat session replay. Native CPU capture is experimental
opt-in on Android (PixelCopy) and iOS (live Flutter layer). The default remains
Flutter RepaintBoundary. The plugin does not depend on unpublished CocoaPods;
monorepo checkouts compile Apple runtime sources, and published packages stub
native capture as unsupported.
                       DESC
  s.homepage         = 'https://github.com/blendto/tugboat-flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Tugboat' => 'dev@bijatech.com' }
  s.source           = { :path => '.' }
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.static_framework = true
  s.swift_version = '5.9'

  apple_runtime = File.join(__dir__, 'NativeRuntime/TugboatCaptureRuntime')
  apple_bridge = File.join(__dir__, 'NativeRuntime/TugboatImageCoreBridge')
  image_core = File.join(__dir__, 'NativeRuntime/image-processing')
  has_native =
    File.file?(File.join(apple_runtime, 'CaptureRuntime.swift')) &&
    File.file?(File.join(apple_bridge, 'TugboatImageCoreBridge.h')) &&
    File.file?(File.join(image_core, 'include/tugboat/tb_image_core.h'))

  if has_native
    s.source_files = [
      'Classes/**/*',
      'NativeRuntime/TugboatCaptureRuntime/**/*.swift',
      'NativeRuntime/TugboatImageCoreBridge/**/*.{h,mm}',
      'NativeRuntime/image-processing/src/**/*.cpp',
      'NativeRuntime/image-processing/include/**/*.h',
    ]
    s.exclude_files = 'Classes/CaptureRuntimeStub.swift'
    s.public_header_files = 'NativeRuntime/TugboatImageCoreBridge/**/*.h'
    s.private_header_files = 'NativeRuntime/image-processing/include/**/*.h'
    s.libraries = 'c++'
    s.frameworks = 'UIKit', 'ImageIO', 'CoreGraphics'
    s.pod_target_xcconfig = {
      'DEFINES_MODULE' => 'YES',
      'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
      'CLANG_CXX_LIBRARY' => 'libc++',
      'HEADER_SEARCH_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/NativeRuntime/image-processing/include"',
      'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    }
  else
    s.source_files = 'Classes/**/*'
    s.pod_target_xcconfig = {
      'DEFINES_MODULE' => 'YES',
      'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    }
  end
end
