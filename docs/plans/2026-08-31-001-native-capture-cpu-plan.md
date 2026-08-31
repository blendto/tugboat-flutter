---
title: Native Screenshot Capture CPU Path - Plan
type: feat
date: 2026-08-31
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
execution: code
product_contract_source: native-capture-research
---

# Native Screenshot Capture CPU Path - Plan

## Status

- [x] Synchronize local `main` with `origin/main`.
- [x] Confirm that local `main` and `origin/main` are `dfc816190c8e247366a74d367c75ae1ba447a434`.
- [x] Create the local branch `feat/native-capture-cpu` (`4a3ebb1dcb7a79189f35ece3610dbb1d54443ae5`).
- [x] Establish and record the current performance baseline.
- [x] Start repository structure changes (local trees). GitHub rename to `tugboat-mobile` still needs administrator access.

No source files changed before this plan.

## Goal Capsule

Move screenshot capture and image processing out of the Flutter screenshot pipeline.
Use native platform capture APIs to obtain app pixels.
Use one portable C++ core for privacy masks, pixel validation, dHash calculation, and duplicate detection.
Use platform JPEG codecs for the first CPU implementation.
Return only masked JPEG data and bounded metadata to Flutter.

Keep the current Flutter `RepaintBoundary` path as the default during the first release.
Offer native CPU capture as an experimental opt-in backend.
Fall back to the current Flutter path when the native path is unavailable or fails safely.

Build the Android vertical slice first.
Build Apple parity after the Android performance and privacy gates pass.
Keep the repository ready for a future React Native adapter.
Investigate Metal and Android GPU processing only after the CPU baseline is stable.

Stop implementation if raw pixels can cross into Dart before masking.
Stop implementation if a failure can publish an unmasked frame.
Stop implementation if native and Flutter paths can publish the same capture twice.
Stop implementation if the native path cannot keep current session and frame semantics.

---

## Product and Technical Decisions

Authoritative contracts are
[repository-scope.md](../architecture/repository-scope.md),
[native-capture-contracts.md](../architecture/native-capture-contracts.md),
and [docs/decisions](../decisions). This plan is sequencing. If they
disagree, the architecture files win.

### Core decisions

- Use native platform code to capture pixels.
- Use C++17 for the portable image-processing core.
- Expose the core through a stable versioned C ABI.
- Use Kotlin for the Android runtime.
- Use Swift and Objective-C++ for the Apple runtime.
- Use Android platform JPEG encoding for the first Android path.
- Use ImageIO for the first Apple JPEG path.
- Keep JPEG encoding outside the portable C++ core for the first release.
- Keep SHA-256 inside each platform runtime.
- Do not use Rust for the first release.
- Do not vendor `libjpeg-turbo` for the first release.
- Do not implement GPU processing in the first release.
- Do not remove `TugboatCaptureBoundary` in the first release.

### Why C++ is the first common module

C++ has direct Android NDK support.
C++ works with Objective-C++ on Apple platforms.
C++ can access native bitmap memory without a second language bridge.
C++ has a smaller initial packaging surface than Rust for this repository.
C++ also keeps a direct path to Vulkan, OpenGL ES, Metal bridge code, and native codecs.

Rust remains a possible future internal implementation.
The stable C ABI will let the team replace the internal implementation without changing the platform adapters.

### Why the first core does not own JPEG encoding

Android and Apple already provide supported JPEG codecs.
Platform codecs reduce initial dependency and packaging work.
This approach avoids a vendored codec in Swift Package Manager and CocoaPods.
This approach also gives the fastest useful Android proof.

The benchmark must measure codec speed and output quality.
The team can test `libjpeg-turbo` later behind the same runtime interface.

### RepaintBoundary decision

The long-term architecture must not depend on Flutter for screenshot pixels.
The first release will still keep `TugboatCaptureBoundary` for fallback behavior.
The first release can also use Flutter data for mask geometry and capture scheduling.

The team can remove the boundary only after Android and Apple native paths have proven these capabilities:

- Correct app-content coordinate mapping.
- Correct privacy masks.
- Reliable lifecycle handling.
- Reliable engine-surface discovery.
- Acceptable platform-view coverage.
- Safe fallback behavior.
- Equal or better frame causality.

### Native capture coverage

Android will first capture the Flutter engine surface.
The first Android source will use `PixelCopy` with the active `FlutterSurfaceView`.
The runtime will detect other render modes.
The runtime will report unsupported modes through bounded status codes.

An engine-surface capture does not guarantee all final SurfaceFlinger layers.
Separate video surfaces, maps, platform views, and secure surfaces can be missing.
The runtime must report capture coverage with each result.

