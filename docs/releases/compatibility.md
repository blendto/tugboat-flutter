# Artifact compatibility

| Adapter | Adapter version | Native runtime |
| --- | --- | --- |
| Flutter `tugboat` | 0.12.9 | Android `capture-runtime` `0.1.0`, Apple `TugboatCaptureRuntime` `0.1.1`, `tugboat_dio` 0.12.9, and `tugboat_http` 0.12.9. Tap anchors: `actions` are the tapped element's own (no `scroll` from a scrollable parent; none when disabled), and a text field reports role `textField`. No fingerprint, route key or inventory hash change. |
| Flutter `tugboat` | 0.12.8 | Android `capture-runtime` `0.1.0`, Apple `TugboatCaptureRuntime` `0.1.1`, `tugboat_dio` 0.12.8, and `tugboat_http` 0.12.8. Privacy fix: screenshot masks now cover text, images (every `Icon` glyph is text, so icons are masked, except an `IconButton` icon at `allTextExceptActionable`) and `TugboatSensitive` under `ExcludeSemantics`, behind modal routes and under `TugboatInternal`, which earlier versions sent unmasked; a mask that cannot be computed fails the capture. No fingerprint, route key or inventory hash change. |
| Flutter `tugboat` | 0.12.7 | Android `capture-runtime` `0.1.0`, Apple `TugboatCaptureRuntime` `0.1.1`, `tugboat_dio` 0.12.7, and `tugboat_http` 0.12.7. A failing sink `start()` / `dispose()` future or a throwing sink factory no longer raises an uncaught error in the host app; a throwing factory is skipped and capture still starts. No fingerprint, route key or inventory hash change. |
| Flutter `tugboat` | 0.12.6 | Android `capture-runtime` `0.1.0`, Apple `TugboatCaptureRuntime` `0.1.1`, `tugboat_dio` 0.12.6, and `tugboat_http` 0.12.6. Adds the `.tugboatTag` / `.tugboatSensitive` / `.tugboatSubView` marker extensions and an opt-in `accessibility` identifier on tags; the Android plugin also compiles against newer runtimes; no default behaviour, fingerprint, route key or inventory hash change. |
| Flutter `tugboat` | 0.12.5 | Android `capture-runtime` `0.1.0`, Apple `TugboatCaptureRuntime` `0.1.1`, `tugboat_dio` 0.12.5, and `tugboat_http` 0.12.5 (now lockstep with `tugboat`; previously 0.1.0). iOS `session_start` `device.model` is the hardware identifier (`iPhone17,1`) instead of `iPhone`; Android unchanged; no fingerprint, route key or inventory hash change. |
| Flutter `tugboat` | 0.12.4 | Android `capture-runtime` `0.1.0`, Apple `TugboatCaptureRuntime` `0.1.1`, and `tugboat_dio` 0.12.4. Production `tap` interactions carry `routeKey`, the route key their fingerprint was hashed under; no fingerprint, route key or inventory hash change. |
| Flutter `tugboat` | 0.12.3 | Android `capture-runtime` `0.1.0`, Apple `TugboatCaptureRuntime` `0.1.1`, and `tugboat_dio` 0.12.3. Session and event IDs are `session-<UUIDv4>` / `event-<UUIDv4>` instead of epoch-microsecond and counter IDs (consumers must treat IDs as opaque); frame uploads add `frameMetadata.triggeredAt`; no fingerprint, route key or inventory hash change. |
| Flutter `tugboat` | 0.12.2 | Android `capture-runtime` `0.1.0`, Apple `TugboatCaptureRuntime` `0.1.1`, and `tugboat_dio` 0.12.2. Documentation release. |
| Flutter `tugboat` | 0.12.0 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; exploration scene inventories no longer carry `loading` or per-element `placeholder`, and the `TugboatLoading` marker is removed (breaking for hosts that used it); the settled re-sample no longer treats placeholder to loaded as new; no fingerprint, route key or inventory hash change; `tugboat_dio` 0.12.0 is a compatibility release. |
| Flutter `tugboat` | 0.11.6 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; opt-in `capturePressDuration` (default off) adds `payload.pressDurationMs` to tap interactions; the gesture stays `tap`; `tugboat_dio` 0.11.6 is a compatibility release. |
| Flutter `tugboat` | 0.11.5 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; identity contract change: `session_start` sends `appInfo.installationId`, an SDK-minted UUID persisted on first launch (seeded from `identifierForVendor` on iOS) unless the host passes its own; `fromPlatform` and `loadAppInfo` take an optional `installationId`; new dependency `path_provider`; `tugboat_dio` 0.11.5 is a compatibility release. Minimum SDKs unchanged (Flutter 3.35.0, Dart 3.9.2). |
| Flutter `tugboat` | 0.11.4 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; a navigating tap on a button's padding resolves to the button's `GestureDetector` (the glyph tap's and scene inventory's layer) instead of its `InkWell`; pointer-down path only; `tugboat_dio` 0.11.4 is a compatibility release. |
| Flutter `tugboat` | 0.11.3 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; no `tugboat` runtime change. `tugboat_dio` 0.11.3 adds opt-in `errorBodyDenyUrls` and `errorBodyUrls` to choose which request URLs may keep an HTTP error response body (matched on host and path only); the default still retains every error body. |
| Flutter `tugboat` | 0.11.2 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; `health.sinks` `pending` and `dropped` count the collector sink's queued, in-flight and discarded events and frames, including backlog cleared by a new session or dispose, as process-wide totals across activations (they read 0 before); collector lifecycle and diagnostic `atMs` come from a monotonic clock on the event `atMs` time base, not wall-clock differences. |
| Flutter `tugboat` | 0.11.1 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; collector flushes queue a follow-up pass, time out session and event posts, interleave frames with event batches, keep referenced frames under a byte-bounded queue, and report `collector_request` / `collector_flush` diagnostics. |
| Flutter `tugboat` | 0.11.0 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; exploration taps carry `fingerprintSource` and `routeKey` next to `fingerprintConfidence`; scene inventories and exploration taps carry `surface` (`kind`, optional `widgetClass`); scene inventories carry `viewport`, `scroll` and per-element `visibleFraction` (logical pixels, documented reference frame); the SDK's capture root is no longer read as a tag; a tap on a control outside the navigator keeps its origin fingerprint; the exploration WebSocket (`explorationCollectorUrl`, `TugboatExplorationTransport`) is removed, so the HTTP collector is the only built-in destination. |
| Flutter `tugboat` | 0.10.11 | Android `capture-runtime` `0.1.0`; Apple `TugboatCaptureRuntime` `0.1.1`; a tap whose handler navigates keeps its `targetAnchor` (resolved from the pointer-down hit path when the pointer-up hit test is absorbed). |
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
| Android `tugboat-android` | 0.1.0 | Unpublished. Native Android SDK on the session engine, with Android `capture-runtime` `0.3.1`. Includes coded events (`Tugboat.eventHook`) and manual `network_call` evidence (`Tugboat.beginNetworkCall`), with the same payload as Flutter, bounded in the engine. |
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

