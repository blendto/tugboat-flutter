# Tugboat Flutter SDK documentation

Documentation for the [Tugboat Flutter SDK](https://github.com/blendto/tugboat-flutter).

These pages describe the Flutter package in this repository. The CLI,
collector, Context Graph (Atlas context), and wiki have separate ownership and
should be verified in their own repositories.

## Getting started

- [SDK README](../sdks/flutter/packages/tugboat/README.md) — install, public API, configuration, and limits
- [Collector integration](integration/collector.md) — Flutter WebSocket and HTTP wire behavior
- [Production replay acceptance](integration/production-replay-acceptance.md) — release, Blend canary, and manual production replay gate
- [Blend gesture check, 2026-08-26](integration/blend-gesture-check-2026-08-26.md) — local Android pinch/pan evidence and remaining recorder gaps
- [Gesture PR review, 2026-08-27](integration/gesture-pr-review-2026-08-27.md) — Cursor review, follow-up fixes, tests, and device limits
- [Example exploration brief](exploration/example-brief.md) — goals and constraints for the demo app

## Design

- [Capture and fingerprint architecture](design/capture-and-fingerprint.md) — implemented schema-v6 identity, screenshots, inferred-event evidence, gaps, and next steps

## Architecture

- [Mobile repository scope](architecture/repository-scope.md) — monorepo products and what each tree may own
- [Native capture contracts](architecture/native-capture-contracts.md) — privacy boundary, coverage, fallback, and diagnostics

## Decisions

- [0001 Mobile monorepo](decisions/0001-mobile-monorepo.md)
- [0002 C++ core](decisions/0002-cpp-core.md)
- [0003 Native artifact ownership](decisions/0003-native-artifact-ownership.md)
- [0004 Platform JPEG codecs](decisions/0004-platform-jpeg.md)
- [0005 Opt-in Flutter rollout](decisions/0005-opt-in-flutter-rollout.md)
- [0006 Mask coordinates](decisions/0006-mask-coordinates.md)
- [0007 GPU processing deferred](decisions/0007-gpu-deferred.md)
- [0008 Independent versioning](decisions/0008-independent-versioning.md)

## Performance

- [CPU capture baseline](performance/cpu-capture-baseline.md) — screenshot-capture comparison contract, toolchain pins, and JPEG size envelope

## Repository layout

| Path | Description |
|------|-------------|
| `sdks/flutter/packages/tugboat` | Flutter SDK (`package:tugboat`) |
| `sdks/flutter/packages/tugboat/example` | Demo app and integration fixture (not published) |
| `sdks/flutter/packages/tugboat_dio` | Dio network-evidence adapter |
| `core/image-processing` | Portable C++ CPU image core (Phase 3) |
| `platforms/android` | Capture runtime AAR (Phase 4) |
| `platforms/apple` | Capture runtime (milestone 2) |
| `sdks/react-native` | Future adapter placeholder |
| `docs/design` | Current architecture and forward-looking SDK decisions |
| `docs/architecture` | Native capture scope and contracts |
| `docs/decisions` | Accepted architecture decision records |
| `docs/integration` | Host-app and transport integration contracts |
| `docs/privacy` | Native capture privacy contract pointers |
| `docs/releases` | Third-party notice process |
| `docs/roadmap` | Deferred GPU and React Native work |

## Current compatibility

- package version: `0.8.12`;
- release line: `0.8.x` (`0.8.12` is a patch after `0.8.11`);
- session JSON schema: `10`;
- fingerprint schema: `6`;
- minimum Dart SDK: `3.9.2`;
- minimum Flutter SDK: `3.35.0`.

Start with the SDK README for integration. Use the architecture document when
changing identity, capture cadence, privacy boundaries, activation, or sink
behavior; these changes can invalidate downstream evidence even when the Dart
API remains source-compatible.