The first Apple path will capture the app view hierarchy.
The path will use `drawHierarchy(in:afterScreenUpdates:)` into a native bitmap context.
The runtime must report incomplete view-hierarchy capture.

System-wide screen recording is outside this SDK scope.
Android `MediaProjection` and Apple ScreenCaptureKit require user-visible permission flows.
These APIs are not suitable for transparent session replay capture.

---

## Public Identifiers

### Android artifact

- Maven group: `com.tugboat.sdk`
- Maven artifact: `capture-runtime`
- Initial version: `0.1.0`
- Full coordinate: `com.tugboat.sdk:capture-runtime:0.1.0`
- Android namespace: `com.tugboat.capture.runtime`
- Kotlin package root: `com.tugboat.capture`

### Flutter adapter

- Dart package: `tugboat`
- Android plugin namespace: `com.tugboat.flutter`
- Planned first native-capable version: `0.9.0`

### Apple artifact

- Swift module: `TugboatCaptureRuntime`
- CocoaPod: `TugboatCaptureRuntime`
- Initial version: `0.1.0`

### Future React Native adapter

- Android namespace: `com.tugboat.reactnative`
- Planned npm scope: `@tugboat`
- Planned npm package: `@tugboat/react-native`

The Maven group requires ownership and registry verification before public publication.
Local Maven publication does not require the public registry step.

---

## Performance Estimate

These values are planning estimates.
They are not measured results.

| Metric | Expected improvement |
| --- | ---: |
| End-to-end capture processing time | 25% to 55% |
| Dart UI-isolate capture work | 70% to 95% |
| Peak transient memory | 30% to 60% |
| Sustainable capture throughput | 1.3x to 2.2x |
| CPU use per captured frame | 20% to 45% |

The native path removes these major costs from Dart:

- Flutter RGBA conversion ownership.
- Full-frame `TransferableTypedData` copying.
- Raw image transfer to a Dart isolate.
- Dart image object allocation.
- Dart JPEG encoding.
- Dart SHA-256 work.

`PixelCopy` can still have a large readback cost.
The final result depends on device GPU, renderer, image size, and active UI composition.
The performance phase must use release builds on physical devices.

### Initial performance gates

- Require at least 35% lower p95 processing time before a wider rollout.
- Require at least 60% lower Flutter UI-isolate screenshot work.
- Require at least 25% lower peak transient memory.
- Require no new Flutter frame-drop regression.
- Require no privacy regression.
- Require acceptable JPEG quality and size.

Keep the backend experimental if these gates do not pass.

---

## Target Repository Structure

Rename the repository from `tugboat-flutter` to `tugboat-mobile`.

```text
tugboat-mobile/
├── core/
│   └── image-processing/
│       ├── include/
│       ├── src/
│       ├── tests/
│       ├── fuzz/
│       └── CMakeLists.txt
├── platforms/
│   ├── android/
│   │   ├── capture-runtime/
│   │   ├── capture-runtime-test/
│   │   ├── sample/
│   │   ├── build.gradle.kts
│   │   └── settings.gradle.kts
│   └── apple/
│       ├── Sources/
│       │   ├── TugboatCaptureRuntime/
│       │   └── TugboatImageCoreBridge/
│       ├── Tests/
│       └── Sample/
├── sdks/
│   ├── flutter/
│   │   ├── packages/
│   │   │   ├── tugboat/
│   │   │   └── tugboat_dio/
│   │   └── example/
│   └── react-native/
│       └── README.md
├── docs/
│   ├── architecture/
│   ├── decisions/
│   ├── integration/
│   ├── performance/
│   ├── privacy/
│   ├── releases/
│   └── roadmap/
├── tool/
│   ├── benchmarks/
│   ├── ci/
│   └── release/
├── Package.swift
├── TugboatCaptureRuntime.podspec
├── pubspec.yaml
├── README.md
└── LICENSE
```

`Package.swift` must stay at the repository root.
Swift Package Manager resolves a remote package from the repository root.
The package can reference sources under `platforms/apple` and `core/image-processing`.

The root podspec will use the same Apple and C++ source trees.
Android will compile the C++ core into its AAR.
Flutter will consume the published Android and Apple artifacts.
React Native will later consume the same artifacts.

Do not copy the common core into the Flutter package.
Files above a published pub package are not part of that package archive.

---

## Artifact and Version Model

| Component | Artifact | Version policy |
| --- | --- | --- |
| C++ image core | Internal static library | Runtime-owned |
| Android runtime | Maven AAR | Independent |
| Apple runtime | Swift package and CocoaPod | Independent |
| Flutter adapter | pub package | Independent with compatibility table |
| React Native adapter | npm package | Independent with compatibility table |

