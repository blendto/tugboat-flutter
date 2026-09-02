Pod::Spec.new do |s|
  s.name             = 'TugboatCaptureRuntime'
  s.version          = '0.1.0'
  s.summary          = 'Tugboat native CPU screenshot capture for Apple platforms.'
  s.description      = <<-DESC
Experimental Apple capture runtime. Renders the live Flutter layer into a
native bitmap, applies privacy masks and dHash through the portable C++ core,
encodes JPEG with ImageIO, and returns masked JPEG bytes only. A view-hierarchy
compatibility mode remains available for UIKit platform views.
                       DESC
  s.homepage         = 'https://github.com/blendto/tugboat-flutter'
  s.license          = { :type => 'AGPL-3.0-only', :file => 'LICENSE' }
  s.author           = { 'Tugboat' => 'dev@bijatech.com' }
  s.source           = { :git => 'https://github.com/blendto/tugboat-flutter.git', :tag => "apple-runtime-v#{s.version}" }
  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.9'
  s.static_framework = true
  s.source_files     = [
    'platforms/apple/Sources/TugboatCaptureRuntime/**/*.swift',
    'platforms/apple/Sources/TugboatImageCoreBridge/**/*.{h,mm}',
    'core/image-processing/src/**/*.cpp',
    'core/image-processing/include/**/*.h',
  ]
  s.public_header_files = 'platforms/apple/Sources/TugboatImageCoreBridge/**/*.h'
  s.private_header_files = 'core/image-processing/include/**/*.h'
  s.libraries        = 'c++'
  s.frameworks       = 'UIKit', 'ImageIO', 'CoreGraphics', 'UniformTypeIdentifiers'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/core/image-processing/include"',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
