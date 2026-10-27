# Artifact compatibility

| Adapter | Adapter version | Native runtime |
| --- | --- | --- |
| Flutter `tugboat` | 0.10.11-dev.6 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; prerelease; scene inventory hashes come from one internal helper shared with the engine conformance fixtures; no behaviour change. |
| Flutter `tugboat` | 0.10.11-dev.5 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; prerelease honouring HTTP `Retry-After` on 429/503 per delivery lane (`CollectorHttpSink` waits before retrying that lane, capped by the new `TugboatCollectorConfig.retryAfterCap` / `endingRetryAfterCap`). After `endSession`, a `session_end` with a retry outcome is re-posted every `eventFlushInterval` (default 3 s) until accepted or dropped; a dropped one (any status other than 202, 408, 429, 5xx) is not re-posted. |
| Flutter `tugboat` | 0.10.11-dev.4 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; prerelease adding the `.tugboatTag` / `.tugboatSensitive` / `.tugboatSubView` marker extensions and an opt-in `accessibility` identifier on tags; no default behaviour change. |
| Flutter `tugboat` | 0.10.11-dev.3 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; prerelease with a test-only collector sink wall clock; no behaviour change. |
| Flutter `tugboat` | 0.10.11-dev.2 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; prerelease; the Android plugin also compiles against newer runtime enum values; no behaviour change. |
| Flutter `tugboat` | 0.10.11-dev.1 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; prerelease with test-only controller seams; no behaviour change. |
| Flutter `tugboat` | 0.10.10 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; seeds the visible navigator route at session start via one `route_change` with `navigation: session_start` before the initial capture. |
| Flutter `tugboat` | 0.10.9 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; isolates rejected frame batches and reports bounded collector upload diagnostics. |
| Flutter `tugboat` | 0.10.8 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; dHash coalescing respects visible-structure changes and keeps its baseline; opt-in `focus_changed` / `system_input` evidence. |
| Flutter `tugboat` | 0.10.7 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; API error `network_call` events carry a bounded `errorResponseBody` (4 KiB cap). |
| Flutter `tugboat` | 0.10.6 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; collector frame uploads include `frameMetadata` for `raw_frames` ingestion. |
| Flutter `tugboat` | 0.10.5 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; iOS launch inputs also accepted from launch arguments (environment wins). |
| Flutter `tugboat` | 0.10.4 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; canonical `interaction` events include `targetAnchor.canonicalPath` on collector payloads. |
| Flutter `tugboat` | 0.10.3 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; non-secret automation run correlation id on the launch plumbing. |
| Flutter `tugboat` | 0.10.2 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; HTTP error `network_call` mapping; opt-in collector HTTP proof logging. |
| Flutter `tugboat` | 0.10.1 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; session lifecycle posts include `atMs`. |
| Flutter `tugboat` | 0.10.0 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; Device Farm launch inputs owned by the SDK; `hidden` + `paused` coalesce into one `app_backgrounded`. |
| Flutter `tugboat` | 0.9.0 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; mode-free capture API with additive evidence capabilities. |
| Flutter `tugboat` | 0.8.17 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; blank iOS engine captures retry with explicit hierarchy coverage. |
| Android `tugboat-android` | 0.1.0 | Unpublished. Native Android SDK on the session engine, with Android `capture-runtime` `0.3.0`. Includes coded events (`Tugboat.eventHook`) and manual `network_call` evidence (`Tugboat.beginNetworkCall`), with the same payload as Flutter, bounded in the engine. |
| Android `tugboat-okhttp` | 0.1.0 | Unpublished. OkHttp interceptor for `network_call` evidence; needs `tugboat-android` 0.1.0 and OkHttp 3.14.9 or later (`compileOnly`). |
| Apple `Tugboat` (SwiftPM) | 0.1.0 | Unpublished. Native SwiftUI SDK on the session engine, with Apple `TugboatCaptureRuntime` `0.2.0`. Includes coded events, manual `network_call` evidence, an opt-in instrumented `URLSession`, and the `async` `Tugboat.data(for:)` helper (no swizzling). |
| Apple `TugboatAlamofire` (SwiftPM) | 0.1.0 | Unpublished. Alamofire `EventMonitor` for `network_call` evidence; its own package, needing `Tugboat` 0.1.0 and Alamofire 5.9.0 or later. |
| Apple `TugboatCaptureRuntime` | 0.2.0 | Unpublished. Additive `capture(view:request:maskSupplier:onComplete:)`: masks computed on the main thread immediately before each draw (`MaskSnapshot`); `CaptureRequest.lastStructureSignature` and `pixelsPerPoint`, `CaptureTimings.maskComputeMicros`, `CaptureResult.maskSnapshot`. No new `CaptureStatus` or `CaptureCoverage` cases. |
| Apple `TugboatCaptureRuntime` | 0.1.1 | Rejects transparent and near-white captures and validates explicit view-hierarchy capture before encoding. |
| Flutter `tugboat` | 0.8.16 | Same hosted runtimes as 0.8.15. iOS plugin looks up `registrar.viewController` at runtime so Flutter 3.35 hosts compile. |
| Flutter `tugboat` | 0.8.15 | Android `com.gettugboat.sdk:capture-runtime:0.1.0` from Maven Central. Apple `TugboatCaptureRuntime` `0.1.0` from CocoaPods trunk. Plugin iOS floor 15. |
| Flutter `tugboat` | 0.8.14 | Android `com.gettugboat.sdk:capture-runtime:0.1.0` from Maven Central. Apple `TugboatCaptureRuntime` 0.1.x compiled from monorepo sources (unpublished CocoaPod is not required). Plugin iOS floor 12; native capture still reports unsupported below iOS 15. |
| Flutter `tugboat` | 0.8.13 | Android `capture-runtime` 0.1.x compiled from monorepo sources (hosted Maven is not required). Apple `TugboatCaptureRuntime` 0.1.x compiled from monorepo sources (unpublished CocoaPod is not required). Plugin iOS floor 12; native capture still reports unsupported below iOS 15. |
| Flutter `tugboat` | 0.8.12 | none (Flutter `flutterRepaintBoundary` only; session identity stamp patch) |
| Apple `TugboatCaptureRuntime` | 0.1.0 | CocoaPods trunk / SwiftPM git tag; iOS 15 live Flutter-layer CPU path |
| `@tugboat/react-native` | — | not started |

