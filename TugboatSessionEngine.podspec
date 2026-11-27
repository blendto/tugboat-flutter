# The portable C++ session engine behind the C ABI (ADR 0009), for the
# `Tugboat` pod. Unpublished: apps use it from a local path (see
# sdks/react-native/README.md). The same sources as the `TugboatSessionEngine`
# target in Package.swift.
Pod::Spec.new do |s|
  s.name             = 'TugboatSessionEngine'
  s.version          = '0.1.0'
  s.summary          = 'Tugboat session engine (C++ core, C ABI).'
  s.homepage         = 'https://github.com/blendto/tugboat-mobile-sdk'
  s.license          = { :type => 'AGPL-3.0-only', :file => 'LICENSE' }
  s.author           = { 'Tugboat' => 'dev@bijatech.com' }
  s.source           = { :git => 'https://github.com/blendto/tugboat-mobile-sdk.git', :tag => "session-engine-v#{s.version}" }
  s.ios.deployment_target = '15.0'
  s.static_framework = true
  s.source_files     = [
    'core/session-engine/src/**/*.{cpp,h}',
    'core/session-engine/third_party/double-conversion/double-conversion/*.{cc,h}',
    'core/session-engine/include/**/*.h',
  ]
  s.public_header_files = 'core/session-engine/include/**/*.h'
  s.private_header_files = [
    'core/session-engine/src/**/*.h',
    'core/session-engine/third_party/**/*.h',
  ]
  s.libraries        = 'c++'
  # The engine is C++17 (Package.swift); react_native_post_install sets C++20 on every pod,
  # and std::vector of the incomplete json Member does not compile there.
  s.compiler_flags   = '-std=c++17'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/core/session-engine/include" "$(PODS_TARGET_SRCROOT)/core/session-engine/src" "$(PODS_TARGET_SRCROOT)/core/session-engine/third_party/double-conversion"',
  }
end
