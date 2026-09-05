# Downstream systems

Status: current · Last verified: 2026-09-05

This repo produces evidence; these consumers own everything after it leaves
the device. Their internals are deliberately out of scope here — this repo's
docs describe only the contracts on the boundary.

**Collector** — receives session evidence from the sink hub (HTTP, and a
WebSocket path for exploration runs). Wire behavior:
`docs/integration/collector.md`.

**Context Graph** — the service that ingests runs/sessions, builds Session
Atlas (screens, control labels, flows), and enriches production sessions.
Consumes this repo's fingerprints, routes, and masked screenshots. Its
identity matching works within one `fingerprintSchemaVersion`; cross-build
remapping is its job, not this repo's.

**Session Atlas** — Context Graph's knowledge base built from exploration
runs recorded with this SDK. Focused, complete exploration runs produce
better Atlas corpora (routes, stable fingerprints, visible bounds, clear
outcomes) — the SDK's capture quality directly gates Atlas quality.
