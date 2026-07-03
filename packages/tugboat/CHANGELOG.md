## Unreleased

### Added

- **`scene_inventory` events** — during exploration, emit a deduped structural inventory
  of actionable elements and `Image` widgets per settled screen state (fingerprints, bounds,
  roles). Fingerprints match tap `targetAnchor` resolution for the same element.
- **Capture attribution diagnostics** — SDK emits `action_window_set`, `action_window_cleared`,
  `tap_outside_tree`, and `pointer_cancel` events during CLI exploration runs.
- **`recordPointerCancel`** — wired from `InputCapture` and the root `Listener` so cancelled
  gestures are visible in the event stream.

### Changed

- **`ExplorationCaptureSink.recordFrame`** — forwards frame metadata and PNG bytes over the
  exploration WebSocket instead of dropping them. The CLI persists these under `frames/` when
  Flutter capture produces them (local capture may still be suppressed after the socket connects
  for performance; see `collector-integration.md`).

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
