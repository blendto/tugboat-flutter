# Repository map

| Path | Product |
| --- | --- |
| `core/image-processing` | Portable C++ CPU core (C ABI) |
| `platforms/android` | `com.tugboat.sdk:capture-runtime` AAR |
| `platforms/apple` | Apple runtime (milestone 2) |
| `sdks/flutter/packages/tugboat` | Flutter adapter / plugin |
| `sdks/flutter/packages/tugboat_dio` | Dio evidence adapter |
| `sdks/react-native` | Future adapter placeholder |
| `docs/` | Architecture, integration, privacy, performance, releases |
| `tool/ci` | Host test, generate, and release-control scripts |
| `tool/benchmarks` | Device-lab capture protocol (not CI) |
| `Package.swift` | Planned root SwiftPM entry (milestone 2) |

`Package.swift` and `TugboatCaptureRuntime.podspec` stay at the repository
root when Apple packaging lands. Swift Package Manager resolves a remote
package from the root. The package will reference sources under
`platforms/apple` and `core/image-processing`.

Do not copy the C++ core into the pub package. Files above a published pub
archive are not part of that archive. Flutter consumes published (or local
Maven) native artifacts.

Ownership rules: [repository-scope.md](repository-scope.md).
Build commands: [common-build.md](../integration/common-build.md).