Use these initial tags:

- `capture-runtime-v0.1.0`
- `flutter-v0.9.0`

The compatibility table must map each adapter version to supported native runtime versions.
The first table entry will map Flutter `0.9.0` to native runtime `0.1.x`.

The first development flow will use local artifacts:

- Android will publish the AAR to an untracked local Maven repository.
- The Flutter example will include that local Maven repository.
- Apple will use a local CocoaPods path override during development.
- Apple will also build through the root Swift package.

Public registry publication will happen only after the privacy and performance gates pass.

---

## Scope Boundaries

### First milestone

The first milestone includes:

- Mobile monorepo structure.
- Architecture and scope documents.
- Portable C++ CPU processing core.
- Android native capture runtime.
- Android AAR production.
- Flutter Android plugin bridge.
- Opt-in native CPU backend.
- Automatic Flutter fallback.
- Privacy tests.
- Android performance tests.
- Local artifact publication.

### Second milestone

The second milestone includes:

- Apple runtime.
- Swift Package Manager support.
- CocoaPods support.
- Flutter Apple plugin bridge.
- Apple privacy tests.
- Apple performance tests.

### Deferred work

The following work is deferred:

- Making native capture the default.
- Removing `TugboatCaptureBoundary`.
- React Native implementation.
- Metal processing.
- Vulkan processing.
- OpenGL ES compute processing.
- A common JPEG codec.
- System-wide screen recording.
- Guaranteed capture of every platform view.
- Guaranteed capture of DRM or secure surfaces.

---

## Detailed Execution Checklist

### Phase 0 - Establish the baseline

- [x] P0.01 Fetch the latest `origin/main`.
- [x] P0.02 Fast-forward local `main`.
- [x] P0.03 Confirm that local `main` matches `origin/main`.
- [x] P0.04 Create `feat/native-capture-cpu`.
- [x] P0.05 Record the Flutter version.
- [x] P0.06 Record the Dart version.
- [x] P0.07 Record the Android Gradle Plugin version.
- [x] P0.08 Record the Android NDK version.
- [x] P0.09 Record the CMake version.
- [x] P0.10 Record the Xcode version.
- [x] P0.11 Record the current minimum Android API.
- [x] P0.12 Record the current minimum iOS version.
- [x] P0.13 Run `dart pub get`.
- [x] P0.14 Run the current format check.
- [x] P0.15 Run the current analyzer.
- [x] P0.16 Run the current complexity check.
- [x] P0.17 Run all current Dart and Flutter tests.
- [x] P0.18 Build the Android Flutter example in release mode.
- [x] P0.19 Record all existing failures.
- [x] P0.20 Record the current screenshot timing fields.
- [x] P0.21 Record the current screenshot memory behavior.
- [x] P0.22 Record the current JPEG output size.
- [x] P0.23 Save the baseline in `docs/performance/cpu-capture-baseline.md`.
- [x] P0.24 Confirm that baseline commands leave the branch clean.

### Phase 1 - Confirm architecture and contracts

- [x] P1.01 Write the mobile repository scope.
- [x] P1.02 Define the common core scope.
- [x] P1.03 Define the Android runtime scope.
- [x] P1.04 Define the Apple runtime scope.
- [x] P1.05 Define the Flutter adapter scope.
- [x] P1.06 Define the future React Native adapter scope.
- [x] P1.07 Define the native capture threat model.
- [x] P1.08 Define the raw-pixel ownership boundary.
- [x] P1.09 Define the mask-before-encode rule.
- [x] P1.10 Define the mask coordinate system.
- [x] P1.11 Define the capture result ownership rules.
- [x] P1.12 Define `engineSurface` coverage.
- [x] P1.13 Define `windowComposite` coverage.
- [x] P1.14 Document platform-view limits.
- [x] P1.15 Document video-surface limits.
- [x] P1.16 Document secure-surface limits.
- [x] P1.17 Define automatic fallback statuses.
- [x] P1.18 Define cancellation behavior.
- [x] P1.19 Define timeout behavior.
- [x] P1.20 Define duplicate-publication prevention.
- [x] P1.21 Define stage timing fields.
- [x] P1.22 Define bounded native diagnostics.
- [x] P1.23 Add ADR 0001 for the mobile monorepo.
- [x] P1.24 Add ADR 0002 for C++ instead of Rust.
- [x] P1.25 Add ADR 0003 for native artifact ownership.
- [x] P1.26 Add ADR 0004 for platform JPEG codecs.
- [x] P1.27 Add ADR 0005 for the opt-in Flutter rollout.
- [x] P1.28 Add ADR 0006 for mask coordinates.
- [x] P1.29 Add ADR 0007 for future GPU processing.
- [x] P1.30 Add ADR 0008 for independent versioning.

