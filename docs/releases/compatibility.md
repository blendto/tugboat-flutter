# Artifact compatibility

| Adapter | Adapter version | Native runtime |
| --- | --- | --- |
| Flutter `tugboat` | 0.8.13 | Android `capture-runtime` 0.1.x compiled from monorepo sources (unpublished Maven is not required). Apple `TugboatCaptureRuntime` 0.1.x compiled from monorepo sources (unpublished CocoaPod is not required). Plugin iOS floor 12; native capture still reports unsupported below iOS 15. |
| Flutter `tugboat` | 0.8.12 | none (Flutter `flutterRepaintBoundary` only; session identity stamp patch) |
| Flutter `tugboat` | 0.9.0 (planned) | Android `capture-runtime` 0.1.x and Apple `TugboatCaptureRuntime` 0.1.x |
| Apple `TugboatCaptureRuntime` | 0.1.0 | unpublished local CocoaPod / SwiftPM; iOS 15 live Flutter-layer CPU path |
| `@tugboat/react-native` | — | not started |

The first tagged pair after gates pass will be `flutter-v0.9.0` with
`capture-runtime-v0.1.0`. Until then native capture stays opt-in and the
Flutter package remains on the 0.8.x line. Do not publish Apple `0.1.0`.

CI requires this table to change whenever Flutter adapter source or the
public Android/C ABI or Apple Swift surface changes
(`tool/ci/check-version-policy.sh`).
