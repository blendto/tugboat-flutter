# Tugboat mobile documentation

Public contracts and integrator docs for this repository. The CLI, collector,
and Context Graph have separate ownership.

**What belongs here:** [publishing.md](publishing.md). Working notes (plans, lab
gates, canaries) are not listed below.

## Getting started

- [SDK README](../sdks/flutter/packages/tugboat/README.md) — install, public API, configuration, and limits
- [Collector integration](integration/collector.md) — Flutter WebSocket and HTTP wire behavior
- [Experimental native CPU capture](integration/native-cpu-experimental.md) — opt-in native CPU backend and fallback rules
- [Common build](integration/common-build.md) — host commands for core, AAR, and Flutter tests
- [Android development](integration/android-development.md)
- [Apple development](integration/apple-development.md)
- [Flutter development](integration/flutter-development.md)
- [Example exploration brief](exploration/example-brief.md) — demo app goals and constraints

## Design

- [Capture and fingerprint architecture](design/capture-and-fingerprint.md) — schema-v6 identity, screenshots, inferred-event evidence

## Architecture

- [Repository map](architecture/repository-map.md)
- [Mobile repository scope](architecture/repository-scope.md)
- [Native capture architecture](architecture/native-capture.md)
- [Native capture contracts](architecture/native-capture-contracts.md) — privacy boundary, coverage, fallback, diagnostics (authoritative)
- [Capture coverage](architecture/capture-coverage.md) — `engineSurface` limits
- [Fallback behavior](architecture/fallback.md)

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

## Performance

- [CPU capture baseline](performance/cpu-capture-baseline.md) — comparison contract and JPEG envelope, not a device-lab result

## Releases

- [Compatibility table](releases/compatibility.md)
- [Release process](releases/process.md)
- [Repository migration](releases/repository-migration.md)
- [Third-party notices](releases/third-party-notices.md)

## Current compatibility

- package version: `0.8.14` (`0.8.x` patch; Android plugin uses Maven Central
  `capture-runtime` `0.1.0`);
- native runtime: `capture-runtime` `0.1.0` on Maven Central;
- planned first native-default adapter: Flutter `0.9.0` after privacy and performance gates;
- session JSON schema: `10`;
- fingerprint schema: `6`;
- minimum Dart SDK: `3.9.2`;
- minimum Flutter SDK: `3.35.0`.

Start with the SDK README for integration. Use the contracts document when
changing identity, capture cadence, privacy boundaries, activation, or sink
behavior; these changes can invalidate downstream evidence even when the Dart
API remains source-compatible.