### Phase 2 - Rename and restructure the repository

The GitHub rename requires repository administrator access. P2.01–P2.07 and
pubspec/GitHub URL rewrites (P2.08–P2.11) wait on that rename. Local trees
use `sdks/flutter/packages/`. Overlay filesystems could not `git mv` across
devices; history is still recorded as renames via copy + `git rm`.

- [ ] P2.01 Rename the GitHub repository to `tugboat-mobile`.
- [ ] P2.02 Confirm that the old GitHub URL redirects.
- [ ] P2.03 Update `origin` to the new GitHub URL.
- [ ] P2.04 Confirm fetch access through the new URL.
- [ ] P2.05 Confirm push access through the new URL.
- [ ] P2.06 Rename the local directory to `tugboat-mobile`.
- [ ] P2.07 Reopen the repository from the new local path.
- [ ] P2.08 Update repository URLs in each `pubspec.yaml`.
- [ ] P2.09 Update issue tracker URLs.
- [ ] P2.10 Update documentation links.
- [ ] P2.11 Update badge links.
- [x] P2.12 Search for all `tugboat-flutter` references.
- [x] P2.13 Review each remaining old reference.
- [x] P2.14 Keep an old reference only when compatibility requires it.
- [x] P2.15 Create `sdks/flutter/packages`.
- [x] P2.16 Move `packages/tugboat` with `git mv`.
- [x] P2.17 Move `packages/tugboat_dio` with `git mv`.
- [x] P2.18 Move the Flutter example with `git mv`.
- [x] P2.19 Update root Dart workspace paths.
- [x] P2.20 Update local Dart path dependencies.
- [x] P2.21 Update Melos package discovery.
- [x] P2.22 Update CI path filters.
- [x] P2.23 Update test scripts.
- [x] P2.24 Update documentation paths.
- [x] P2.25 Run all Flutter tests from the new paths.
- [x] P2.26 Run `dart pub publish --dry-run` for `tugboat`.
- [x] P2.27 Run `dart pub publish --dry-run` for `tugboat_dio`.
- [x] P2.28 Confirm that Git preserves moved-file history.
- [x] P2.29 Create `core/image-processing`.
- [x] P2.30 Create `platforms/android`.
- [x] P2.31 Create `platforms/apple`.
- [x] P2.32 Create the new documentation directories.
- [x] P2.33 Create root build helper scripts.
- [x] P2.34 Add the React Native scope placeholder.
- [x] P2.35 Do not add an npm workspace yet.
- [x] P2.36 Keep the current AGPL-3.0-only license.
- [x] P2.37 Add a third-party notice process.

### Phase 3 - Build the C++ image-processing core

- [x] P3.01 Select C++17 as the minimum language level.
- [x] P3.02 Add the CMake project.
- [x] P3.03 Add a static library target.
- [x] P3.04 Add a CTest target.
- [x] P3.05 Add a public C header.
- [x] P3.06 Keep C++ types out of the public ABI.
- [x] P3.07 Add `tb_image_core_version`.
- [x] P3.08 Add a versioned processing entry point.
- [x] P3.09 Define RGBA8888 input.
- [x] P3.10 Define BGRA8888 input.
- [x] P3.11 Define width limits.
- [x] P3.12 Define height limits.
- [x] P3.13 Define the maximum pixel count.
- [x] P3.14 Define row-stride validation.
- [x] P3.15 Add checked buffer-size multiplication.
- [x] P3.16 Reject invalid buffers.
- [x] P3.17 Reject unsupported pixel formats.
- [x] P3.18 Reject images above the pixel limit.
- [x] P3.19 Define integer mask rectangles.
- [x] P3.20 Clip masks to image bounds.
- [x] P3.21 Ignore empty masks.
- [x] P3.22 Apply opaque masks in place.
- [x] P3.23 Add deterministic grayscale conversion.
- [x] P3.24 Add the current 9-by-8 dHash algorithm.
- [x] P3.25 Add Hamming-distance calculation.
- [x] P3.26 Preserve the current skip threshold.
- [x] P3.27 Support forced captures.
- [x] P3.28 Return the calculated dHash.
- [x] P3.29 Return the skip decision.
- [x] P3.30 Return processing timings.
- [x] P3.31 Use explicit status codes.
- [x] P3.32 Prevent exceptions from crossing the C ABI.
- [x] P3.33 Define explicit buffer ownership.
- [x] P3.34 Document thread-safety requirements.
- [x] P3.35 Add public API documentation.
- [x] P3.36 Add zero-size image tests.
- [x] P3.37 Add invalid-stride tests.
- [x] P3.38 Add integer-overflow tests.
- [x] P3.39 Add mask-clipping tests.
- [x] P3.40 Add overlapping-mask tests.
- [x] P3.41 Add RGBA mask tests.
- [x] P3.42 Add BGRA mask tests.
- [x] P3.43 Add dHash golden tests.
- [x] P3.44 Compare C++ dHash output with Dart output.
- [x] P3.45 Add Hamming-threshold tests.
- [x] P3.46 Add forced-capture tests.
- [x] P3.47 Add deterministic repeated-run tests.
- [x] P3.48 Run AddressSanitizer.
- [x] P3.49 Run UndefinedBehaviorSanitizer.
- [x] P3.50 Add mask-input fuzzing.
- [x] P3.51 Add image-metadata fuzzing.
- [x] P3.52 Add the C++ tests to CI.

