# Artifact compatibility

| Adapter | Adapter version | Native runtime |
| --- | --- | --- |
| Flutter `tugboat` | 0.8.12 | Android `com.tugboat.sdk:capture-runtime` 0.1.x (local Maven; experimental). Apple `TugboatCaptureRuntime` 0.1.x (local CocoaPod / SwiftPM; experimental). |
| Flutter `tugboat` | 0.9.0 (planned) | Android `capture-runtime` 0.1.x and Apple `TugboatCaptureRuntime` 0.1.x |
| Apple `TugboatCaptureRuntime` | 0.1.0 | unpublished local CocoaPod / SwiftPM; iOS 15 view-hierarchy CPU path |
| `@tugboat/react-native` | — | not started |

The first tagged pair after gates pass will be `flutter-v0.9.0` with
`capture-runtime-v0.1.0`. Until then native capture stays opt-in and the
Flutter package remains on the 0.8.x line. Do not publish Apple `0.1.0`.

CI requires this table to change whenever Flutter adapter source or the
public Android/C ABI or Apple Swift surface changes
(`tool/ci/check-version-policy.sh`).