The native SDKs, Android `tugboat-android` and Apple `Tugboat` (both unpublished 0.1.0), follow
Flutter's activation contract (`enabled` default false, `activate`/`deactivate`).

Flutter `0.8.16` compiles on Flutter 3.35 and consumes Android
`capture-runtime` `0.1.0` from Maven Central and Apple
`TugboatCaptureRuntime` `0.1.0` from CocoaPods. Native capture stays
opt-in. The first native-default adapter is still planned as Flutter `0.9.0`.

Android `capture-runtime` `0.3.1` is unpublished (0.2.0 was never
published). It adds window capture (`windowComposite`),
`CaptureStatus.SecureWindow`, and masks supplied on the main thread at copy
time (`WindowMaskSupplier`) for native Android hosts. `0.3.1` also makes
`CaptureRuntime.dispose()` answer queued captures with `Disposed` (no API
change). Only the unpublished native SDK (`tugboat-android`) consumes it;
Flutter `tugboat` still pins `0.1.0`.

Apple `TugboatCaptureRuntime` `0.2.0` is unpublished. It adds a mask
supplier that runs in the same main-thread turn as the draw, for the native
SwiftUI SDK (`Tugboat`, unpublished), which is its only consumer. Flutter
`tugboat` still pins `0.1.1` and keeps the request-mask path unchanged.

CI requires this table to change whenever Flutter adapter source or the
public Android/C ABI or Apple Swift surface changes
(`tool/ci/check-version-policy.sh`).
