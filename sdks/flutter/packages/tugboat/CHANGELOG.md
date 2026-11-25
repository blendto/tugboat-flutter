## 0.12.3

### Changed

- Session and event IDs are now globally unique: `session-<UUIDv4>` and
  `event-<UUIDv4>`, minted on the device. Previously they were
  `session-<epoch microseconds>` and `event-<counter>`, so two devices (or two
  controllers) could produce the same ID. This applies to every controller
  event, the interaction, route and scroll IDs that double as event IDs, and
  the sink's `capture_diagnostic` events.
- Frame uploads carry a UTC `frameMetadata.triggeredAt` (session start plus the
  frame's `atMs`), so the collector can recover capture time for a late
  upload now that the session ID no longer encodes a start time.

### Compatibility

- Consumers must treat these IDs as opaque and preserve either shape: older
  SDKs still send the old formats. Use `startedAt`, `atMs` and `triggeredAt`
  for timing. `frame-<n>` IDs are unchanged (unique within a session), and
  capture IDs never enter a fingerprint. No fingerprint, route key or
  inventory hash change.

## 0.12.2

- Reworked the replay quick start, accessibility and navigation examples, and Dart API guide.

## 0.12.0

### Removed

- Loading-state detection on exploration scene inventories. It guessed from
  widget types and names, which is not reliable enough to build on: any
  widget whose name contains `Placeholder` (a `PlaceholderSettingsPage`)
  marked its whole subtree as loading, a custom loader (Lottie, SpinKit, an
  app's own skeleton) was invisible unless the host wrapped it, and a spinner
  that disappeared did not by itself trigger a new inventory. Gone with it:
  - the `loading` object on scene inventories (`progressIndicators`,
    `placeholders`, `busyControls`);
  - the per-element `placeholder: true` flag;
  - the exported `TugboatLoading` marker widget. **Breaking:** remove any
    `TugboatLoading(...)` wrapper and keep its `child`. The marker was
    transparent, so removing it changes no fingerprint, route key or
    inventory hash.

  `loading` was already optional (omitted on production captures and when the
  walk failed), so a consumer that reads it must already handle its absence.
  No fingerprint, route key, inventory hash or `fingerprintSchemaVersion`
  changes: none of these fields were ever hash input.

### Changed

- The settled re-sample no longer treats a control flipping between loaded
  and placeholder as new. A re-sample is still emitted when it adds a control
  or content path not yet sent in the route visit, or flips a sent control
  between enabled and disabled; the quiet-screen timing is unchanged. A
  skeleton replaced by content that adds new paths is still caught; one that
  only restyles the same controls in place is not.

## 0.11.6

### Added

- Opt-in `TugboatReplayConfig.capturePressDuration`, default off: tap
  interactions carry `payload.pressDurationMs`, the milliseconds from
  pointer-down to pointer-up (BLE-567). Until now a 1.5 s press reached the
  collector as a plain `tap` with nothing to tell it from a quick one. The
  gesture stays `tap`; there is no `long_press` gesture name, because
  collectors that do not know a gesture reject the whole batch. Swipes,
  scrolls, pan and zoom never carry it. Turn it on once the collector that
  validates `pressDurationMs` as a tap fact is deployed. With the flag off,
  events are unchanged.

## 0.11.5

### Changed

- Identity contract change: `session_start` now sends a real installation id
  as `appInfo.installationId` (BLE-566). Before, `fromPlatform` filled that
  field from `device_info_plus`, which on Android is `Build.ID`, the OS build
  label shared by every device on that build, and on iOS is
  `identifierForVendor`; the collector mapper then dropped the field, so no
  session ever carried it. The SDK now mints a random UUID on first launch and
  keeps it in its own file (`tugboat/installation_id` in the app support
  directory, not the host's shared preferences), so it lasts across launches
  and updates and is new after a reinstall or a data clear. On iOS the first
  value is `identifierForVendor` instead of a random UUID, so existing iOS
  installs keep the value they already reported as `device.id`. A host can
  pass its own id with the new optional `installationId` argument on
  `TugboatCollectorHost.fromPlatform` and `loadAppInfo`; a non-empty host id
  wins. `TugboatCollectorHost.installationId()` returns the SDK's id.
  Existing data: sessions before 0.11.5 have no `installationId`, so nothing
  already stored changes meaning. `device.id` is unchanged (still `Build.ID`
  on Android, `identifierForVendor` on iOS), so consumers that grouped by it
  keep working; group installs by `appInfo.installationId` from now on. On
  Android each install gets a new id the first time it runs 0.11.5; on iOS it
  matches the earlier `device.id`. A host that builds
  `TugboatCollectorConfig` by hand now has its `appInfo.installationId` sent
  as given, where it was dropped before, so do not put `device_info_plus`
  ids such as Android's `Build.ID` there.
  Known caveat: the id file is in the app's support directory, which platform
  backups include, so restoring a backup onto a second device gives both
  devices the same id. A host that needs to avoid that passes its own
  `installationId` or excludes `tugboat/installation_id` from backup.
  Persistence is hardened: a failed first write is retried on later reads
  instead of being cached, and stores racing on first launch (isolates,
  processes) adopt the id that reached disk.

### Added

- Dependency on `path_provider` (^2.1.4) to locate the app support directory.

- The minimum stays Flutter 3.35.0 and Dart 3.9.2. Newer `path_provider`
  platform packages need Flutter 3.38.4, but pub resolves older ones on
  older SDKs, so a Flutter 3.35 host builds. The workspace lockfile is
  resolved on Flutter 3.35.7 so it works on the minimum toolchain.

## 0.11.4

### Fixed

- A tap on a button's padding whose handler navigates (a close button that
  pops the route, say) records the same target as a tap on the button's glyph
  again (BLE-440). Since 0.10.11 such a tap is resolved from the hit path kept
  at pointer-down. The padding hit lands first on the button's own gesture
  `Listener`, which is skipped as capture chrome, so the walk climbed from
  the `MouseRegion` above the `GestureDetector` and recorded the `InkWell`
  (`…/OutlinedButton#0/InkWell#0`). On a tap that stays on the screen, alias
  normalisation folds that back to the inventory primary, but after a
  navigating tap it cannot run, so one control was recorded under two
  fingerprints and the `InkWell` one matched nothing in scene inventories.
  On the pointer-down path only, a chrome hit entry whose climb reaches an
  actionable, addressable control now resolves to that control
  (`…/InkWell#0/GestureDetector#0`), the layer a glyph tap and the scene
  inventory report. Taps resolved from the pointer-up hit test, and controls
  hidden under `ExcludeSemantics`, resolve exactly as before. Identity change:
  only navigating taps on a button's padding move, back from the `InkWell`
  fingerprint to the `GestureDetector` one that 0.10.10 and earlier recorded
  and that scene inventories list (the `InkWell` fingerprint is already in
  that entry's `aliases`). `fingerprintSchemaVersion` is unchanged.

## 0.11.3

### Changed

- Lockstep release with `tugboat_dio` 0.11.3, which adds the opt-in
  `errorBodyDenyUrls` and `errorBodyUrls` controls over which request URLs may
  keep an HTTP error response body. The `tugboat` package has no runtime
  behavior change, and error bodies are still retained by default.

## 0.11.2

### Changed

- `TugboatReplay.health.sinks.pending` and `dropped` now report what the
  collector sink really holds and discards. They always read 0 before: the
  sink mailbox delivers synchronously and never queued anything, so the
  collector sink's own queues were invisible. `pending` counts events and
  frames that are queued, waiting for a retry, or in a request that has not
  finished. `dropped` counts, over the life of the sink, events and frames
  discarded at the pending-event cap (`maxPendingEvents`), the retry-queue cap
  (`maxPendingBatches`) and the frame caps (`maxPendingFrames`,
  `maxPendingFrameBytes`), and those still queued when a new session starts
  or the sink is disposed. Items already in a request then stay in `pending`
  until it finishes and count as dropped only if the collector leaves them to
  retry, so a delivered request is never counted. All three cover the whole
  process rather than one activation: each activation builds a new sink, so
  `accepted` and `dropped` are now running totals across
  `activate` / `deactivate` cycles, and a deactivated session's sink keeps
  counting in `pending` and `dropped` until its last request finishes. Before,
  health read only the current activation's sink and reset to 0, hiding what
  the previous one discarded. This changes what health reports (diagnostics
  only); the collector wire format and delivery behavior are unchanged.

### Fixed

- Durations in collector lifecycle posts no longer depend on the wall clock.
  `atMs` on `session_end`, on `user_changed` / `traits_updated` /
  `session_identify`, and on `capture_diagnostic` events the sink records was
  a `DateTime.now()` difference, so an NTP step or a clock change mid-session
  made it wrong or negative. It now comes from a monotonic stopwatch started
  with the session, offset once by the time between the session's
  `startedAt` and the sink starting, so it shares the time base of event
  `atMs` and `session_end` is never before the session's last event. The
  later of two coalesced identity changes is chosen by that stopwatch.
  `triggeredAt` is still a wall-clock timestamp, so after a clock change it
  can differ from `session start + atMs`. The wire shape of every event is
  unchanged.

## 0.11.1

### Fixed

- The last screenshot of a session is uploaded before `session_end`. A frame
  recorded while a collector flush was running was not part of that flush,
  and `endSession()` only waited for it, so the frame was never sent
  (BLE-549). A `flush()` call during a running pass now queues one follow-up
  pass that runs after it.
- One hung request no longer blocks every upload (BLE-551). `/v1/sessions` and
  `/v1/events/batch` posts time out after 15 seconds like frame uploads, and a
  timeout is retried. A flush drains only the events queued when it reached
  them and uploads newly captured frames between event batches. When an event
  post fails, the flush moves the rest of its events to the retry queue
  unsent instead of waiting out a timeout for each batch, and while the
  oldest retry batch gets no response at all, fresh events join it there
  rather than being posted.
- Stalled uploads no longer cut long holes in replays (BLE-550).
  `maxPendingFrames` defaults to 400 (was 20) and the new
  `maxPendingFrameBytes` (default 8 MiB) bounds held frame bytes. Eviction
  drops the oldest frame no event references first and keeps the newest
  frame. A flush takes one 20-frame batch from the queue at a time, so at
  most that batch is held beyond the bounds, and a timed-out request is
  aborted rather than left holding its frames.
- A session lifecycle post the collector rejects (4xx), such as
  `user_changed`, is dropped instead of being retried on every flush, where
  it held every later lifecycle post, `session_end` included. A rejected
  `session_start` is still retried, because uploads wait for its session id.
- A session started while the previous one was still ending no longer
  receives that session's `session_end`, and keeps its periodic flush. The
  ending session stops at the switch.

### Changed

- Requires `package:http` 1.5.0 or later (was 1.4.0), for aborting a
  collector request when it times out.

### Added

- `collector_frame_upload` drop diagnostics also report the final count before
  `session_end`, and carry `droppedReferencedFrameCount`.
- `collector_request` diagnostics report the first failed session or event post
  per outage (status code, or `error: timeout` / `transport`) and its recovery
  (BLE-552).
- `collector_flush` diagnostics report the first flush pass per outage slower
  than 10 seconds, with the step it spent the most time in.

## 0.11.0

### Added

- Every scene inventory carries `trigger` (`initial`, `resume`, `route`,
  `tap`, `scroll`, `gesture`, `settled`, `manual`). A scroll-end capture is
  `scroll` and a swipe, pan or zoom capture is `gesture`. It is not part of
  any hash or the de-duplication key.
- In exploration mode, the inventory is re-sampled by default once the page
  settles after a moment: a tap or gesture (a control the interaction
  reveals, such as a Continue shown once a row is picked), a scroll end, or a
  load with no interaction (a `FutureBuilder`, a skeleton or a full-screen
  spinner replaced by content). A re-sample is emitted only when it is new to
  the route visit: a control or content path not yet sent (list positions
  collapsed, except a `PageView`'s page position), or a sent one flipped
  between enabled and disabled or placeholder and loaded. It is labelled
  `tap`, `gesture` or `scroll` after that moment, else `settled`. An idle
  page costs no timer; a page that keeps animating is checked after 2 s of
  frames, then ever more rarely; a looping animation or blinking cursor
  never emits. At most 50 re-samples per route visit, as a backstop. A
  `PageView`'s page position is kept apart, so each onboarding page is new;
  the cost is that an auto-advancing carousel sends one re-sample per page
  it has not shown in the visit. Turn it off with
  `resampleSettledInventory: false`; production captures run none of it.
- In exploration mode, every scene inventory carries `loading`
  (`progressIndicators`, `placeholders`, `busyControls`) and each element
  beneath a skeleton, shimmer, `Redacted` or `Placeholder` ancestor, or a new
  `TugboatLoading` marker, carries `placeholder: true`. The signal is
  structural and text-free, and no fingerprint, route key or inventory hash
  changes. Placeholder names are a heuristic; see the capture design doc for
  its known false positives. `TugboatLoading(enabled: false)` switches the
  marker off: the nearest `TugboatLoading` above an element decides, so a
  disabled one also overrides a skeleton ancestor that stays mounted after
  loading (`Skeletonizer(enabled: loading, child: TugboatLoading(enabled:
  loading, child: content))`). Toggling `enabled` changes no fingerprint.
- In exploration mode (scene inventory emission on), every `tap` interaction
  that carries a `targetFingerprint` now also carries `fingerprintSource` and
  `routeKey`, next to the existing `fingerprintConfidence`. Production taps keep
  their lean envelope and do not carry these. `fingerprintSource` is how the
  fingerprint was resolved: `pointerDown`, `snap` (a pathless hit re-anchored to the inventory control
  under the tap) or `inventory`. `routeKey` is the resolved route key the
  fingerprint was hashed under, so a tap on a dialog or an unnamed page joins
  its inventory exactly. `route` is unchanged and still the raw route.
- Every scene inventory carries `surface`: `{ "kind": "page" | "sheet" |
  "dialog" | "popup" | "menu", "widgetClass": "..." }`, and exploration taps
  carry the surface of their inventory. `kind` comes from the current route's
  type; `widgetClass` is the first app-level widget class below a sheet,
  dialog or popup's overlay host, as in the canonical paths, and is omitted
  when it cannot be told (private or inline builders, pages, menus, shells). It
  is found when the app wraps the `Navigator` in a widget of its own in the
  `MaterialApp` builder (a provider or overlay host), and while a toolbar or a
  toast in an app overlay shows. A dialog route's `Dialog` around one app
  class (`Dialog.fullscreen(child: CouponDialog())`) names that class, and a
  custom popup route's own `Scaffold` is looked through to its body. Two
  anonymous sheets with the same type argument share a `routeKey` but differ in
  `surface.widgetClass`. Production taps do not carry `surface`. It is not
  part of any fingerprint, `routeKey` or `inventoryHash`.
- Documented that `RouteSettings(name: ...)` on `showModalBottomSheet` and
  `showDialog` gives a sheet or dialog a stable, readable route key today.
- In exploration mode, every scene inventory carries `viewport`
  (`widthPx`, `heightPx`, `devicePixelRatio`, `boundaryOffset`, `insets`,
  `keyboardInset`, `referenceFrame: "captureBoundary"`): the frame `boundsNorm`
  is a fraction of. All sizes are in the render view's logical pixels;
  multiply by `devicePixelRatio`, the render view's own ratio, for device
  pixels. `widthPx`, `heightPx` and `boundaryOffset` are the boundary's box
  after any transform above it, so `(boundaryOffset + boundsNorm * widthPx) *
  devicePixelRatio` is exact under a `Transform.scale`, a `FittedBox` or a
  host binding that scales the whole UI. Each element carries `visibleFraction`
  (0 to 1) when part of its paint box is outside the capture boundary or
  clipped by an ancestor, and an inventory with a vertical scrollable carries
  `scroll` (`offsetPx`, `maxExtentPx`, `axis`) for the largest one. `boundsNorm`
  stays unclipped paint bounds. None of it is part of any fingerprint,
  `routeKey`, `inventoryHash` or the de-duplication key, and production taps do
  not compute it.

- Scene inventory entries carry `positional: true` when the canonical path
  has a list position (`[item:N]`), so a consumer can tell that the
  fingerprint names a position rather than the control.
- Scene inventory entries carry `tag` (the nearest explicit `TugboatTag` id)
  when the element sits under one. `hitTestBounds` is not reported.

### Changed

- In exploration mode, scroll inventories follow frames. During a scroll a
  scene inventory is built only for a moment that also captures a frame
  (scroll screenshots, and the after-capture at the end of a scroll a
  pointer drives), and is emitted only when its content differs from the
  last inventory sent. A scroll start, an update with no frame and a
  programmatic scroll end (an auto-scrolling marquee, `jumpTo`) no longer
  build one; the re-sample emits what such a scroll reveals, if anything is
  new. Blend's Logo Maker marquee sent about 14 inventories a second; a
  fixture of it now sends its first inventory and nothing more over 30 s
  (340 before). The viewport semantic map keeps its scroll cadence. This
  holds with `resampleSettledInventory: false` too.
- The fingerprint schema is now 7 (`tugboatFingerprintSchemaVersion`), one
  bump for #137, #139 and #141. Fingerprints that move: controls under a sheet
  or dialog's `DisplayFeatureSubScreen` or modal barrier (the ordinal is
  dropped, so a sheet stacked on its own copy keeps its fingerprints); every
  control on an anonymous sheet or dialog with a nameable class, now keyed
  `sheet:<WidgetClass>` or `dialog:<WidgetClass>` instead of
  `ModalBottomSheetRoute<T>` or `struct:<hash>` (a dialog whose builder
  returns a `Dialog` around one app class included); every control on a route
  whose `struct:` key moved (an anonymous dialog with no nameable class, or
  an anonymous route with a disabled control or a new low-level control);
  controls under a `ListTileTheme` (including inside `Drawer` and
  `ExpansionTile`) or `SwitchTheme`, which are now transparent, and later
  same-type siblings of such a control, which are renumbered; controls inside
  or around an `InkWell` without `onTap` (a `Switch` trailing a `ListTile`
  with no callbacks, a `GestureDetector` around such a tile); and a disabled
  `TextField` with no other control inside, which takes its enabled twin's
  fingerprint. Nothing else moves: an enabled control on a named route with
  none of these above it keeps its fingerprint, in inventories and production
  taps. For one release each exploration inventory entry lists its schema 6
  fingerprints in `aliases`, except one that already names another entry in
  the same inventory. Consumers keyed on schema 6 fingerprints should map
  them through `aliases` during that release.
- Interactive coverage (#141): `Semantics` with a tap or long-press action, a
  `Listener` with `onPointerUp` and a `RawGestureDetector` with a tap or
  long-press recognizer are reported when they are a control of their own
  (outside every control and around none). Disabled controls are listed with
  `enabled: false` and keep their enabled twin's fingerprint; toggling a
  Material or Cupertino button, toggle, `ActionChip`, `TextField` or
  `ListTile.enabled` changes no fingerprint or route key (`InputChip.isEnabled`,
  `CupertinoTextField` and `SearchBar` still differ, as before). A `GestureDetector`, `InkWell`, `ListTile` or tap `Semantics` with a
  `null` callback is not a control, so toggling it still changes an anonymous
  route's `struct:` key. Production taps on a disabled control carry its
  twin's fingerprint. A custom `PopupRoute` keeps its key, and two
  sheets or dialogs with no nameable class and the same structure still share
  one.

### Fixed

- Exploration taps now deliver `fingerprintSource`, `routeKey` and `surface` to
  the HTTP collector. The collector mapper dropped them, so they stayed in the
  in-memory envelope only.
- A tap on a control that stays mounted while the app navigates, such as a
  persistent bottom bar outside the `Navigator`, was fingerprinted under the
  destination route's key while its `route` showed the origin. In production
  mode the pointer-down hit path now wins when the route changed since
  pointer-down, as exploration mode already did, so the fingerprint belongs to
  the route the tap happened on.
- The SDK's own capture root (`ValueKey('tugboat-capture-N')`) was read as a
  developer tag, so every control under `TugboatReplay.wrapApp` with no nearer
  tag reported a junk `tagFingerprint` and `tag` fingerprint part. The tag
  lookup now ends at the capture root. `TugboatTag` and `ValueKey<String>`
  inside the capture tag as before, and fingerprints do not change.
- A tap re-anchored to a different inventory control (an inventory snap or the
  semantic fallback) no longer carries the original hit's `tagFingerprint`.
- In exploration mode a button an app wraps in `ExcludeSemantics` to give it
  one semantics node of its own (`Semantics(label) > ExcludeSemantics >
  ElevatedButton`) was in no inventory, so taps on it failed with
  `no_target_at_point` while production taps resolved it, and the settled
  re-sample never saw it appear. Exploration inventories now list it under
  the identity a tap on it resolves to in both modes, with the hidden
  button's role, actions and paint box, and exploration taps join that entry.
  Production taps are unchanged, and no fingerprint or route key moves. The
  same happened on 0.10.11.
- A tap on such a button inside a scrollable named the scrollable. Blend's
  onboarding Continue (`Visibility` > `AnimatedOpacity` > `Semantics(button)`
  > `ExcludeSemantics` > `ElevatedButton`, whose `onPressed` animates the
  onboarding `PageView`) was the `PageView`'s `Scrollable` in production and,
  in exploration, the list row at the `PageView`'s centre, whose inventory
  entry listed the `Scrollable`'s fingerprint as an alias. Inside a
  scrollable, the hit path now names a sole control hidden under
  `ExcludeSemantics` (found down a chain of single children, no subtree
  walk) when the retained widget whose path the tap takes holds that control
  alone, so both modes give the button, and the pointer-down rule keeps it
  when its tap animates the `PageView`, also for a tap on the button's own
  icon. A scrollable whose centre lands on such a control keeps its own
  inventory entry. Moves: taps on such a control inside a scrollable. Two
  controls under one wrapper, hidden buttons with no retained widget of
  their own (rows or pages that would share one path), a hidden control
  inside another control, and one outside any scrollable are unchanged. The
  same happened on 0.10.11.
- A production tap on a control whose `onTap` animates the scrollable it sits
  in (a grid tile that calls `PageController.nextPage`) was fingerprinted as
  the scrollable, while exploration taps named the tile: the animated scroll
  makes the scrollable ignore pointers before the SDK reads pointer-up. When
  the pointer-up target is a scrollable and the pointer-down hit path names a
  control inside it, that control now wins, so both modes give the tile's
  fingerprint. Taps on a scrollable outside any control are unchanged. The
  same happened on 0.10.11.
- In exploration mode, the inventory of a programmatic scroll (an
  auto-scrolling marquee) could be built while the tree still needed layout:
  its hit tests read stale boxes and, in debug builds, failed
  `'!debugNeedsLayout'` in `RenderFractionalTranslation`, losing the
  inventory (`[tugboat] queued scroll_end task failed`). Such inventories now
  wait for the frame's post-frame callback when layout may be dirty and are
  built at once otherwise. A failing scroll inventory is caught and logged,
  never thrown into the app's scroll notification. Pointer-driven scrolls and
  production are unchanged. The same happened on 0.10.11.
- An inventory taken while a route transition was running (an input
  observation after system back, or a focus change as a dialog opened) listed
  the departing or covered route's controls under the destination's route key.
  A capture request that a running transition suppresses, and a scroll during
  it (a marquee on the page below), no longer emit an inventory; the route
  capture emits the destination's once the transition settles. The same
  happened on 0.10.11.

- The route capture fired a transition duration after the Navigator
  callback, while the transition could still be running and before the
  covered route went offstage. The `route` inventory of a pushed page then
  counted the covered page's spinner, and on an unnamed page whose
  predecessor stays visible beneath it during the transition its `struct:`
  key was computed over both pages: the page's route inventory and first taps
  carried one key, every later inventory of the page another. The capture
  (and the transition window that holds back other inventories) now goes at
  once only when those routes are not animating and no frame is due, and
  otherwise waits until two frames have passed with them at rest, bounded by
  the route barrier timeout. Those route keys move to the settled
  page's key. The same happened on 0.10.11.

### Removed

- The local exploration WebSocket. `TugboatReplayConfig.explorationCollectorUrl`
  and the exported `TugboatExplorationTransport` are gone, along with the
  internal `ExplorationCaptureSink`. Nothing receives that socket any more;
  point `collector` at a local HTTP collector instead.
- The WebSocket control messages `set_action_window`, `clear_action_window`,
  `pause_capture` and `resume_capture`, and `handleExplorationControl` on the
  controller. `TugboatReplayController.setActionContext`, `clearActionContext`
  and `setCapturePaused` are unchanged and remain the in-process way to open
  and close an action window and to pause capture.
- The socket-triggered frame suppression. Connecting the socket without an HTTP
  collector used to suppress non-interaction screenshots; with no socket that
  never happened in a real run, so capture scheduling is unchanged.
- The example app's `tools/sdk-event-collector.js` WebSocket server.

## 0.10.11

### Fixed

- A tap whose own handler opens or closes a route now keeps its target. With
  global pointer capture the SDK read the tap after the app's `onTap` had run,
  and the Navigator then absorbed the hit test, so the interaction was sent
  with an empty `targetAnchor`. Pointer-down now keeps a plain hit test of the
  pressed point, and pointer-up falls back to it when its own hit test finds no
  actionable target. The kept path also wins when the fresh hit test has no
  canonical path and the kept one has a path but no role, as for a button under
  `ExcludeSemantics`. Taps that resolved before resolve exactly as before.

## 0.10.10

### Fixed

- Session start now seeds the navigator's visible route and emits one
  `route_change` with `navigation: session_start`, so the first screen and the
  first post-start navigation retain correct route evidence (including nested
  navigators with dedicated observers).

## 0.10.9

### Fixed

- An invalid frame in a collector upload batch no longer discards neighboring
  valid frames: a rejected batch is retried one frame at a time.
- Frame upload failures, memory-cap evictions, and later recovery now emit
  bounded `capture_diagnostic` events with no image contents or credentials.
- Frame HTTP requests time out after 15 seconds so a stalled upload does not
  block subsequent flushes indefinitely.

## 0.10.8

### Fixed

- Perceptual (dHash) frame coalescing no longer hides real UI changes. A
  capture whose visible structure changed since the referenced frame (retained
  widgets, control enabled state and values (checkbox, switch, radio, chip
  selection, slider), blocking overlays, or the bounds of text, editable,
  and image boxes) is always encoded instead of being
  coalesced into a 9x8-similar frame, so masked error text, new banners, and
  toggled controls produce their own frame. The structure signature is local
  only: it reads no text or pixels and is never serialized.
- The dHash baseline now stays on the frame that is actually referenced. A
  coalesced candidate no longer replaces it, so a series of small changes can
  no longer drift arbitrarily far from the last recorded frame without a new
  frame.

### Added

- Opt-in `TugboatReplayConfig.captureFocusChanges`: emits a `focus_changed`
  evidence event (`focus` / `previousFocus`: `text_input`, `other`, `none`)
  when primary focus moves into, out of, or between editable text fields,
  including keyboard "next" actions and programmatic focus with no pointer,
  and requests one visual observation after `settleDelay`, referenced as
  `afterFrame`.
- Opt-in `TugboatReplayConfig.captureSystemInput`: emits a `system_input`
  evidence event (`input`: `back`, `volume_up`, `volume_down`, `volume_mute`,
  `power`, `media_play_pause`) for system back requests and allowlisted
  hardware keys, and requests one visual observation after `settleDelay`,
  referenced as `afterFrame`. Key events and back requests are never consumed.
  Other keys are never recorded.
- Both are off by default because the collector must accept the new event
  types first. Their frames use the existing `manual` trigger.

## 0.10.7

### Added

- API error `network_call` events (`outcome: response` with a 4xx/5xx status)
  now carry a bounded `errorResponseBody` on collector payloads, so backend
  rejections are diagnosable without a device. Successes, transport failures,
  and cancellations never carry one. Snapshots stay capped at 4 KiB.

## 0.10.6

### Added

- `POST /v1/frames` multipart uploads include a `frameMetadata` JSON array aligned
  with each JPEG, carrying `TugboatFrame` capture fields (`requestedBackend`,
  `resolvedBackend`, `captureMicros`, dimensions, etc.) for collector
  `raw_frames` ingestion.

## 0.10.5

### Fixed

- Accept the iOS launch inputs from launch arguments as well as the process
  environment (`--tugboat-emit-scene-inventory[=value]`,
  `--tugboat-accept-action-context[=value]`,
  `--tugboat-collector-base-url=<url>`, `--tugboat-automation-run-id=<id>`;
  a bare flag means true), so iOS automation hosts that can pass launch
  arguments but not environment (e.g. agent-device `--launch-args`,
  Appium/XCUITest) can enable capture. The environment wins when both are
  present. Raw strings still pass through untouched; Dart
  `TugboatLaunchParsers` owns all normalization. Android behavior is
  unchanged.

## 0.10.4

### Fixed

- Canonical `interaction` events now attach resolved `targetAnchor` (including
  `canonicalPath`) on the session record and on collector payloads when identity
  resolution succeeds.

## 0.10.3

### Added

- Non-secret automation run correlation id on the launch plumbing:
  `TugboatLaunchOptions.automationRunId` from the Android Intent extra
  `tugboat_automation_run_id`, the iOS process environment
  `TUGBOAT_AUTOMATION_RUN_ID`, and the `tugboat/launch` map key
  `automationRunId`. Blank values decode to null and the id is echoed in
  `toJson` (hence the `TUGBOAT_LAUNCH` debug line) only when set, so
  automation logs correlate to one run. It MUST NOT carry Firebase custom
  tokens, credentials, or determine entitlements/authentication; the SDK is
  not coupled to Firebase or RevenueCat.

## 0.10.2

### Added

- Map SDK `network_call` events onto the collector payload allowlist, including
  HTTP 4xx/5xx responses with `outcome: response`.
- Opt-in, redacted collector HTTP proof logging for Device Farm diagnostics
  (`--dart-define=TUGBOAT_HTTP_PROOF=true` in debug builds).

## 0.10.1

### Added

- Include session-relative `atMs` on `POST /v1/sessions` payloads, matching
  event batches.

## 0.10.0

### Added

- Device Farm launch inputs owned by the SDK: `TugboatLaunchOptions`
  reads Android Intent extras (`tugboat_emit_scene_inventory`,
  `tugboat_accept_action_context`, `tugboat_collector_base_url`) and iOS
  process environment (`TUGBOAT_EMIT_SCENE_INVENTORY`,
  `TUGBOAT_ACCEPT_ACTION_CONTEXT`, `TUGBOAT_COLLECTOR_BASE_URL`) through the
  `tugboat/launch` plugin channel, so host apps need no native code.
- `TugboatReplayConfig.withDeviceFarmOverrides()`: additive merge of launch
  capabilities plus a release-guarded, local-only collector URL override
  (`resolveTugboatCollectorBaseUrl`). Hosts collapse to a single call.

### Fixed

- Coalesce the back-to-back `hidden` + `paused` lifecycle callbacks into a
  single `app_backgrounded` event instead of emitting one per state.

## 0.9.0

### Changed

- Replace `TugboatCaptureProfile` with one privacy-safe capture policy.
- Use `TugboatReplayConfig.enabled` for lifecycle configuration.
- Add explicit, additive capabilities for scene inventory, viewport semantic
  maps, capture diagnostics, and external action context.
- Keep `allTextAndMedia` as the default screenshot mask when capabilities are
  enabled.
- Make `TugboatParameterPolicy.allowAll` mode-free and remove the duplicate
  production-specific parameter policy.
- Remove capture-profile fields from SDK health and sink session context.
- Rename the controller action-window API to `setActionContext` and
  `clearActionContext`.

### Migration

- Replace `profile: TugboatCaptureProfile.dormant` with `enabled: false`.
- Replace `profile: TugboatCaptureProfile.productionLean` with `enabled: true`.
- Replace exploration mode with `enabled: true` plus only the required
  additive capabilities.
- Remove the `profile` argument from `TugboatReplay.activate`.

## 0.8.17

### Fixed

- Reject blank iOS engine-surface captures and retry with explicit hierarchy
  capture before falling back to Flutter capture.
- Resolve the live `FlutterView` without selecting an unrelated controller
  view.

### Changed

- Raise the default degraded capture scale from `0.67` to `0.80` to retain
  more screenshot detail when the capture budget is degraded.
- Depend on CocoaPods `TugboatCaptureRuntime` `0.1.1`.

## 0.8.16

### Fixed

- The iOS plugin compiles on Flutter 3.35. `registrar.viewController` is a
  Flutter 3.38 API, so look it up at runtime and fall back to the key window
  when resolving the live Flutter view for opt-in native CPU capture.

## 0.8.15

The iOS plugin depends on CocoaPods `TugboatCaptureRuntime` `0.1.0` and
raises the plugin floor to iOS 15. Native CPU capture stays opt-in.

## 0.8.14

The Android plugin depends on Maven Central
`com.gettugboat.sdk:capture-runtime:0.1.0` instead of compiling
`platforms/android` from source or stubbing native capture in published
packages. Native CPU capture stays opt-in.

## 0.8.13

Patch release after published `0.8.12`.

### Fixed

- The Android plugin compiles `capture-runtime` from monorepo sources instead
  of requiring unpublished Maven `com.gettugboat.sdk:capture-runtime:0.1.0`.
- The iOS plugin no longer depends on unpublished CocoaPod
  `TugboatCaptureRuntime` and keeps a deployment target of iOS 12. Native
  capture remains runtime-gated to iOS 15.
- Align Android/iOS plugin packaging versions with Dart `0.8.13`.
- Bind iOS native capture to the registrar's Flutter view instead of the
  key window.

### Added

- Convert `tugboat` into a Flutter plugin with an experimental opt-in native
  CPU capture backend (`nativeCpuExperimental`) on Android (`PixelCopy`) and
  iOS (live Flutter-layer rendering). The default remains
  `flutterRepaintBoundary`, with automatic fallback when native capture is
  unavailable or fails safely.
- Record a regenerable JPEG size envelope for the current Dart encoder so the
  native CPU capture path can compare codec output against the same buffers.
- Native `encodeMicros` is the Pigeon capture round-trip only. Nested native
  stage timings stay on the backend trace so `TugboatFrame.captureMicros` does
  not double-count PixelCopy, dHash, JPEG, and SHA-256.
- Published `TugboatFrame` records include `requestedBackend`,
  `resolvedBackend`, and `fallbackReason` so production screenshots identify
  Flutter vs native without `capture_diagnostic` events. HTTP `/v1/frames` is
  still JPEG-only.
- `route_change` now splits route identity (`routeName`, `routeType`,
  `routeNamed`, and the matching `from*` fields) without changing `route`,
  `fromRoute`, or `navigation`.
- Overlay classification is the closed set `page | sheet | dialog | popup |
  unknown`. Bottom sheets are `sheet` (no longer `modal`).
- Overlay pushes include presentation parent (`presentedOver*`, `hostPage*`)
  and a bounded same-navigator `routeStack` snapshot.
- Claimed route changes copy `causeTargetFingerprint` and `causeGesture` from
  the interaction. Overlay after-frames still capture under exploration
  screenshot suppression when `overlayKind` is not `page`.
- Raise the example Android wrapper to Gradle 8.14 / AGP 8.11.1 / Kotlin 2.2.20
  so Flutter 3.47 can build a release APK for device-lab capture gates.
- Document the mobile monorepo, native capture contracts, fallback, coverage,
  and path-aware version / license / API-surface checks. Native capture stays
  experimental.

## 0.8.12

Patch release after `0.8.11`.

### Fixed

- Stamp the current runtime `userId` and traits snapshot on every session
  lifecycle POST (`session_start`, `session_identify`, `traits_updated`,
  `user_changed`, `session_end`). Slim payloads had omitted identity from
  traits-only updates and omitted both fields from `session_end`.

## 0.8.11

Patch release after `0.8.10`.

### Changed

- Refactor capture, replay, semantic, model, and network paths to keep each
  function at or below a cyclomatic complexity of 10.
- Add a workspace complexity check that fails on warnings.
- Preserve locale-independent fingerprints and the 0.8.10 capture reliability
  behavior during the refactor.

## 0.8.10

Patch release after `0.8.9`.

### Fixed

- Flush a newly enabled Flutter semantics tree only when no frame is pending.
  During dirty layout or paint, read the last stable tree and use scene
  inventory fallback instead of forcing an unsafe semantics flush.
- Replace fixed screenshot waits in release-gate widget tests with a bounded
  controller-idle wait. The full SDK suite now covers real screenshot encoding,
  masking, interaction action windows, and production-masked modal ownership.
- Align the workspace lockfile with the checked-in Flutter 3.35.7 and Dart
  3.9.2 toolchain.

### Compatibility

- Document and verify that collector mapping preserves schema-v2 `pan`,
  `zoom_in`, and `zoom_out` facts, including `pointerCount` and zoom `scale`.

## 0.8.9

Patch release after `0.8.8`.

### Fixed

- Keep a classified touch gesture open until all contacts lift. Replacement
  fingers join the same gesture, and zoom scale continues across contact changes.
- Detect pinches that start with contacts closer than the touch slop.
- Keep stationary third-finger taps until movement confirms a shared gesture.
- Include trackpad pan travel in `endPosition` and `delta`.
- Continue touch travel after the primary finger lifts. Later contact movement
  updates `endPosition` and `delta` without jumps when fingers join or lift.
- Clear input contacts on pause, hide, and detach, even when Flutter does not
  deliver pointer cancellation. A later swipe starts a new gesture.

One-finger canvas pan remains `swipe`. Observed Flutter scrolling remains
`scroll`. This patch does not change the event or fingerprint schemas.
Touch `scale` describes contact-span ratios, not the host widget's transform.

## 0.8.8

This release follows `0.8.0` and stays on the `0.8.x` line as `0.8.8`.

### Added

- Exploration capture now snapshots fresh target, inventory, and viewport
  semantic evidence at primary pointer-down. It records bounded diagnostics and
  a closed failure reason when no safe target fingerprint is available.
- Actionable semantic nodes without a direct fingerprint link can use a
  guarded scene-inventory fallback. Fallback fingerprints have low confidence.
- Capture sessions and events now carry the active app locale. The SDK observes
  `Localizations`, emits `locale_changed` evidence, includes locale in
  exploration sessions, and supports `TugboatReplay.setLocale(...)`.

### Changed

- A completed exploration tap reuses its pointer-down evidence. Pan, zoom,
  scroll, cancellation, secondary pointers, production capture, and dormant
  capture do not run or publish this tap-only path.
- Fingerprint schema 6 now uses structural list and grid positions instead of
  visible text or icon data. Nested Flutter hit targets normalize to the same
  primary inventory control in exploration and production capture.

## 0.8.7

This release follows `0.8.0` and stays on the `0.8.x` line as `0.8.7`.

### Added

- `TugboatCollectorHost.fromPlatform()` now snapshots optional session-start
  device facts on `session_start`: `batteryPercent`, `storageFreeMb` (free
  internal storage), `ramMb` (Android physical RAM via `device_info_plus`),
  and `networkType` (`wifi`, `cellular`, `ethernet`, `vpn`, `none`, or
  `other`). Each field is omitted independently when the platform cannot
  observe it.
- Three-finger shared translation now publishes one canonical `swipe`
  interaction with `payload.pointerCount: 3`. Two-finger pan/zoom and
  one-finger swipe behavior is unchanged.

### Changed

- Bumped `device_info_plus` to `^11.5.0` so Android RAM can be observed for
  the session-start snapshot.

## 0.8.6

This release follows `0.8.0` and stays on the `0.8.x` line as `0.8.6`.

### Fixed

- Default `TugboatReplay.eventHook` parameter policy now retains bounded
  JSON-safe external-event values (`allowAllInProduction`). Parameter keys
  were already captured; values were omitted unless the host opted in. Hosts
  that must not retain values can still pass `namesOnly`, an allow-list, or a
  transform. Existing JSON and size bounds still apply.

### Added

- Canonical interactions now include `pan`, `zoom_in`, and `zoom_out`.
  Two-pointer pinch and translation, plus trackpad pan/zoom events, publish
  one gesture. Nested payload carries `position` / `endPosition` / `delta`,
  `pointerCount` when above one, and `scale` for zoom. Two-finger list
  scrolling still becomes `scroll`. Stationary two-finger contact remains two
  taps.

### Changed

- `productionLean` capture profiles no longer emit `capture_diagnostic` session
  or collector events. Bounded `healthSnapshot().captureDiagnostics` counters
  still update on device. Exploration profiles continue to emit full diagnostic
  events.

## 0.8.5

This release follows `0.8.0` and stays on the `0.8.x` line as `0.8.5`.

### Breaking changes

- The SDK now publishes only schema-v2 canonical `interaction` gesture events.
  Removed legacy gesture projections, publication modes, session aliases, and
  compatibility constructors.
- Removed the on-device outbox and its public configuration. Collector and
  exploration delivery are best-effort through bounded in-memory queues.
- `interaction.afterFrame` now means a temporal post-interaction observation.
  An unclaimed route frame can satisfy it without creating route causality or
  an inferred result.

### Changed

- Production-friendly scroll capture now keeps scroll metrics independent from
  screenshots. In-motion scroll screenshots are opt-in, pressure-droppable,
  and disabled by default; pointer-linked scrolls retain one optionally
  deferred scroll-end observation.
- Screenshot output can be bounded with `captureMaxWidth` /
  `captureMaxHeight`. A degraded screenshot budget applies
  `degradedCaptureScale` before GPU readback, reducing raw RGBA allocation as
  well as encoded size.
- Low-priority captures dropped under active/queued capture pressure emit the
  bounded `capture_pressure_drop` diagnostic outcome.
- `capturePixelRatio` accepts values above `1.0`. Optional output bounds still
  cap the effective readback scale before allocation.
- Network observation accepts bounded absolute paths with dynamic identifier
  segments. Schemes, queries, fragments, encoded data, network-path prefixes,
  backslashes, whitespace, and control characters remain rejected.

### Fixed

- A new pointer-down cancels a pending deferred scroll-end screenshot before
  Flutter reports the next `ScrollStart`. The completed scroll keeps its final
  offsets, overscroll count, target fingerprint, and interaction record, but it
  does not block or consume the new gesture.
- Tap-only target, inventory, and viewport-semantic resolution now runs after a
  gesture remains a tap. Scroll gestures no longer pay that work on
  pointer-down.
- Scroll completion joins pointer-up and `ScrollEndNotification` in either
  callback order and publishes one canonical interaction. Pointer cancellation,
  replacement scrolls, lifecycle changes, and programmatic scrolls do not leave
  a late interaction screenshot request.
- Interaction after-frames must complete after the interaction boundary. A
  pre-pointer-up frame cannot become an after-frame, including frames from a
  claimed route capture that settles while the pointer is still down. An
  unrelated automatic route cannot add causal route evidence to the interaction.
- Tap target resolution uses the pointer-down position so a slop-bounded
  release cannot resolve a sibling control or miss the recognizer's original
  target.
- Screenshot capture pixel-ratio clamp results are explicitly converted to
  `double` for sound null-safety.

## 0.8.0

### Changed

- Raw SDK writers no longer emit `stateAnchor`, `stateSignature`, or
  `state_change` events. Session wire schema 10 identifies this contract and
  the serialized `interaction` frame trigger. Completed interactions request
  one fresh after-frame.
- Collector event mapping now omits `stateAnchor`. Deploy the serial collector
  compatibility patch before sending 0.8.0 recordings to a collector that
  still requires that key.
- Production collector events for `interaction` and `route_change` use flat
  schema-v2 wire shapes (`interactionSchema` or `routeChangeSchema` == `2`) with
  facts-only fields. The mapper no longer emits empty `targetAnchor` objects or
  duplicates `stream` inside generic `payload`. Interaction v2 drops inferred
  `result`, nested `origin`/`result`, and tap-settle outcome computation.
- `interaction` schema v2 carries gesture-specific facts under a nested
  `payload` (`position` for tap; `position`/`endPosition`/`delta` for swipe,
  pan, and zoom; `scale`/`pointerCount` for zoom and two-pointer pan;
  `position`/`startOffset`/`endOffset`/`overscrollCount` for scroll). Cancelled
  interactions omit `payload`. The SDK no longer emits `scroll_start`,
  `scroll_end`, or `pointer_cancel` — scroll and cancel semantics live on
  `interaction` only.

## 0.7.1

### Changed

- **Screenshot capture performance** — remove the post-capture state-signature
  short circuit and replace it with a paint-signature gate that skips the full
  GPU readback/encode path when the capture subtree (including nested
  `RepaintBoundary`s) has not painted. Diagnostic outcome
  `state_signature_short_circuit` is replaced by `paint_generation_unchanged`.
- **Encode path** — JPEG encoding, SHA-256, mask fills, and dHash now run on a
  persistent background isolate with transferable RGBA input. dHash coalesce
  tolerates Hamming distance ≤ 2. Default screenshot budget is 60 ms / 5 s.
- **Collector uploads** — frame wire format docs corrected to JPEG. Pending
  frames are not superseded on enqueue: events reference exact frame IDs and
  multipart upload has no hash alias.

## 0.7.0

### Added

- **Explicit production parameter opt-in** —
  `TugboatParameterPolicy.allowAllInProduction` retains JSON-safe external-event
  parameter values in production capture profiles. `namesOnly` remains the
  default. `allowAll` remains an exploration-only escape hatch and still
  downgrades to names-only outside exploration. The existing JSON and size
  bounds still apply. This policy can retain feedback, search terms, URLs, IDs,
  and other user content. Hosts must confirm consent, privacy, access, and
  retention rules before they use it.

## 0.6.0

### Changed

- **Canonical interactions are now the recording default** —
  `TugboatReplayConfig.interactionPublishMode` defaults to `canonicalOnly`, so
  each finalized gesture emits one semantic `interaction` instead of also
  emitting `tap`, `tap_settled`, or `swipe` compatibility rows.
- **Legacy gesture publication is deprecated** — `dualWrite` and `legacyOnly`
  remain explicit migration overrides for historical consumers. New
  integrations must not enable them; removal prerequisites and the searchable
  `TODO(tugboat-legacy-projection-removal)` marker are documented in the SDK
  README.

### Added

- **Provider-neutral coded-event hook** — `TugboatReplay.eventHook` records one
  logical `external_event` on the evidence stream with a bounded parameter
  policy (`namesOnly`, `allowList`, `transform`, or exploration-only
  `allowAll`). Values are deep-copied at hook time; dormant/disabled calls are
  safe no-ops.
- **Generic network observation** — `TugboatReplay.beginNetworkCall` exposes an
  exactly-once token for method, safe route template, status, outcome, and
  duration. No headers, queries, bodies, raw errors, or stack traces are
  retained.
- **Evidence isolation** — external and network evidence stamp session identity
  only and never inherit active exploration `actionId`, `relatedEventId`, or
  target/state anchors.
- **Evidence health counters** — `TugboatSdkHealth.evidence` exposes bounded
  accepted/dropped/duplicate-finish counts without retaining rejected raw
  values.
- **`tugboat_dio` companion package** — Dio interceptor that maps request
  lifecycle callbacks onto the core network token without importing Dio into
  core.

### Fixed

- **Session-bound evidence completion** — in-flight network tokens can no
  longer finish into a replacement session, and session end fences reentrant
  evidence before publishing its terminal event.
- **Production parameter policy** — exploration-only `allowAll` is downgraded
  to names-only outside exploration, and unsupported values contribute one
  drop to bounded diagnostics.
- **Session-end admission** — session end claims its in-flight future before
  sync sink work, so evidence fencing no longer needs a separate ending bool.
- **Deactivate evidence fence** — `TugboatReplay.deactivate` closes evidence
  admission immediately; the activation gate still owns `session_end` on
  teardown.

## 0.5.3

### Added

- **Debounced identity coalesce** — after `session_start`, `setUserId` and
  `setTraits` within 3s consolidate into one `session_identify` POST when
  both change; otherwise `user_changed` or `traits_updated`. Pending updates are
  flushed before `session_end`.

### Changed

- Pre-start identity still folds into a single `session_start` when values are
  staged before or while start is pending.

## 0.5.2

### Changed

- **`setUserId` folds into pending `session_start`** — when a `session_start`
  is still pending, `CollectorHttpSink.setUserId` updates the runtime id only
  and skips `user_changed` (same coalesce already used by `setTraits`). Boot
  identity can land on a single `session_start` POST.

## 0.5.1

### Added

- **User traits via collector sessions** — `TugboatReplay.setTraits` posts
  `eventType: traits_updated` on `POST /v1/sessions` with a full traits bag,
  caches the response `traitsId`, and stamps it on event batches.
  `TugboatReplay.setUserId` posts `user_changed` and updates the runtime user
  id. Pre-set traits are included on the next `session_start`. No
  `/v1/identify` route.

### Changed

- **`setUserId` skips unchanged ids** — calling `TugboatReplay.setUserId` /
  `CollectorHttpSink.setUserId` with the same value as the current runtime
  user id does not post `user_changed`.
- **Pre-initialize identify** — `setTraits` / `setUserId` called after the
  controller mounts but before the HTTP sink is created retain identity for
  the next `session_start` instead of dropping it.

## 0.5.0

### Breaking changes

- **Control-value and semantic-annotation telemetry** — session JSON writers
  now emit schema version 9 and no longer write `controlValue`,
  `controlValueTransition`, or `semanticAnnotation` in event `data`.
  Readers that support historic schemas should continue to tolerate versions
  6–8, where those fields may be present.
- **Removed public barrel exports** —
  `TugboatEncodedControlScalar`, `TugboatVisibleControlValue`,
  `TugboatControlValueScope`, `TugboatControlValue`, and
  `TugboatSemanticAnnotation`.
- **Removed public schema constants** —
  `tugboatControlValueSchemaVersion`,
  `tugboatControlValueTransitionSchemaVersion`, and
  `tugboatSemanticAnnotationSchemaVersion`.
- **Removed public extraction and merge helpers** —
  `tugboatControlValueForWidget`,
  `tugboatControlValueFromSemanticsProperties`,
  `tugboatControlValueFromSemanticsNode`,
  `tugboatSemanticAnnotationFromProperties`,
  `tugboatSemanticAnnotationFromNode`,
  `tugboatMergeSemanticAnnotations`, and `tugboatMergeControlValues`.

## 0.4.18

### Fixed

- **Semantic parameter pairs in overlays** — interactions in dialogs and
  popovers now retain the accessibility label and raw value supplied by the
  visible control, rather than metadata from an obscured control beneath it.

## 0.4.17

### Changed

- **Raw control and semantic values** — control values, semantic values, and
  semantic labels are now sent verbatim instead of being tokenized. This makes
  slider positions, durations, and template identifiers available for session
  summaries and aggregate analysis.
- **Explicit custom-control values** — `TugboatControlValueScope` exposes a
  stable `controlKey`, typed number/duration/enum value, optional unit, and
  numeric range metadata for controls whose value is not readable from a
  standard Flutter widget.

## 0.4.16

### Added

- **Privacy-safe interaction metadata** — valued controls and semantic
  annotations can enrich tap, settle, swipe, and scroll events without
  retaining arbitrary semantic text.

### Changed

- **Causal control-value transitions** — settled control values are captured
  from the original interaction target and use a distinct transition payload.
- **Canonical interaction parity** — canonical-only tap and swipe results retain
  their post-interaction control and semantic metadata without relying on
  legacy projection events.
- **Cross-SDK semantics flags** — checked-state capture compiles on the
  package's declared Flutter 3.35 minimum and newer enum-based SDKs.

## 0.4.15

### Added

- **Canonical `interaction` events** — each finalized gesture emits one
  `stream: semantic` record with immutable `origin`, `result`, `attribution`,
  and `evidenceEventIds` (`interactionSchema: 1`). Legacy `tap` / `tap_settled`
  / `swipe` continue as dual-write peers on `stream: legacy_projection`.
- **Evidence stream** — `route_change`, `state_change`, `scroll_start`,
  `scroll_end`, and `pointer_cancel` emit on `stream: evidence` so default
  semantic enrichment selects only canonical interactions.
- **`enrichmentCandidate`** on collector-mapped events — false for evidence,
  diagnostic, and legacy-projection records; true for canonical `interaction`
  (and compat semantic tap/tap_settled/swipe when canonical emission is off).
- **Delayed reconciliation window** — `interactionClaimWindow` defaults to
  1,250 ms. A released tap can claim the first eligible visible route/modal
  successor in that window (`interactionAttribution: delayed_likely`). Set the
  window to `Duration.zero` to retain microtask-only same-turn claims.
- **Diagnostic stream isolation** — `capture_diagnostic` events carry
  `stream: diagnostic` so enrichment/insight queries can ignore them by
  default. Session health still aggregates outcome counts.
- **`causedByInteractionId`** on claimed `route_change` / `state_change`
  (alongside existing `causeEventId`).

### Fixed

- **Swipe origin freeze** — swipe events retain the pointer-down state anchor
  rather than refreshing live controller state at pointer-up.
- **Settle waits for delayed successors** — when the claim window is active,
  tap settlement holds until a successor claims or the deadline expires instead
  of finalizing `unknown` immediately.
- **Terminal cancelled interactions** — abandoning a pending/released
  transaction (lifecycle, session end, supersede, post-up cancel) publishes a
  canonical `gesture=cancelled` interaction instead of silently dropping it.

## 0.4.14

### Fixed

- **Automatic-navigation visual continuity** — when a route transition
  supersedes an in-flight tap capture, `tap_settled` now waits for and attaches
  the route's fresh frame as a non-causal `visual_successor`. A pointer-generation
  fence prevents later user interactions from being attached to the earlier tap.

## 0.4.13

### Fixed

- **Deferred tap emission** — `tap` is sampled at pointer-down but only emitted
  after gesture classification at pointer-up. Flick-scrolls no longer mint
  phantom taps; swipes carry `startCaptureCoordinate` instead of
  `relatedEventId` to a never-settled tap.
- **Same-turn interaction claims** — released pointer-up claims attribute
  `route_change` only through the pointer-up turn (`same_turn`). A wall-clock
  claim window incorrectly bound automatic redirects to taps; `interactionClaimWindow`
  defaults to zero and no longer extends attribution. Pre-up claims still work
  while the pointer is down (long-press → navigate).
- **Pre-up claim + swipe/cancel** — routes that claim before pointer-up no longer
  force a normal interaction tap; the buffered tap publishes as `causal_only`
  when the gesture finalizes as swipe/cancel (or at `route_change` publish).
- **Lifecycle claim fence** — backgrounding drops pending/released pointer claims
  so resume/navigation cannot attribute a pre-background gesture.
- **Session-end claim fence** — pending pointers are abandoned without emitting
  orphan `causal_only` taps when the claimed route was cancelled before publish;
  further pointer-down/up/cancel is ignored.
- **Duplicate pointer-down** — a second down on the same pointer abandons the
  prior pending claim instead of silently overwriting it.
- **Claim map hygiene** — `_claimsByTapEventId` entries are removed when a claim
  emits, drops, or expires; `invalidatesRelatedTap` is always a boolean.
- **Monotonic deferred publish** — buffered taps / `tap_outside_tree` publish at
  emission `atMs` with `sampledAtMs` preserving pointer-down time.
- **Gesture promotion** — `tap_gesture_resolved` (`promotesRelatedTap`) plus an
  in-memory `replayRole` patch promote genuine taps that were first published as
  `causal_only` for a pre-up route claim.
- **Missing-frame coordinates** — `unavailableReason: missing_frame` now keeps
  boundary-local / normalized geometry when the boundary rect is known, instead
  of zeroing local/normalized fields.

## 0.4.12

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
- **Replay capture contract documentation** — documents the implemented route/frame
  attribution invariant separately from the still-open production acceptance
  gaps for rapid modal chains, automatic navigation, and playback tap-coordinate
  alignment.
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
