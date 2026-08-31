# Artifact compatibility

| Adapter | Adapter version | Native runtime |
| --- | --- | --- |
| Flutter `tugboat` | 0.8.12 | `com.tugboat.sdk:capture-runtime` 0.1.x (local Maven; experimental) |
| Flutter `tugboat` | 0.9.0 (planned) | `com.tugboat.sdk:capture-runtime` 0.1.x |
| Apple `TugboatCaptureRuntime` | — | milestone 2 |
| `@tugboat/react-native` | — | not started |

The first tagged pair after gates pass will be `flutter-v0.9.0` with
`capture-runtime-v0.1.0`. Until then native capture stays opt-in and the
Flutter package remains on the 0.8.x line.

CI requires this table to change whenever Flutter adapter source or the
public Android/C ABI surface changes
(`tool/ci/check-version-policy.sh`).