### Phase 4 - Build the Android capture runtime

Use API 24 as the initial native capture floor.
Use the Flutter backend on older supported devices.

- [x] P4.01 Create the Android Gradle workspace.
- [x] P4.02 Add the `capture-runtime` Android library.
- [x] P4.03 Set the namespace to `com.tugboat.capture.runtime`.
- [x] P4.04 Set the coordinate to `com.tugboat.sdk:capture-runtime`.
- [x] P4.05 Configure the pinned NDK version.
- [x] P4.06 Connect Gradle to CMake.
- [x] P4.07 Compile the core for `arm64-v8a`.
- [x] P4.08 Compile the core for `armeabi-v7a`.
- [x] P4.09 Compile the core for `x86_64`.
- [x] P4.10 Define the Kotlin public API.
- [x] P4.11 Define the capability result.
- [x] P4.12 Define the capture request.
- [x] P4.13 Define the capture result.
- [x] P4.14 Define bounded failure codes.
- [x] P4.15 Add request identifiers.
- [x] P4.16 Add capture cancellation.
- [x] P4.17 Add runtime disposal.
- [x] P4.18 Add one serialized capture queue.
- [x] P4.19 Add a configurable native timeout.
- [x] P4.20 Accept an active `FlutterView`.
- [x] P4.21 Find the active `FlutterSurfaceView`.
- [x] P4.22 Detect `FlutterTextureView`.
- [x] P4.23 Report unsupported render modes.
- [x] P4.24 Calculate the app-content capture rectangle.
- [x] P4.25 Allocate a target-size mutable bitmap.
- [x] P4.26 Request `PixelCopy`.
- [x] P4.27 Handle each `PixelCopy` result code.
- [x] P4.28 Reject stale completion callbacks.
- [x] P4.29 Lock bitmap pixels through the NDK.
- [x] P4.30 Call the C++ processor through JNI.
- [x] P4.31 Unlock bitmap pixels on each code path.
- [x] P4.32 Skip JPEG encoding after a dHash skip.
- [x] P4.33 Encode JPEG with quality 80.
- [x] P4.34 Calculate SHA-256 over the JPEG.
- [x] P4.35 Return masked JPEG bytes.
- [x] P4.36 Return image dimensions.
- [x] P4.37 Return dHash.
- [x] P4.38 Return the content hash.
- [x] P4.39 Return stage timings.
- [x] P4.40 Return capture coverage.
- [x] P4.41 Clear raw bitmap references after completion.
- [x] P4.42 Do not log pixel data.
- [x] P4.43 Do not log JPEG data.
- [x] P4.44 Build a release AAR.
- [x] P4.45 Add consumer ProGuard rules.
- [x] P4.46 Add native symbol handling.
- [x] P4.47 Publish the AAR to a local Maven repository.
- [x] P4.48 Consume the local artifact from the sample.
- [x] P4.49 Add Android unit tests.
- [x] P4.50 Add Android instrumentation tests.
- [ ] P4.51 Add API 24 tests.
- [ ] P4.52 Add a recent Android API test.
- [ ] P4.53 Add device-rotation tests.
- [ ] P4.54 Add foreground and background tests.
- [ ] P4.55 Add activity-recreation tests.
- [x] P4.56 Add repeated-initialization tests.
- [x] P4.57 Add repeated-disposal tests.

### Phase 5 - Convert the Flutter SDK into a plugin

