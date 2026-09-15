# Artifact compatibility

| Adapter | Adapter version | Native runtime |
| --- | --- | --- |
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
| Apple `TugboatCaptureRuntime` | 0.1.1 | Rejects transparent and near-white captures and validates explicit view-hierarchy capture before encoding. |
| Flutter `tugboat` | 0.8.16 | Same hosted runtimes as 0.8.15. iOS plugin looks up `registrar.viewController` at runtime so Flutter 3.35 hosts compile. |
| Flutter `tugboat` | 0.8.15 | Android `com.gettugboat.sdk:capture-runtime:0.1.0` from Maven Central. Apple `TugboatCaptureRuntime` `0.1.0` from CocoaPods trunk. Plugin iOS floor 15. |
| Flutter `tugboat` | 0.8.14 | Android `com.gettugboat.sdk:capture-runtime:0.1.0` from Maven Central. Apple `TugboatCaptureRuntime` 0.1.x compiled from monorepo sources (unpublished CocoaPod is not required). Plugin iOS floor 12; native capture still reports unsupported below iOS 15. |
| Flutter `tugboat` | 0.8.13 | Android `capture-runtime` 0.1.x compiled from monorepo sources (hosted Maven is not required). Apple `TugboatCaptureRuntime` 0.1.x compiled from monorepo sources (unpublished CocoaPod is not required). Plugin iOS floor 12; native capture still reports unsupported below iOS 15. |
| Flutter `tugboat` | 0.8.12 | none (Flutter `flutterRepaintBoundary` only; session identity stamp patch) |
| Apple `TugboatCaptureRuntime` | 0.1.0 | CocoaPods trunk / SwiftPM git tag; iOS 15 live Flutter-layer CPU path |
| `@tugboat/react-native` | — | not started |

Flutter `0.8.16` compiles on Flutter 3.35 and consumes Android
`capture-runtime` `0.1.0` from Maven Central and Apple
`TugboatCaptureRuntime` `0.1.0` from CocoaPods. Native capture stays
opt-in. The first native-default adapter is still planned as Flutter `0.9.0`.

CI requires this table to change whenever Flutter adapter source or the
public Android/C ABI or Apple Swift surface changes
(`tool/ci/check-version-policy.sh`).
