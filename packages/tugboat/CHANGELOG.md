## 0.4.11

### Added

- **Navigator and route-instance ownership** — every observed Navigator gets a
  session-local opaque `navigatorId`; every pushed route gets a
  `routeInstanceId`. Stacked anonymous modals stay distinguishable.
  Install nested observers with `TugboatReplay.createNavigatorObserver()`.
- **Navigation origin contract** — `route_change` events carry
  `navigationOrigin` (`interaction` | `automatic_or_unknown`) and optional
  `causeEventId`. Only observer-time single-use pending-interaction claims can
  bind a tap; timer/auth redirects never fabricate causality.
- **Versioned `captureCoordinate`** — taps retain legacy global `x`/`y` and add
  a boundary-local / normalized / raster transform bound to the before-frame.
  Outside-boundary and generation-mismatch cases emit an unavailable reason
  instead of clamping.
- **Replay coherence characterization harness** — deterministic, advanceable
  scheduler/capture test seams (`debugNow`, `debugDelay`, `debugExecuteCapture`,
  `debugSeedFrame`) plus reusable helpers that reproduce known navigation/frame
  races without wall-clock sleeps. Tracks milestone issue #5.
- **Pathless-tap snap** (2026-07-04) — when hit-testing resolves a tap to a target
  with a role but no canonical path (opaque `Texture`, decorated boxes outside the
  token map), the tap is re-anchored to the smallest *interactive* scene-inventory
  element containing the tap point, so its fingerprint always joins the inventory.
  Guards: only interactive-tier entries qualify, and the candidate's area must be
  comparable to the render surface the pointer actually hit (occluded controls under
  opaque overlays are never falsely attributed). Snapped anchors keep
  `tagFingerprint`, drop stale `fingerprintParts`, and are marked
  `fingerprintConfidence: 'low'`.
- **Structurally addressable anchor preference** — `_targetAtWithTokenMap` prefers
  hit-test candidates that have both a role and a non-empty canonical path over
  role-only candidates, fixing joins for paywall dismiss buttons and overlay chrome.
- **`scene_inventory` events** — during exploration, emit a deduped structural inventory
  of actionable elements and `Image` widgets per settled screen state (fingerprints, bounds,
  roles). Fingerprints match tap `targetAnchor` resolution for the same element.
- **Fingerprint aliases** — inventory entries store alternate structural fingerprints for the
  same logical control (e.g. wrapper layers like `InkWell` vs `GestureDetector`). Tap
  resolution can match via primary fingerprint or alias.
- **Tap injection** — when a tap resolves to a fingerprint not in the enumerated inventory,
  the tap target is appended to the inventory so exploration joins are guaranteed.
- **Route epoch guard** — stale delayed route callbacks no longer clobber `_currentRoute` or
  emit incorrect `route_change` events during rapid navigation.
- **Item-normalized state signatures** — `[item:hash]` segments in actionable paths are
  normalized to `[item]` for signature hashing only, so list scroll does not fork inventories
  for the same logical screen.
- **Capture attribution diagnostics** — SDK emits `action_window_set`, `action_window_cleared`,
  `tap_outside_tree`, and `pointer_cancel` events during CLI exploration runs.
- **`recordPointerCancel`** — wired from `InputCapture` and the root `Listener` so cancelled
  gestures are visible in the event stream.

### Changed

- **Tap/navigation causality fence** — tap settlement joins a route-capture
  barrier only when that route explicitly claimed the same tap event.
  Automatic redirects that overlap settlement, including successors of a
  tap-caused route, remain independent and cannot donate their frame or route
  event ID to the tap.
- **Frame-owned coordinate geometry** — frame provenance now retains the
  capture boundary's logical rect and transform generation. Resizes, rotations,
  and inset changes invalidate stale before-frame attachment and emit
  `generation_mismatch` instead of projecting a current tap onto older pixels.
- **Route-capture barrier** — tap settlement now joins the matching route epoch
  instead of reusing the previous route's latest frame. Supersession,
  lifecycle cancellation, capture failure, and bounded timeout outcomes
  complete deterministically without allowing late readbacks to publish.
- **Production viewport semantics stay local** — production sessions can still
  build viewport semantic maps for tap resolution, but `viewport_semantic_map`
  and `scroll_semantic_snapshot` events are emitted only during exploration so
  UI text from semantic nodes is not uploaded in lean production captures.
- **`ExplorationCaptureSink.recordFrame`** — forwards frame metadata and PNG bytes over the
  exploration WebSocket instead of dropping them. The CLI persists these under `frames/` when
  Flutter capture produces them (local capture may still be suppressed after the socket connects
  for performance; see `collector-integration.md`).
- **`actionableSummary` deduplication** — count only leaf canonical controls (one per
  `FilledButton`/`TextButton`, not nested ink-well chrome). Fixes over-counting in modal,
  visibility, and rebuild fingerprint tests.
- **`nonAssetImagesOnly` contract narrowed to what is actually classified** — README and
  enum docs now state the mode masks non-asset `Image` widgets (such as `Image.network`,
  `Image.file`, and `Image.memory`) plus sensitive inputs. Custom-painted or decorated
  image surfaces (e.g. `ExtendedImage`, `DecorationImage`, `CustomPaint`) are not
  classified by this mode and must be wrapped in `TugboatSensitive` when private.
  Image-provenance detection is isolated in a single helper (`_isNonAssetImageWidget`)
  as the one place to extend classification later. Behavior is unchanged; regression
  tests cover asset-visible, memory-masked, and Sensitive-always-masked cases.
- **Typed route transitions in the controller** — `route()` converts raw navigator
  callback strings into an internal typed model (`_RouteNavigationKind`,
  `_RouteTransition`) and resolves visible navigation in one place
  (`_resolveVisibleRouteChange`), replacing string-driven branching and collapsing the
  two duplicate `route_remove` stack-cleanup checks into a single normalized decision.
  The `route_change` wire format (`data.fromRoute` / `data.route` / `data.navigation`)
  and epoch/capture semantics are unchanged; stack-cleanup removals from
  `pushNamedAndRemoveUntil` still never bump the route epoch or cancel the pending
  destination capture (now covered by a dedicated regression test).

### Removed

- **`control_inventory` SDK events** — the SDK no longer emits per-screen control
  inventories over the exploration WebSocket. Possible actions should be derived
  from screenshots (for example via a VLM) instead of SDK-side widget-tree scans.
  State anchors still include `actionableSummary` role counts for fingerprinting
  only; that field is not a substitute for control discovery.

## 0.1.0

- Initial Tugboat Flutter SDK with screenshot evidence, interaction anchors,
  route transitions, privacy masking, and exploration transport.