- [x] P5.01 Add Android plugin metadata to `tugboat`.
- [x] P5.02 Add Apple plugin metadata to `tugboat`.
- [x] P5.03 Add the Android plugin class.
- [x] P5.04 Add an Apple capability stub.
- [x] P5.05 Add Pigeon to the development toolchain.
- [x] P5.06 Define `getCapabilities`.
- [x] P5.07 Define `capture`.
- [x] P5.08 Define `dispose`.
- [x] P5.09 Generate the Dart bridge.
- [x] P5.10 Generate the Kotlin bridge.
- [x] P5.11 Generate the Swift bridge.
- [x] P5.12 Add generated-file verification to CI.
- [x] P5.13 Add `TugboatScreenshotCaptureBackend`.
- [x] P5.14 Add `flutterRepaintBoundary`.
- [x] P5.15 Add `nativeCpuExperimental`.
- [x] P5.16 Make `flutterRepaintBoundary` the default.
- [x] P5.17 Add `screenshotCaptureBackend` to replay configuration.
- [x] P5.18 Document the experimental status.
- [x] P5.19 Keep current capture-scale defaults.
- [x] P5.20 Keep JPEG quality 80.
- [x] P5.21 Keep the current dHash threshold.
- [x] P5.22 Keep the current frame transport schema.
- [x] P5.23 Add a capture backend interface.
- [x] P5.24 Move the current capturer behind that interface.
- [x] P5.25 Add the native CPU backend.
- [x] P5.26 Convert mask rectangles to normalized app coordinates.
- [x] P5.27 Send only mask metadata to native code.
- [x] P5.28 Send the previous dHash.
- [x] P5.29 Send the forced-capture flag.
- [x] P5.30 Receive only masked JPEG data.
- [x] P5.31 Convert native timings into capture diagnostics.
- [x] P5.32 Record the requested backend.
- [x] P5.33 Record the resolved backend.
- [x] P5.34 Record capture coverage.
- [x] P5.35 Record the fallback reason.
- [x] P5.36 Ignore stale native results.
- [x] P5.37 Prevent duplicate frame publication.
- [x] P5.38 Preserve current capture scheduling.
- [x] P5.39 Preserve current session semantics.
- [x] P5.40 Fall back when native capture is unsupported.
- [x] P5.41 Fall back when the render surface is unavailable.
- [x] P5.42 Fall back after a native timeout.
- [x] P5.43 Fall back after `PixelCopy` failure.
- [x] P5.44 Fall back after processing failure.
- [x] P5.45 Do not fall back after cancellation.
- [x] P5.46 Do not publish native and Flutter results together.
- [x] P5.47 Limit retries after a known native failure.
- [x] P5.48 Reset retry state after a lifecycle change.

### Phase 6 - Validate privacy and correctness

- [x] P6.01 Add a test screen with known private regions.
- [x] P6.02 Capture the screen through the native backend.
- [x] P6.03 Decode the returned JPEG in the test.
- [x] P6.04 Verify that each mask is opaque.
- [x] P6.05 Verify mask behavior at each screen edge.
- [ ] P6.06 Verify masks after device rotation.
- [ ] P6.07 Verify masks at each capture scale.
- [ ] P6.08 Verify masks after density changes.
- [ ] P6.09 Verify masks after keyboard changes.
- [ ] P6.10 Verify masks after system-inset changes.
- [x] P6.11 Verify that raw RGBA data does not cross the platform channel.
- [x] P6.12 Verify that raw data does not enter logs.
- [x] P6.13 Verify that failure diagnostics contain no image data.
- [x] P6.14 Verify dHash parity with the Flutter path.
- [x] P6.15 Verify forced capture behavior.
- [x] P6.16 Verify duplicate-frame suppression.
- [x] P6.17 Verify content hashes.
- [x] P6.18 Verify JPEG server compatibility.
- [x] P6.19 Run current replay acceptance tests.
- [x] P6.20 Add a formal privacy sign-off gate.

### Phase 7 - Measure Android performance

