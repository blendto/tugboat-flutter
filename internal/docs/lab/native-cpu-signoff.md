# Native CPU capture privacy sign-off

Status: host-side checks landed; device JPEG checks remain

Authoritative rules:
[native-capture-contracts.md](../../../docs/architecture/native-capture-contracts.md).

Stop shipping the experimental backend if any row below is fail.

| Gate | Evidence | Host | Device |
| --- | --- | --- | --- |
| Raw RGBA never crosses the Pigeon request | `NativeCaptureRequest.encode()` has no `Uint8List`; request fields are ids, sizes, force, dHash, normalized masks | [x] `native_privacy_contract_test.dart` | n/a |
| Failure replies carry empty JPEG | Cancelled / fallback status uses empty `jpeg` | [x] `native_cpu_backend_test.dart` | n/a |
| Native success does not also run Flutter encode | Throwing Flutter encoder is unused on native `ok` | [x] `native_cpu_backend_test.dart` | n/a |
| Cancellation does not fall back | Native `cancelled` does not call the Flutter source | [x] `native_cpu_backend_test.dart` | n/a |
| Stale `requestId` does not publish | Stale completion returns cancelled, empty JPEG | [x] `native_cpu_backend_test.dart` | n/a |
| Masks are normalized CaptureBoundary space | Widget fixture → native request masks | [x] `native_privacy_contract_test.dart` | n/a |
| Opaque fill `(0x1a,0x1a,0x1a,0xff)` after native mapping | Decode JPEG in the host test | [x] `native_privacy_contract_test.dart` | [~] API 35 emulator debug A/B (PR comment); physical release still open |
| Edge / corner masks | Host mapping + fixture | [x] mapping unit test | [ ] after rotation |
| Capture scale / density / landscape / insets | Host native JPEG fixture | [x] `native_privacy_contract_test.dart` | [ ] PixelCopy |
| Force flag forwarded | Native request `force: true` | [x] | [ ] interaction frames |
| dHash bit-for-bit with Dart | C++ goldens vs `perceptual_hash.dart` | [x] `tb_image_core_test.cpp` | [ ] live frame |
| No pixel/JPEG logs | Plugin and runtime do not log buffers | [x] source review | [ ] logcat on device |
| Replay acceptance still green | Default Flutter backend | [x] 379 `tugboat` tests | [ ] Android instrumentation |
| Apple MaskMapper floor/ceil | XCTest `MaskMapperTests` | [x] source + tests (needs Xcode to run) | n/a |
| Apple engine-surface JPEG opacity | Simulator decode: Flutter pixels and two opaque masks | [x] iPhone 17 Pro Simulator, iOS 26.5 | [ ] physical iOS 15+ |

Device-only PixelCopy rows stay open until a physical Android run of
`NativePrivacyFixtureScreen` through `nativeCpuExperimental` confirms opaque
tiles after real rotation, keyboard, and inset changes. Host widget tests
cover capture-scale, density, landscape layout, and view-inset mapping with
the same floor/ceil JPEG path as P6.02.

Apple physical-device rows remain open. The Simulator live-layer proof uses
Flutter engine-surface coverage. It does not prove UIKit platform-view
coverage.

Do not make native capture the default while any device row is open.
