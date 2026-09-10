# Downstream systems

Status: current · Last verified: 2026-09-05

This repo produces evidence; these consumers own everything after it leaves
the device. Their internals are deliberately out of scope here — this repo's
docs describe only the contracts on the boundary.

**Collector** — standalone HTTP sink that receives session evidence from the
sink hub. Wire behavior: `docs/integration/collector.md`. Local exploration
runs use a separate WebSocket destination, not the collector.

**Context Graph** — downstream consumer of this repo's evidence (fingerprints,
routes, masked screenshots). Ingestion, enrichment, and identity remapping
across builds are its responsibility, not this repo's. See
`docs/design/capture-and-fingerprint.md` for the boundary contract.

**Session Atlas** — downstream knowledge base built from exploration runs;
this repo does not specify Atlas internals or matching behavior.
