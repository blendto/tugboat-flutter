# Tugboat Flutter SDK documentation

Documentation for the [Tugboat Flutter SDK](https://github.com/blendto/tugboat-flutter).

These pages describe the Flutter package in this repository. The CLI,
collector, Context Graph (Atlas context), and wiki have separate ownership and
should be verified in their own repositories.

## Getting started

- [SDK README](../packages/tugboat/README.md) — install, public API, configuration, and limits
- [Collector integration](integration/collector.md) — Flutter WebSocket and HTTP wire behavior
- [Production replay acceptance](integration/production-replay-acceptance.md) — release, Blend canary, and manual production replay gate
- [Blend gesture check, 2026-08-26](integration/blend-gesture-check-2026-08-26.md) — local Android pinch/pan evidence and remaining recorder gaps
- [Gesture PR review, 2026-08-27](integration/gesture-pr-review-2026-08-27.md) — Cursor review, follow-up fixes, tests, and device limits
- [Example exploration brief](exploration/example-brief.md) — goals and constraints for the demo app

## Design

- [Capture and fingerprint architecture](design/capture-and-fingerprint.md) — implemented schema-v6 identity, screenshots, inferred-event evidence, gaps, and next steps

## Repository layout

| Path | Description |
|------|-------------|
| `packages/tugboat` | Flutter SDK (`package:tugboat`), published on pub.dev |
| `packages/tugboat_dio` | Optional Dio adapter, published on pub.dev |
| `packages/tugboat/example` | Demo app and integration fixture (not a separate pub.dev package) |
| `docs/design` | Current architecture and forward-looking SDK decisions |
| `docs/integration` | Host-app and transport integration contracts |

## Current compatibility

- package version: `0.8.12`, published on
  [pub.dev/packages/tugboat](https://pub.dev/packages/tugboat) and
  [pub.dev/packages/tugboat_dio](https://pub.dev/packages/tugboat_dio);
- release line: `0.8.x` (`0.8.12` is a patch after `0.8.11`);
- session JSON schema: `10`;
- fingerprint schema: `6`;
- minimum Dart SDK: `3.9.2`;
- minimum Flutter SDK: `3.35.0`.

Start with the SDK README for integration. Use the architecture document when
changing identity, capture cadence, privacy boundaries, activation, or sink
behavior; these changes can invalidate downstream evidence even when the Dart
API remains source-compatible.
