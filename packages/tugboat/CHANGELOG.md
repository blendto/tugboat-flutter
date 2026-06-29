## Unreleased

### Removed

- **`control_inventory` SDK events** — the SDK no longer emits per-screen control
  inventories over the exploration WebSocket. Possible actions should be derived
  from screenshots (for example via a VLM) instead of SDK-side widget-tree scans.
  State anchors still include `actionableSummary` role counts for fingerprinting
  only; that field is not a substitute for control discovery.

### Changed

- **`actionableSummary` deduplication** — count only leaf canonical controls (one per
  `FilledButton`/`TextButton`, not nested ink-well chrome). Fixes over-counting in modal,
  visibility, and rebuild fingerprint tests.

## 0.1.0

- Initial Tugboat Flutter SDK with screenshot evidence, interaction anchors,
  route transitions, privacy masking, and exploration transport.
