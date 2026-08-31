# Apple development

Milestone 2. This repository currently ships an iOS **capability stub** in
`sdks/flutter/packages/tugboat/ios` so `getCapabilities` reports native
capture as unavailable. `capture` returns `unsupportedApi`.

The Swift module / CocoaPod `TugboatCaptureRuntime` 0.1.0, root
`Package.swift`, and `TugboatCaptureRuntime.podspec` are not in this
milestone. CI `verify-swift-api.sh` skips until `Package.swift` exists.

Do not start Metal work before the CPU baseline exists
([gpu.md](../roadmap/gpu.md)).