- [ ] P7.01 Add stage-level native timing.
- [ ] P7.02 Measure surface-copy time.
- [ ] P7.03 Measure mask time.
- [ ] P7.04 Measure dHash time.
- [ ] P7.05 Measure JPEG time.
- [ ] P7.06 Measure SHA-256 time.
- [ ] P7.07 Measure platform-channel time.
- [ ] P7.08 Measure total capture time.
- [ ] P7.09 Measure peak transient memory.
- [ ] P7.10 Measure process CPU time.
- [ ] P7.11 Measure Flutter UI-isolate time.
- [ ] P7.12 Measure dropped Flutter frames.
- [ ] P7.13 Measure JPEG output size.
- [ ] P7.14 Measure idle battery effect.
- [ ] P7.15 Measure active capture battery effect.
- [ ] P7.16 Benchmark a static screen.
- [ ] P7.17 Benchmark a scrolling screen.
- [ ] P7.18 Benchmark an image-heavy screen.
- [ ] P7.19 Benchmark a screen with many masks.
- [ ] P7.20 Benchmark rapid navigation.
- [ ] P7.21 Benchmark keyboard visibility.
- [ ] P7.22 Benchmark app background transitions.
- [ ] P7.23 Benchmark low-memory conditions.
- [ ] P7.24 Benchmark a mid-range physical device.
- [ ] P7.25 Benchmark a recent flagship device.
- [ ] P7.26 Run at least 30 warm-up captures.
- [ ] P7.27 Run at least 200 measured captures.
- [ ] P7.28 Report p50.
- [ ] P7.29 Report p90.
- [ ] P7.30 Report p95.
- [ ] P7.31 Report the worst observed value.
- [ ] P7.32 Require at least 35% lower p95 processing time.
- [ ] P7.33 Require at least 60% lower Flutter UI-isolate work.
- [ ] P7.34 Require at least 25% lower peak transient memory.
- [ ] P7.35 Require no new dropped-frame regression.
- [ ] P7.36 Require no privacy regression.
- [ ] P7.37 Require acceptable JPEG quality.
- [ ] P7.38 Record each device class that fails a gate.
- [ ] P7.39 Keep the backend experimental if any gate fails.

### Phase 8 - Update documentation and release controls

- [ ] P8.01 Rewrite the root README for the mobile monorepo.
- [ ] P8.02 Update `docs/README.md`.
- [ ] P8.03 Add a repository map.
- [ ] P8.04 Add a common build guide.
- [ ] P8.05 Add an Android development guide.
- [ ] P8.06 Add an Apple development guide.
- [ ] P8.07 Add a Flutter development guide.
- [ ] P8.08 Add the native capture architecture document.
- [ ] P8.09 Add the privacy pipeline document.
- [ ] P8.10 Add the capture coverage document.
- [ ] P8.11 Add the fallback behavior document.
- [ ] P8.12 Add the performance method.
- [ ] P8.13 Add the compatibility table.
- [ ] P8.14 Add the release process.
- [ ] P8.15 Add the React Native roadmap.
- [ ] P8.16 Add the GPU roadmap.
- [ ] P8.17 Update the Flutter integration guide.
- [ ] P8.18 Update the production replay acceptance guide.
- [ ] P8.19 Update the package changelogs.
- [ ] P8.20 Add a repository migration note.
- [ ] P8.21 Make version checks path-aware.
- [ ] P8.22 Remove version-bump requirements for documentation-only changes.
- [ ] P8.23 Remove Flutter version-bump requirements for internal C++ tests.
- [ ] P8.24 Require a runtime version bump for public runtime API changes.
- [ ] P8.25 Require a compatibility-table update for adapter changes.
- [ ] P8.26 Add native artifact build checks.
- [ ] P8.27 Add AAR API surface checks.
- [ ] P8.28 Add Swift API surface checks.
- [ ] P8.29 Add pub package dry-run checks.
- [ ] P8.30 Add license checks.

### Phase 9 - Release the Android experimental path

- [ ] P9.01 Build the final Android AAR.
- [ ] P9.02 Generate artifact checksums.
- [ ] P9.03 Generate release notes.
- [ ] P9.04 Create `capture-runtime-v0.1.0`.
- [ ] P9.05 Publish `com.tugboat.sdk:capture-runtime:0.1.0`.
- [ ] P9.06 Update the Flutter dependency.
- [ ] P9.07 Bump Flutter to `0.9.0`.
- [ ] P9.08 Update `tugboat_dio` if required.
- [ ] P9.09 Run final Flutter package checks.
- [ ] P9.10 Run final Android integration tests.
- [ ] P9.11 Publish the Flutter beta.
- [ ] P9.12 Keep native capture opt-in.
- [ ] P9.13 Monitor native failure rates.
- [ ] P9.14 Monitor automatic fallback rates.
- [ ] P9.15 Review measured data before changing the default.

---

## Apple Follow-up Checklist

- [ ] A1.01 Add the root `Package.swift`.
- [ ] A1.02 Add the root `TugboatCaptureRuntime.podspec`.
- [ ] A1.03 Add the C++ SwiftPM target.
- [ ] A1.04 Add the Swift runtime target.
- [ ] A1.05 Add the Objective-C++ bridge.
- [ ] A1.06 Build the core for the iOS simulator.
- [ ] A1.07 Build the core for iOS devices.
- [ ] A1.08 Capture the Flutter view into a native bitmap context.
- [ ] A1.09 Use `drawHierarchy(in:afterScreenUpdates:)`.
- [ ] A1.10 Report incomplete capture results.
- [ ] A1.11 Apply masks through the C++ core.
- [ ] A1.12 Calculate dHash through the C++ core.
- [ ] A1.13 Encode JPEG through ImageIO.
- [ ] A1.14 Calculate SHA-256.
- [ ] A1.15 Return only masked JPEG data.
- [ ] A1.16 Connect the Swift Pigeon bridge.
- [ ] A1.17 Add CocoaPods integration tests.
- [ ] A1.18 Add SwiftPM integration tests.
- [ ] A1.19 Add Apple privacy tests.
- [ ] A1.20 Add Apple performance tests.
- [ ] A1.21 Publish the Apple `0.1.0` runtime.
- [ ] A1.22 Update the compatibility table.

