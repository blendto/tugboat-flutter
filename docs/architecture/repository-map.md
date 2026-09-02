# Repository map

| Path | Product |
| --- | --- |
| `core/image-processing` | Portable C++ CPU core (C ABI) |
| `platforms/android` | `com.gettugboat.sdk:capture-runtime` AAR |
| `platforms/apple` | `TugboatCaptureRuntime` SwiftPM / CocoaPod (experimental iOS CPU) |
| `sdks/flutter/packages/tugboat` | Flutter adapter / plugin |
| `sdks/flutter/packages/tugboat_dio` | Dio evidence adapter |
| `sdks/react-native` | Future adapter placeholder |
| `docs/` | Architecture, integration, privacy, performance, releases |
| `tool/ci` | Host test, generate, and release-control scripts |
| `tool/benchmarks` | Device-lab capture protocol (not CI) |
| `Package.swift` | Root SwiftPM entry for `TugboatCaptureRuntime` |

`Package.swift` and `TugboatCaptureRuntime.podspec` stay at the repository
root. Swift Package Manager resolves a remote package from the root. The
package references sources under `platforms/apple` and
`core/image-processing`.

Do not copy the C++ core into the published pub package. Files above a
published pub archive are not part of that archive. The Flutter Android
plugin depends on Maven Central `com.gettugboat.sdk:capture-runtime`. The
iOS plugin compiles Apple runtime sources when `platforms/apple` resolves;
published pub archives omit that tree and stub iOS native capture.
Native Android apps consume Maven Central or the local Maven AAR; native
Apple apps still use the root CocoaPod / SwiftPM package.

Ownership rules: [repository-scope.md](repository-scope.md).
Build commands: [common-build.md](../integration/common-build.md).
