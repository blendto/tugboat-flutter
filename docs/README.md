# Tugboat mobile documentation

Documentation for the [Tugboat mobile monorepo](https://github.com/blendto/tugboat-flutter).

These pages describe the products in this repository. The CLI, collector,
Context Graph (Atlas context), and wiki have separate ownership and should be
verified in their own repositories.

## Getting started

- [SDK README](../sdks/flutter/packages/tugboat/README.md) — install, public API, configuration, and limits
- [Collector integration](integration/collector.md) — Flutter WebSocket and HTTP wire behavior
- [Experimental native CPU capture](integration/native-cpu-experimental.md) — opt-in Android PixelCopy backend and fallback rules
- [Common build](integration/common-build.md) — host commands for core, AAR, and Flutter tests
- [Android development](integration/android-development.md)
- [Apple development](integration/apple-development.md)
- [Flutter development](integration/flutter-development.md)
- [Production replay acceptance](integration/production-replay-acceptance.md) — release, Blend canary, and manual production replay gate
- [Blend gesture check, 2026-08-26](integration/blend-gesture-check-2026-08-26.md) — local Android pinch/pan evidence and remaining recorder gaps
- [Gesture PR review, 2026-08-27](integration/gesture-pr-review-2026-08-27.md) — Cursor review, follow-up fixes, tests, and device limits
- [Example exploration brief](exploration/example-brief.md) — goals and constraints for the demo app

## Design

- [Capture and fingerprint architecture](design/capture-and-fingerprint.md) — implemented schema-v6 identity, screenshots, inferred-event evidence, gaps, and next steps

## Architecture

- [Repository map](architecture/repository-map.md) — trees and what each product may own
- [Mobile repository scope](architecture/repository-scope.md) — monorepo products and ownership
- [Native capture architecture](architecture/native-capture.md) — CPU path sketch
- [Native capture contracts](architecture/native-capture-contracts.md) — privacy boundary, coverage, fallback, and diagnostics (authoritative)
- [Capture coverage](architecture/capture-coverage.md) — `engineSurface` limits
- [Fallback behavior](architecture/fallback.md) — retry streak and one-request rule

## Decisions

- [0001 Mobile monorepo](decisions/0001-mobile-monorepo.md)
- [0002 C++ core](decisions/0002-cpp-core.md)
- [0003 Native artifact ownership](decisions/0003-native-artifact-ownership.md)
- [0004 Platform JPEG codecs](decisions/0004-platform-jpeg.md)
- [0005 Opt-in Flutter rollout](decisions/0005-opt-in-flutter-rollout.md)
- [0006 Mask coordinates](decisions/0006-mask-coordinates.md)
- [0007 GPU processing deferred](decisions/0007-gpu-deferred.md)
- [0008 Independent versioning](decisions/0008-independent-versioning.md)

## Privacy

- [Privacy pipeline](privacy/pipeline.md) — mask-before-encode ownership
- [Native CPU sign-off](privacy/native-cpu-signoff.md) — host vs device gates

## Performance

- [CPU capture baseline](performance/cpu-capture-baseline.md) — comparison contract, toolchain pins, JPEG envelope
- [CPU capture method](performance/cpu-capture-method.md) — device-lab protocol
- [CPU capture results](performance/cpu-capture-results.md) — empty until a physical device run

## Releases

- [Compatibility table](releases/compatibility.md) — adapter ↔ runtime versions
- [Release process](releases/process.md)
- [Repository migration](releases/repository-migration.md)
- [Third-party notices](releases/third-party-notices.md)

## Roadmap

- [React Native](roadmap/react-native.md)
- [GPU processing](roadmap/gpu.md)

## Current compatibility

- package version: `0.8.12`;
- native runtime: `com.tugboat.sdk:capture-runtime` `0.1.0` (local Maven, experimental);
- release line: `0.8.x` (`0.8.12` is a patch after `0.8.11`);
- planned first native-capable adapter: Flutter `0.9.0` after privacy and performance gates;
- session JSON schema: `10`;
- fingerprint schema: `6`;
- minimum Dart SDK: `3.9.2`;
- minimum Flutter SDK: `3.35.0`.

Start with the SDK README for integration. Use the contracts document when
changing identity, capture cadence, privacy boundaries, activation, or sink
behavior; these changes can invalidate downstream evidence even when the Dart
API remains source-compatible.