---

## React Native Follow-up Checklist

- [ ] R1.01 Confirm the minimum React Native version.
- [ ] R1.02 Create the npm workspace.
- [ ] R1.03 Define the TypeScript API.
- [ ] R1.04 Add an Android TurboModule.
- [ ] R1.05 Consume the existing Android AAR.
- [ ] R1.06 Add an Apple TurboModule.
- [ ] R1.07 Consume the existing CocoaPod.
- [ ] R1.08 Keep raw pixels outside JavaScript.
- [ ] R1.09 Return masked JPEG data only.
- [ ] R1.10 Add parity tests against Flutter.
- [ ] R1.11 Add an example application.
- [ ] R1.12 Publish the first npm beta.

---

## GPU Follow-up Checklist

Do not start this work before the CPU benchmark is complete.

- [ ] G1.01 Identify the largest remaining CPU stage.
- [ ] G1.02 Measure native surface-to-CPU readback.
- [ ] G1.03 Define a GPU-buffer capture interface.
- [ ] G1.04 Keep the C ABI stable.
- [ ] G1.05 Prototype Metal processing on Apple platforms.
- [ ] G1.06 Prototype Vulkan processing on Android.
- [ ] G1.07 Compare Vulkan with OpenGL ES compute.
- [ ] G1.08 Apply masks on the GPU.
- [ ] G1.09 Calculate reduced luminance on the GPU.
- [ ] G1.10 Calculate dHash from the reduced result.
- [ ] G1.11 Avoid full-resolution GPU-to-CPU readback.
- [ ] G1.12 Compare CPU and GPU battery use.
- [ ] G1.13 Keep the CPU path as a fallback.
- [ ] G1.14 Ship GPU processing only after a clear device-level gain.

Metal can give a material gain when capture pixels stay in a Metal texture.
Vulkan or OpenGL ES can give a material gain when Android pixels stay in a GPU buffer.
A GPU mask followed by a full CPU readback will give a smaller gain.
The GPU design must therefore solve buffer ownership before shader work.

---

## Suggested Pull Request Sequence

1. Add repository scope, structure, and decision records.
2. Add the C++ core with tests and fuzzing.
3. Add the Android AAR and local Maven publication.
4. Add the Flutter plugin bridge and automatic fallback.
5. Add privacy tests and Android benchmarks.
6. Publish the Android experimental release.
7. Add the Apple runtime and packaging.
8. Add the React Native adapter.
9. Add GPU prototypes only after CPU evidence.

Each pull request must keep existing Flutter behavior working.
Each pull request must have a reversible rollout boundary.

---

## Delivery Estimate

Assume one experienced mobile engineer.
Assume access to Android and Apple test devices.
Assume required registry and signing access is available during release work.

| Work | Estimate |
| --- | ---: |
| Repository restructure and documents | 3 to 5 working days |
| C++ core and tests | 4 to 7 working days |
| Android runtime | 7 to 12 working days |
| Flutter bridge and fallback | 5 to 8 working days |
| Privacy and performance validation | 4 to 7 working days |
| Android beta release work | 2 to 4 working days |
| Total Android CPU beta | 5 to 8 weeks |
| Apple parity after Android | 3 to 5 additional weeks |
| React Native adapter | 2 to 3 additional weeks |
| GPU investigation before implementation | 1 to 2 weeks |

---

## Definition of Done for the Android CPU Beta

- The repository has the agreed mobile monorepo structure.
- The common C++ core builds on Android and Apple toolchains.
- The C++ core passes unit tests, sanitizers, and fuzz tests.
- Android produces a versioned AAR.
- Flutter consumes the AAR through the plugin adapter.
- Native capture stays opt-in.
- Unsupported devices fall back safely.
- Raw pixels never cross into Dart.
- Every encoded frame has privacy masks applied.
- Native and Flutter paths preserve current session semantics.
- Native and Flutter paths cannot publish one request twice.
- Android privacy tests pass.
- Existing Flutter replay tests pass.
- Measured performance passes the initial gates.
- Documentation states all known capture limitations.
- The compatibility table identifies supported artifact versions.
- The release can be disabled without a package rollback.