Apple `Tugboat` (unpublished 0.1.0) follows Flutter's activation contract
(`enabled` default false, `activate`/`deactivate`).

Flutter `0.8.16` compiles on Flutter 3.35 and consumes Android
`capture-runtime` `0.1.0` from Maven Central and Apple
`TugboatCaptureRuntime` `0.1.0` from CocoaPods. Native capture stays
opt-in. The first native-default adapter is still planned as Flutter `0.9.0`.

Android `capture-runtime` `0.3.0` is unpublished (0.2.0 was never
published). It adds window capture (`windowComposite`),
`CaptureStatus.SecureWindow`, and masks supplied on the main thread at copy
time (`WindowMaskSupplier`) for native Android hosts. Only the unpublished
native SDK (`tugboat-android`) consumes it; Flutter `tugboat` still pins
`0.1.0`.

Apple `TugboatCaptureRuntime` `0.2.0` is unpublished. It adds a mask
supplier that runs in the same main-thread turn as the draw, for the native
SwiftUI SDK (`Tugboat`, unpublished), which is its only consumer. Flutter
`tugboat` still pins `0.1.1` and keeps the request-mask path unchanged.

CI requires this table to change whenever Flutter adapter source or the
public Android/C ABI or Apple Swift surface changes
(`tool/ci/check-version-policy.sh`).
