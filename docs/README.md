# Tugboat Flutter SDK documentation

Documentation for the [Tugboat Flutter SDK](https://github.com/blendto/tugboat-flutter).

These pages describe the Flutter package in this repository. The CLI,
collector, Context Graph (Atlas context), and wiki have separate ownership and
should be verified in their own repositories.

## Getting started

- [SDK README](../packages/tugboat/README.md) — install, public API, configuration, and limits
- [Collector integration](integration/collector.md) — Flutter WebSocket and HTTP wire behavior
- [Production replay acceptance](integration/production-replay-acceptance.md) — release, Blend canary, and manual production replay gate
- [Example exploration brief](exploration/example-brief.md) — goals and constraints for the demo app

## Design

- [Capture and fingerprint architecture](design/capture-and-fingerprint.md) — implemented schema-v6 identity, screenshots, inferred-event evidence, gaps, and next steps

## Repository layout

| Path | Description |
|------|-------------|
| `packages/tugboat` | Flutter SDK (`package:tugboat`) |
| `packages/tugboat/example` | Demo app and integration fixture (not published) |
| `docs/design` | Current architecture and forward-looking SDK decisions |
| `docs/integration` | Host-app and transport integration contracts |

## Current compatibility

- package version: `0.9.0`;
- release line: `0.9.x`, following `0.8.0`;
- session JSON schema: `10`;
- fingerprint schema: `6`;
- minimum Dart SDK: `3.9.2`;
- minimum Flutter SDK: `3.35.0`.

Start with the SDK README for integration. Use the architecture document when
changing identity, capture cadence, privacy boundaries, activation, or sink
behavior; these changes can invalidate downstream evidence even when the Dart
API remains source-compatible.
