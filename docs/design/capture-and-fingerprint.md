# Capture and fingerprint architecture

Status: current implementation audit (2026-07-26)
Scope: `sdks/flutter/packages/tugboat` in this repository

This document describes what the Flutter SDK implements today. It deliberately
does not specify the internals of the CLI, collector, dashboard, or Atlas
services. Those systems consume the contracts described here, but their own
repositories remain authoritative for ingestion and enrichment behavior.

## Goals and invariants

The SDK captures evidence that can be joined to an app graph without retaining
arbitrary visible text as structural identity.

- State and target identity are deterministic within one build and fingerprint
  schema version.
- Optional evidence capabilities use the same fingerprint algorithm.
- Locale is emitted as session and event evidence but never enters identity.
- Developer tags strengthen matching but are optional.
- Screenshots remain visual evidence and are masked before leaving the app.
- Capture failures and sink failures must not interrupt the host app.
- Disabled lifecycle configuration returns the host child unchanged.

Cross-build stability is not promised. Consumers should namespace identity by
build metadata and `fingerprintSchemaVersion`; remapping identities across app
builds is downstream work.

## Current architecture

```text
NavigatorObserver + global/local pointer input + scroll notifications
                              |
                              v
                 TugboatReplayController
                    |        |        |
                    |        |        +-- viewport semantic session
                    |        +----------- masked screenshot capturer
                    +-------------------- structural anchor resolver
                              |
                        in-memory session
                              |
                    sink hub (failure-isolated)
                              |
                        HTTP collector
```

`TugboatReplay.wrapApp` installs the controller, repaint boundary, input
capture, scroll listener, and lifecycle observer only when capture is enabled.
`TugboatReplay.navigatorObserver` supplies route changes and navigator context.
Both are needed for complete capture.

### Lifecycle and capabilities

`TugboatReplayConfig.enabled` controls the capture lifecycle. Scene inventory,
semantic-map, diagnostic, and action-context evidence use separate additive
capabilities. All optional capabilities are false by default. The default
screenshot mask is always `allTextAndMedia`.

`TugboatReplay.disabled = true` is a global kill switch. It deactivates the
current controller and keeps future calls to `wrapApp` inert. Runtime
`activate(activationRequestId:)` notifies the mounted gate without
requiring a host rebuild. `deactivate()` tears capture down through the same
gate. Pause/hidden flush pending delivery; detach ends the session once.

Identity fields (session schema **v10** only):

- `activationRequestId` — host request correlation
- `captureSessionId` — SDK-emitted session (`session.id`)
- `collectorSessionId` — HTTP transport ID after accept
- `explorationRunId` — exploration control plane

Cross-build fingerprint equivalence remains outside this repository. The SDK
emits exact build and fingerprint-schema provenance only.

## Session and event model

The controller owns one bounded, in-memory `TugboatSession`. Serialized session
JSON is schema version `10` only. Schema v9 stopped writing `controlValue`,
`controlValueTransition`, or `semanticAnnotation` in event `data`; those fields
are optional historic data in older sessions only. Schema v10 removes
serialized state identity and adds the `interaction` frame trigger.

The session stores:

- frame metadata plus JPEG bytes;
- ordered events;
- optional scroll samples;
- app/platform/viewport metadata;
- activation / capture / collector identity fields;
- a `truncated` flag when configured frame or event limits are exceeded.

Collector and exploration delivery are best-effort. Bounded in-memory queues do
not survive process termination.

The event stream currently includes:

- lifecycle: `session_start`, `session_end`;
- canonical gestures: `interaction` (`gesture`: `tap`, `swipe`, `scroll`,
  `cancelled`) with nested `payload` facts;
- navigation: `route_change`;
- exploration control: `scene_inventory`, `action_window_set`,
  `action_window_cleared`;
- optional semantic evidence: `viewport_semantic_map`,
  `scroll_semantic_snapshot`;
- optional input-context evidence: `focus_changed` and `system_input`.

Events may carry `beforeFrame`, `afterFrame`, `targetAnchor`,
`relatedEventId`, `explorationRunId`, `actionId`, and type-specific `data`.
Schema-v2 production `interaction` and `route_change` collector records are
flat facts-only shapes without inferred interaction results. `interaction`
carries gesture facts under nested `payload` (omitted for `cancelled`).
Route transition values live in `route_change` fields, not in a session-level
route dictionary.

### Capture lifecycle and attribution

`wrapApp` starts a session only after its repaint boundary has a non-zero
viewport. The session begins with `session_start` and an initial capture
request. Pointer-down freezes a compatible pre-interaction frame. Pointer-up
publishes one canonical `interaction` after gesture classification. Its
after-frame is a temporal observation captured after the interaction. A route
frame can satisfy this reference even when the route is not causally attributed
to the interaction. Causal route ownership remains on `route_change`. A capture
that is unavailable, cancelled, or timed out remains absent.

Frame requests are serialized and use fresh-paint/readback checks before
publishing. Non-interaction requests can coalesce and reuse exact-content or
perceptual frames only within a compatible context. Each completed interaction
uses a separate fresh request and cannot coalesce or reuse either type of
frame. Provenance records capture context without state identity. `paused` and
`hidden` request a delivery
flush after 500 ms; `resumed` cancels that pending flush; `detached`, wrapper
disposal, and deactivation end the session once and initiate sink shutdown.

Input event coordinates (`x`, `y`, and swipe start/delta values) originate as
Flutter global logical-pixel coordinates. The resolver converts a global point
to capture-boundary local coordinates only to hit-test and normalize it against
the viewport; stored coordinates are not capture-boundary-normalized for replay
playback, are neither device pixels nor widget-local, and can therefore produce
fractional overlay drift.

### Focus and system input

Both capabilities are opt-in (`captureFocusChanges`, `captureSystemInput`)
because the collector must accept their event types. Each records one
evidence event and requests one reusable visual observation after
`settleDelay`. The event is published once that observation resolves, with
`afterFrame` naming a frame completed no earlier than the input, or, when a
navigation the input caused suppresses the standalone capture, the route
barrier's frame. Session end, session replacement, and backgrounding publish
waiting events without a frame. Frames keep the `manual` trigger.

- `focus_changed` fires when primary focus moves into, out of, or between
  editable text fields, including keyboard "next" actions and programmatic
  focus that no pointer caused. It carries only `focus` and `previousFocus`
  (`text_input`, `other`, `none`). Focus churn between non-text nodes, such as
  route scopes, is ignored.
- `system_input` carries a closed `input` value. `back` is a system back
  request that reached Flutter as a navigation pop request. It is observed by
  a binding observer that registers when a `TugboatNavigatorObserver` is
  constructed, which normally precedes the app's `WidgetsApp`. The observer
  never claims the request. If it registers later, only back requests the app
  does not handle are seen. Predictive-back transitions that the app claims
  do not produce `back`; their pop is still a `route_change`. Allowlisted
  hardware keys that Flutter receives (`volume_up`, `volume_down`,
  `volume_mute`, `power`, `media_play_pause`, key-down only) are observed
  without consuming them. iOS does not deliver hardware volume buttons to
  Flutter. Character, editing, and navigation keys are never recorded.

### Navigator and modal routes

Installing `TugboatReplay.navigatorObserver` is intended to record the standard
Navigator push, pop, replace, and remove callbacks automatically. No
per-navigation SDK call is required. When a session starts, the SDK also emits
one synthetic `route_change` with `navigation: session_start` for the route
already visible on the observed navigator (including nested observers), so
evidence before the first post-start navigation carries the correct route.
Navigator-driven `route_change` values remain `route_push`, `route_replace`,
`route_pop`, and `route_remove`. Dialogs and `showModalBottomSheet`
instances can participate when their routes use that observed Navigator. Nested
navigators require their own observer integration; native/system overlays
remain outside the Flutter Navigator and repaint-boundary surface.

Every visible navigation change advances a route epoch and has a single route
capture barrier after transition settlement. A later visible navigation
supersedes stale work. This is the implemented intended invariant: a delayed
destination capture or tap-settle operation should not attach the prior route's
frame, and an unavailable compatible frame should remain explicitly degraded.

It is not yet a production-accepted guarantee. Production acceptance #13/#14
remains open: rapid/nested modal chains and programmatic/automatic navigation
can still be absent or degraded. Treat those observations as SDK capture gaps,
not as coherent replay evidence.

Pointer work and post-interaction capture are serialized through a controller
queue. An error in one queued task is caught and logged so later taps, scrolls,
and route captures continue.

## Fingerprint schema v6

`tugboatFingerprintSchemaVersion` is currently `7`. Hashes are 16-character
SHA-256 prefixes derived from sorted identity parts. Schema 7 changes are in
[Schema 7: interactive coverage](#schema-7-interactive-coverage-141); the
rules below are the schema 6 rules unless a section says otherwise.

### Canonical target identity

The SDK does not hash the raw Flutter element tree. `AnchorResolver` builds a
frame-scoped token map that:

1. excludes SDK chrome, hidden/offstage/zero-opacity nodes, excluded semantics,
   and content obscured by a blocking overlay;
2. removes a versioned denylist of layout, styling, animation, navigation,
   state-management, and scroll-plumbing wrappers;
3. retains salient and actionable widgets, including actionable widgets such
   as `InkWell` even when their type is otherwise denylisted;
4. assigns same-type sibling ordinals after filtering;
5. gives repeating list and grid items structural `[item:index]` tokens from
   `IndexedSemantics.index`, with traversal order as a fallback;
6. resolves a route key from a non-anonymous route name or a structural
   fallback;
7. caches the token map only for the current Flutter frame so tap resolution,
   state identity, inventories, and screenshot masking can reuse one walk.

A target fingerprint is derived from `routeKey + canonicalPath`. The serialized
`TugboatTargetAnchor` retains the canonical path, widget type, role, normalized
position metadata, enabled/actions metadata, confidence, and compact
fingerprint parts for diagnosis.

`TugboatTag` and a `ValueKey<String>` add a `tagFingerprint` alias. The nearest
one at or above the control wins, and the lookup ends at the SDK's capture root,
so the SDK's own root key and anything above it are never tags. A tag is
transparent to structural identity: adding it does not change the target
fingerprint, and it does not raise confidence. `TugboatSubView` adds a developer-owned
subview label for route-internal state and scroll attribution.

### Locale evidence

The capture root observes the active Flutter `Localizations` locale when the
SDK is installed in the app builder. Sessions and events carry a normalized
locale object with `language`, optional `country` and `script`, and a BCP 47
`tag`. A runtime transition emits `locale_changed` on the evidence stream.

The HTTP collector `session_start` carries the initial active app locale. Later events carry the
current locale directly. `TugboatReplay.setLocale(...)` supports hosts where
the capture root cannot observe `Localizations`.

Atlas may use locale to select labels or group observations. Locale must not
namespace or alter the structural fingerprint.

### State identity

Version 0.8.0 and later do not write state identity. State anchors and
signatures remain internal legacy model data only. New event, inventory,
semantic-map, diagnostic, debug, and provenance JSON omit them. Use route
evidence, target anchors, and frame hashes for raw replay facts.

### Confidence

Confidence is the floor of route and structural evidence:

- `high`: reserved. No target anchor is `high` today: a tag alias does not raise
  confidence, because a `ValueKey<String>` on any ancestor also counts as a tag;
- `medium`: usable structural path and/or structural route fallback;
- `low`: ambiguous structure, bare collapsed item, or insufficient actionable
  evidence.

Confidence is evidence quality, not a uniqueness guarantee. Consumers should
corroborate low-confidence matches rather than treating them as ground truth.

In exploration mode (scene inventory emission on), a `tap` interaction that
carries a `targetFingerprint` also carries the fields below. Production taps keep
the lean envelope (`route` and `targetFingerprint`) and do not carry them:

- `fingerprintConfidence`, as above. An inventory snap and the semantic
  inventory fallback are `low`.
- `fingerprintSource`: how the fingerprint was resolved. `pointerDown` (the
  pointer-down hit test), `snap` (a pathless hit re-anchored to the smallest
  interactive inventory element under the tap) or `inventory` (taken from an
  inventory entry).
- `routeKey`: the resolved route key the fingerprint was hashed under, the same
  value an inventory carries as its `routeKey`. `route` stays the raw origin
  route captured at pointer-down. A consumer joins a tap to an inventory on
  `(routeKey, targetFingerprint)`; `route` alone does not join for dialogs,
  unnamed pages and anonymous sheets, whose route keys are not the raw route.
- `surface`: `{ "kind": ..., "widgetClass": ... }`, the same object the tap's
  inventory carries (see below).

### Surface

Every scene inventory carries `surface`, and exploration `tap` interactions
carry the surface of the inventory they resolved against. Production taps do
not. It is text-free evidence and not part of identity: it is not an input to
any fingerprint, `canonicalPath`, `routeKey`, `inventoryHash` or the inventory
de-duplication key, and it does not change `route`.

- `kind`: `page`, `sheet`, `dialog`, `popup` or `menu`, from the runtime type of
  the route that is current when the inventory is built. `ModalBottomSheetRoute`,
  `CupertinoModalPopupRoute` and `CupertinoSheetRoute` are `sheet`;
  `DialogRoute`, `RawDialogRoute` and `CupertinoDialogRoute` are `dialog`; the
  framework's private popup-menu and dropdown routes are `menu` (matched on the
  type name); any other `PopupRoute` is `popup`; everything else is `page`.
  A `RouteSettings.name` does not change the kind. It is separate from
  `route_change.overlayKind`, which keeps its own closed set. A build that
  obfuscates type names loses the sheet, dialog and menu matches.
- `widgetClass`: for sheets, dialogs and popups, the first app-level widget
  class below the route's overlay host, named as in the elements' canonical
  paths (`DisplayFeatureSubScreen#0/BottomSheet#0/RawGestureDetector#0/MySheet#0/...`
  gives `MySheet`, and honors `widgetNames`). It is read from the retained
  token tree and omitted rather than guessed: when the retained tree has more
  than one root besides the modal barrier or forks above the candidate, when
  the first widget after the host plumbing is a control, a list item, a
  non-composite widget or a known framework content widget (`AlertDialog`,
  `ListTile`, `DraggableScrollableSheet`, ...), and always for `page` and
  `menu`. A private widget class never reaches the canonical path, so a sheet
  built by `_MySheet` has no `widgetClass`; so does an inline builder that
  returns framework widgets, and a sheet over a shell (for example a bottom bar
  outside a nested navigator), where the shell is a second retained root.

Two anonymous sheets with the same type argument share a `routeKey` such as
`ModalBottomSheetRoute<bool>`, so `surface.widgetClass` is what tells them
apart. A host can also give the route a stable, readable key today by naming it:

```dart
showModalBottomSheet<bool>(
  context: context,
  routeSettings: const RouteSettings(name: '/checkout/payment-method'),
  builder: (_) => const PaymentMethodSheet(),
);

showDialog<void>(
  context: context,
  routeSettings: const RouteSettings(name: '/checkout/confirm'),
  builder: (_) => const ConfirmDialog(),
);
```

The name becomes `route` and `routeKey`, unless it starts with `_` or contains
`PageRoute`, `ModalRoute`, `CupertinoPageRoute`, `MaterialPageRoute`,
`DialogRoute` or `PopupRoute` (those still fall back to a structural key). Names
are developer-authored identity strings and must not carry user or tenant data.

### Bounds, viewport and scroll

Every scene inventory element carries `boundsNorm`, and every inventory built in
exploration mode carries `viewport` and, when it has one, `scroll`. All three
are text-free geometry evidence and not part of identity: none is an input to
any fingerprint, `canonicalPath`, `routeKey`, `inventoryHash` or the inventory
de-duplication key. Production taps never compute them.

**`boundsNorm`** is `{ left, top, width, height }` as fractions of the capture
boundary's render box (`TugboatCaptureBoundary`, the SDK's root). It is the
element's **paint bounds** (`RenderBox.paintBounds`, transformed into the
boundary) and not its hit-test box: a control that pads its tap target beyond
its paint box, or hit-tests outside it, is not described by it. It is **not
clipped**: a row half scrolled out of its list, or an element sticking out of
the boundary, keeps coordinates below 0 or above 1. Elements that do not overlap
the boundary at all are not in the inventory.

**`viewport`** says what `boundsNorm` is a fraction of, so a consumer can get
display pixels exactly:

```json
"viewport": {
  "widthPx": 390.0, "heightPx": 770.0,
  "devicePixelRatio": 2.0,
  "boundaryOffset": { "left": 10.0, "top": 30.0 },
  "insets": { "top": 48.0, "bottom": 34.0, "left": 3.0, "right": 5.0 },
  "keyboardInset": 0.0,
  "referenceFrame": "captureBoundary"
}
```

- **Units: every value is in Flutter logical pixels** (device-independent
  pixels, what `RenderBox.size` and `MediaQuery` report), not device pixels,
  despite the `Px` in the names of `widthPx` and `heightPx` (and `offsetPx` and
  `maxExtentPx` below). Multiply by `devicePixelRatio` to get device pixels.
- `widthPx` and `heightPx` are the capture boundary's size, the denominator of
  `boundsNorm`. It can be smaller than the display (system bars, insets, host
  layout around the SDK's root).
- `boundaryOffset` is the boundary's top-left in the Flutter view's logical
  coordinates (`localToGlobal(Offset.zero)`).
- `insets` is the view padding (`FlutterView.viewPadding`: status and navigation
  bars, cutouts), top, bottom, left and right. It is not reduced by the keyboard
  and is read from the view, so a `MediaQuery` override inside the app does not
  change it.
- `keyboardInset` is the bottom view inset (`FlutterView.viewInsets.bottom`), 0
  when no keyboard is shown.
- `referenceFrame` is always `captureBoundary`: the only frame boxes are
  normalized in.
- The object is left out when the boundary has no laid-out `FlutterView` to
  read. A boundary placed under a scaling `Transform` reports its own layout
  size, not the scaled size.

To place an element on a screenshot, scale the box by the frame it is measured
in:

- Of an image of the capture boundary alone: `x = boundsNorm.left *
  imageWidth`, and likewise for `top`, `width`, `height` with the image size.
- Of a screenshot or accessibility dump of the whole Flutter view, in device
  pixels:
  `x = (boundaryOffset.left + boundsNorm.left * widthPx) * devicePixelRatio`
  and `y = (boundaryOffset.top + boundsNorm.top * heightPx) * devicePixelRatio`;
  `width = boundsNorm.width * widthPx * devicePixelRatio` and
  `height = boundsNorm.height * heightPx * devicePixelRatio`. These are pixels
  of the Flutter view. They are display pixels only when the view fills the
  display: the view's own position on the display (split screen, multi-window,
  an embedded view) is not reported.

**`visibleFraction`** (per element) is the share, from 0 to 1 rounded to three
decimals, of the element's paint box that is inside the capture boundary and
not clipped by an ancestor: the box is intersected with the boundary and with
the approximate paint clip (`describeApproximatePaintClip`) of every render
ancestor below the boundary, such as a scrollable's viewport or a `ClipRect`,
then divided by the full box area. It is **omitted when the element is fully
visible** (1.0 after rounding) and absent when it cannot be told. `0.0` is a
real value: an element a list builds in its cache extent, or one wholly
scrolled out of a list that still lies inside the boundary, is listed with
`visibleFraction: 0.0`. Elements are never dropped for being clipped, so the
inventory and its hash are the same with or without the field. Its known
limits:

- It is geometric clipping only. It does not see occlusion by other widgets
  (an app bar or bottom bar over a list, a sheet over a page), opacity, or
  `Offstage` and `Visibility`.
- A rounded or custom clip counts as its bounding rectangle, and a rotated clip
  as its axis-aligned box.
- An element that has no paint area or a clip that throws is treated as
  unclipped.
- An entry that the exploration tap path adds to an inventory only because the
  tap landed on it has no `visibleFraction`.

**`scroll`** is `{ "offsetPx": ..., "maxExtentPx": ..., "axis": "vertical" }`,
the position of the inventory's **primary vertical scrollable**: among the
vertical `Scrollable`s in the retained tree of the current surface, the one
whose viewport shows the largest area inside the capture boundary (ties go to
the first in tree order). `offsetPx` is `ScrollPosition.pixels` and
`maxExtentPx` is `ScrollPosition.maxScrollExtent`, both logical pixels and equal
to the app's `ScrollController` values; `maxExtentPx` is left out for an
unbounded list. Horizontal scrollables and scrollables inside a text field
(`EditableText`) never count, and `scroll` is omitted when none qualifies. A
nested scroll view that is not the largest is not reported, reverse lists
report the raw `pixels`, and a page with two equally large vertical lists
reports the first.

`viewport` and `scroll` are not part of the inventory de-duplication key
(`routeKey`, `inventoryHash` and the scroll context). Two inventories of the
same route and hash at different scroll offsets or insets are emitted only when
a scroll event makes the scroll context differ.

### Loading and placeholders

Exploration inventories say when a surface is still loading, so a consumer can
tell a loading frame from a loaded one. Like the bounds evidence above, this is
structural, text-free, and never part of an identity:

- **`loading`** on every inventory built in exploration mode:
  `{ progressIndicators, placeholders, busyControls }`.
  - `progressIndicators` counts `ProgressIndicator` widgets (Circular, Linear,
    Refresh) and `CupertinoActivityIndicator` in the capture boundary's tree,
    skipping hidden subtrees.
  - `placeholders` counts inventory elements beneath a placeholder ancestor.
  - `busyControls` counts distinct interactive entries beneath an
    `AbsorbPointer(absorbing: true)` or `IgnorePointer(ignoring: true)`.
- **`placeholder: true`** on an element beneath a placeholder ancestor, omitted
  otherwise.

A placeholder ancestor is a widget whose runtime type name contains
`Shimmer`, `Skeleton`, `Placeholder` or `Redacted` (case-sensitive), or a
`TugboatLoading` marker. Flutter's own debug `Placeholder` matches the
`Placeholder` fragment: it is a placeholder by definition, and it only appears
in captures where an app uses it as a stub.

`TugboatLoading({required child})` is for hosts whose skeleton widgets have
other names. It is transparent: it adds no canonical path segment and changes
no fingerprint, `routeKey`, `surface` or `inventoryHash`, so wrapping a control
in it leaves that control's identity unchanged. It is exported from
`package:tugboat/tugboat.dart`.

The ancestor walk is bounded at the capture root, and the progress-indicator
walk runs only when an exploration inventory is built. Production taps compute
none of it. An exploration tap whose target is injected into an inventory that
had no elements gets a `loading` with only `progressIndicators` set, and its
injected entry is never a placeholder.

### Settled re-sample and `trigger`

Every scene inventory carries `trigger`, the reason it was taken:

| `trigger` | Taken when |
| --- | --- |
| `initial` | the first capture of a session |
| `resume` | the app returns to the foreground |
| `route` | the visible route changes |
| `tap` | a tap (and a gesture completion, which reads as a tap) |
| `scroll` | scroll start, update or end |
| `settled` | the settled re-sample below |
| `manual` | a manual capture |

`trigger` is not part of `inventoryHash`, `routeKey` or the emission
de-duplication key.

**Settled re-sample** is on by default in exploration mode (it needs
`emitSceneInventory: true`). It catches a page that loads after its first
inventory (a `FutureBuilder`, a paginated list), which otherwise shows only its
placeholder layout until the next tap or route change. It is off in production,
where nothing runs.

To turn it off in exploration, set `resampleSettledInventory: false` on
`TugboatReplayConfig`. With it off, a tap, scroll and route flow emits the same
inventories as before this change.

After an inventory is emitted for a route, a watch is armed. Each frame drawn
while armed pushes back a 400 ms quiet window. When the page has been quiet for
the window, the inventory is rebuilt and emitted with `trigger: "settled"` only
if its structural signature differs from the last emitted inventory for that
route. The signature is `inventoryHash`, the element count, and each element's
`boundsNorm` quantised to a 2% grid, joined and hashed. A rebuild that finds no
change stops the watch.

- Settled emissions do not write to the emission de-duplication set. They
  compare against their own per-route signature, so existing triggers are
  unaffected.
- At most five settled inventories per route key per session. A session-wide
  cap of 40 settled inventories and 200 rebuilds bounds the work further.
- The watch stops on route change, pause, lifecycle pause, session end and
  dispose. It also stops after five seconds armed, checked on frames.
- Idle pages, blinking cursors and looping animations that do not move
  anything produce no extra events. A page that keeps moving stops at the cap.
- No timer repeats forever: the quiet timer exists only after a drawn frame,
  and an idle page leaves none pending.

### What is and is not retained

The structural pipeline does not use or serialize arbitrary `Text`,
accessibility, tooltip, or icon-label strings as target identity.

Developer-authored identity strings can still be emitted:

- named routes;
- `TugboatTag.id` in target fingerprint parts, plus its hash alias;
- `TugboatSubView.label`;
- widget type names or configured `widgetNames` replacements;
- canonical structural paths.

Bounds, pointer coordinates, scroll metrics, and masked screenshot pixels are
also capture data. Apps must treat tags, route names, and subview labels as
telemetry and avoid putting user data in them.

### Schema 7: interactive coverage (#141)

Schema 7 is one bump for #137, #139 and #141. A fingerprint is still the hash
of `path` and `routeKey`. What moves, exhaustively:

- **Overlay paths (#139).** A control under `DisplayFeatureSubScreen`, a
  `ModalBarrier` or an `AnimatedModalBarrier` (sheets and dialogs) loses that
  segment's ordinal. Popup menus, dropdowns and custom `PopupRoute`s whose
  paths have no such segment do not move.
- **Route keys (#137, #141).** An anonymous sheet or dialog with a nameable
  class is keyed `sheet:<WidgetClass>` or `dialog:<WidgetClass>`. A `struct:`
  key is hashed over ordinal-free paths that include disabled controls and
  low-level controls of their own, so it moves for an anonymous dialog (its
  paths had `DisplayFeatureSubScreen#N`) and for an anonymous route with a
  disabled or low-level control. Every fingerprint on a route whose key moved moves. An
  anonymous page with only enabled schema 6 controls keeps its key.
- **Theme wrappers (#139).** Controls under a `ListTileTheme` or `SwitchTheme`
  move, including the `ListTileTheme` that `Drawer` and `ExpansionTile`
  insert. A later same-type sibling of a wrapped control is renumbered
  (`ListTile#0` becomes `ListTile#1`), and the wrapped control can take that
  sibling's schema 6 fingerprint.
- **Disabled controls (#141).** An `InkWell` without `onTap` keeps its path
  segment, so a control inside one (a `Switch` trailing a `ListTile` with no
  callbacks) moves. A disabled control takes its enabled twin's fingerprint, so
  a disabled `TextField` (schema 6: `.../TextField#0`) moves to its enabled
  path, and a production tap on a disabled control carries that fingerprint.

Nothing else moves: an enabled control on a named route, with no overlay host,
theme wrapper or bare `InkWell` above it, keeps its schema 6 fingerprint, and
so does its production tap.

- **Roles.** `Semantics` with `onTap` or `onLongPress`, a `Listener` with
  `onPointerUp`, and a `RawGestureDetector` with a `TapGestureRecognizer` or
  `LongPressGestureRecognizer` are low-level `button` roles. Such a widget is a
  control of its own only outside every control and around no schema 6 role:
  inside a control it is the control's plumbing, and around one (a pointer-up
  `Listener` around a button) it is a layer of that control, so neither adds an
  entry or a path segment. A control of its own gets a path for itself
  (`.../Semantics#0`) but is not a parent in any other path, so the content
  below it keeps its schema 6 path. The `Listener` that `Navigator` builds and the
  dismiss `Semantics` of a `ModalBarrier` are never controls. A `MouseRegion`
  is never a role. Framework widgets that build a low-level role around no
  control are reported: a bottom sheet's drag handle, a `SelectionArea` around
  plain text.
- **Disabled controls** are listed with `enabled: false` and no tap action. They
  are never tap targets (`enabled != false` gates tap selection and the
  pathless snap), and exploration taps on them stay unresolved as before.
  For a control with a disabled state (Material and Cupertino buttons,
  toggles, chips, sliders, dropdowns, text fields, `ListTile.enabled`),
  toggling it changes only `enabled` and `actions`: not its fingerprint, the
  fingerprints below it, or the route key.
- **Identity element.** As in schema 6, the identity of a hit is the innermost
  role on its path, scrollables included (a `TextField`'s inner scrollable).
  Schema 7 adds low-level controls of their own, and a `GestureDetector`
  without a tap inside a disabled control, which stands in for its enabled
  twin's tap detector. An `InkWell` or `InkResponse` without `onTap` is not an
  identity. When the hit cannot reach inside a disabled control (a disabled
  `TextField` ignores pointers), its identity is the innermost control below
  it if those form one chain of disabled controls and scrollables.
- **Tag.** An inventory entry carries `tag` when an explicit `TugboatTag` sits
  at or above its element. It is the developer's id, not a `ValueKey`, and it is
  never hash input.
- **Not reported.** `hitTestBounds` is not reported, so inventory boxes are paint
  bounds. A `ListTile` with no callbacks is not listed: Flutter treats it as not
  interactive, not as disabled (`ListTile.enabled` is the disabled state). A
  pan-only `GestureDetector`, a `Listener` with only pointer-down, and a
  `Semantics` with a label but no tap action are not controls.
- **Aliases.** For one release an exploration inventory entry lists, in
  `aliases`, the schema 6 fingerprints of the same control, computed from a
  second, schema 6 walk of the same tree, whenever schema 6 reported that
  control. A schema 6 fingerprint is left out when it already names something
  else in the same inventory (an entry's fingerprint or layer alias) or when two
  entries claim it: a wrong alias is worse than none, and an alias must never
  redirect a tap to another control. `aliases` also lists the entry's layers
  (schema 7 structural paths), as before. Inventories are emitted again when
  only their aliases changed, so a sheet stacked on its own copy delivers its
  `DisplayFeatureSubScreen#1` fingerprints. Production taps neither carry nor
  use schema 6 aliases.
- **Overlay hosts (#139).** A sheet opened on top of another has the
  fingerprints of the same control as the sheet opened alone (schema 6 gave
  `DisplayFeatureSubScreen#0` and `#1`). Different sheet classes stay apart
  through their class segment and route key.
- **Theme wrappers (#139).** Only `ListTileTheme` and `SwitchTheme` are
  transparent (`_canonicalWrapperDenylist`): wrappers an app puts around its
  own controls, with no render object, reproduced as splitting one control
  into two schema 6 fingerprints. Themes the framework inserts itself
  (`IconButtonTheme` in an `AppBar` toolbar, a `ListTile` trailing slot or a
  popup menu) are always present, so they never split a fingerprint and stay
  in the path.
- **List positions (#139).** An entry whose canonical path has an `[item:N]`
  segment carries `positional: true`. The fingerprint names a position in a
  list, so another item at the same index, in another tab or state, shares it.
  No key value enters a path: `ValueKey` and `ObjectKey` values are never hash
  input.
- **Sheet and dialog route keys (#137).** The kind comes from the route's type
  name, so a sheet's own button still resolves to its sheet key after a
  navigating tap, and production and exploration taps compute the same key.
  The class is still found while transient overlay entries show above the
  route (a text selection toolbar and handles), so the key does not flip. A
  host-named route (`RouteSettings(name: ...)`) keeps its name, and an inline
  builder with no nameable class keeps the runtime type (sheet) or `struct:`
  key (dialog).
- **Known limits.** Two sheets or dialogs with no nameable class and the same
  structure still collide; name the class or pass `RouteSettings(name: ...)`. A
  custom `PopupRoute` cannot be told from its type name, so it keeps its
  `struct:` key. A disabled control whose inner controls fork (a disabled
  `TextField` with a suffix button) keeps its own path, so enabling it changes
  its fingerprint. A `GestureDetector`, `InkWell`, `ListTile` or tap
  `Semantics` has no disabled state: with its callback `null` it is not a
  control, so toggling the callback adds or removes its entry and changes an
  anonymous route's `struct:` key (and every fingerprint on that route).
- **Golden.** `test/fingerprint_golden_test.dart` pins fingerprints, route keys,
  aliases and the schema version for a fixture tree. Any change to them fails
  that test: bump `tugboatFingerprintSchemaVersion` and update the golden in
  the same change.

## Screenshot pipeline

Screenshots are taken from the SDK `RepaintBoundary` at the configured pixel
ratio (default `0.75`). Optional `captureMaxWidth` / `captureMaxHeight` bounds
lower the effective ratio before readback while preserving aspect ratio; when
the rolling screenshot budget is degraded, `degradedCaptureScale` (default
`0.67`) lowers it again. This reduces both GPU readback dimensions and the raw
RGBA allocation rather than only shrinking the final JPEG. Before JPEG encoding
the SDK collects mask rectangles using the shared anchor resolver and applies
them as opaque fills on the RGBA buffer inside the encode isolate (avoiding a
second full-size GPU raster).

The default mask policy covers all rendered text, editable inputs, and images.
Hosts can select a stricter or narrower explicit mask policy. Evidence
capabilities never change the mask.

The public mask levels are `explicitOnly`, `allTextAndMedia`, `allText`,
`allTextExceptActionable`, and `sensitiveInputsOnly`.

Capture computes a 9x8 perceptual dHash from the masked RGBA buffer inside the
encode isolate and skips JPEG encoding when the Hamming distance to the
baseline hash is at most 2 bits (tolerating minor anti-alias shimmer). The
baseline is the hash of the frame that is actually referenced: a coalesced
candidate never replaces it, so small successive changes cannot drift away
from the recorded frame. The perceptual skip is offered only while the
capture's visible-structure signature matches the referenced frame's. The
signature is computed from the same frame-scoped token map as masking:
retained structural tokens, control role, enabled state, and value (toggles,
radios, chip selection, sliders), blocking-overlay presence, and rounded bounds of text, editable, and image boxes. It reads no
text or pixels and is never serialized. A structure change, such as masked
error text appearing, therefore always encodes a frame. SHA-256 content
hashing then deduplicates encoded frames with identical bytes. Capture requests are
serialized and compatible non-interaction requests can coalesce. When the
capture subtree's paint signature has not
changed since the last accepted frame (outer capture boundary paint generation
plus nested [RepaintBoundary] layer/picture identity), the controller skips the
entire GPU readback/encode path and reuses a compatible frame. Scroll metrics
are sampled independently from screenshots. In-motion visual checkpoints are
disabled by default and, when explicitly enabled, drop with
`capture_pressure_drop` rather than queue behind active screenshot work. A
pointer-linked scroll can request one fresh observation after an optional
`scrollEndCaptureDelay`; that idle wait runs outside the controller queue so it
does not block route or pointer settlement. Each other completed interaction
requests a post-interaction observation. A fresh route capture can satisfy it
without asserting that the interaction caused the route. `afterFrame` therefore
means "observed later," not "action result."

Pointer-down cancels a pending deferred scroll-end capture before Flutter sends
the next `ScrollStart`. The SDK keeps the completed scroll metrics and publishes
the old interaction without a stale after-frame. Tap-only target, inventory,
and viewport-semantic resolution runs at pointer-up. This keeps tap evidence
while removing that work from the scroll input path.

Pointer-down also keeps one plain hit test of the pressed point (no token-map
walk). With global pointer capture the SDK reads pointer-up after the app's tap
recognizer, and a recognizer that already won its arena runs `onTap` first. When
that handler pushes or pops a route, the Navigator absorbs pointers at once, so
a fresh hit test can no longer reach the old screen. When the pointer-up hit test
finds no actionable target with a canonical path, the target is resolved from
the kept pointer-down hit path instead. That path also wins when the fresh hit test
has no canonical path and the kept one has a path but no role, as for a control
whose button sits under `ExcludeSemantics`. A tap that already resolves is
unchanged, and fingerprints are the same element's fingerprints either way.

A control that stays mounted while the app navigates (a persistent bottom bar
outside the `Navigator`) is not absorbed, so its pointer-up hit test succeeds
but runs under the destination route. When the route changed since pointer-down,
a usable pointer-down hit path therefore wins over the fresh hit test, and the
fingerprint belongs to the route the tap happened on. Exploration
mode resolves at pointer-down and has no such window.

Mask fills, dHash, JPEG encoding, and content hashing run on a persistent
background isolate after a full-frame RGBA readback on the UI isolate. RGBA
bytes are packed into [TransferableTypedData] for the worker: packing still
copies once on the UI isolate, but the worker materializes the buffer without
a second full-frame copy (unlike a plain isolate/`compute` send). Platform
views, video textures, maps, and native overlays may be absent or incomplete
in repaint-boundary output.

### Capture stage clocks

The Dart clock names do not match processing stages. Native capture must emit
the stages in `docs/performance/cpu-capture-baseline.md`, not impersonate
these fields.

| Dart field | What it actually measures |
| --- | --- |
| `ScreenshotCaptureAttempt.frameWaitMicros` | Wait for a usable frame before readback |
| `ScreenshotCaptureResult.captureMicros` | `RenderRepaintBoundary.toImage` only |
| `ScreenshotCaptureResult.maskMicros` | Mask-rect collection and scale into pixel space. The opaque RGBA fill is not included. |
| `ScreenshotCaptureResult.encodeMicros` | `ui.Image.toByteData(rawRgba)` plus isolate mask fill, dHash, optional JPEG, and SHA-256 |
| `TugboatFrame.captureMicros` | Sum of frame wait + the three result clocks |
| `TugboatFrame.requestedBackend` / `resolvedBackend` | Closed backend names for the host request and the JPEG producer. `fallbackReason` is present only after a native-to-Flutter retry. |

Paint-generation reuse records zeros and skips GPU readback. A dHash skip
still performs readback, fill, and hash; JPEG and SHA-256 are omitted, but
`encodeMicros` still includes the work that ran.

`TugboatScreenshotBudgetTracker.record` accepts `encodedBytes` and discards
it. JPEG size is stored only as `TugboatFrame.byteLength`. Test ceilings for
the rolling budget live in
`sdks/flutter/packages/tugboat/benchmark/screenshot_budget_baseline.dart`; they are not
device-tier gates.

## Viewport semantics

`viewportSemanticMode` resolves with `emitViewportSemanticMap`:

| Mode | Engine | Emits map events | Debug logs |
| --- | --- | --- | --- |
| `off` | no | no | no |
| `tapResolutionOnly` | yes while enabled | no | no |
| `full` | yes | when capability is true | no |
| `fullWithDebugLogs` | yes | when capability is true | when capability is true |

The SDK holds a persistent Flutter `SemanticsHandle` only while semantic-map
emission is enabled. It can still build maps locally for tap resolution.
Emitted maps are bounded by
`viewportSemanticMapMaxNodes` (default `120`) and
`viewportSemanticMapMaxBytes` (default `48000`).

Scene inventory and viewport semantic maps are related but distinct:
inventories enumerate actionable structural controls; semantic maps add
viewport-level semantic resolution and scroll context. Tap resolution can use
semantics without emitting map events.

## Transport boundary

The controller fans evidence to the built-in HTTP sink configured by
`collector`, plus any registered custom sinks.

The sink hub isolates synchronous and asynchronous sink failures. Capture
remains authoritative in memory. Public `TugboatCaptureSinkFactory` registration
is supported via `TugboatReplayConfig.sinkFactories`; the built-in HTTP sink
remains available through `collector`.

HTTP delivery queues remain process-local. See
[Collector integration](../integration/collector.md) for the wire behavior.

## Lifecycle

- `wrapApp` always mounts a lightweight activation gate (unless disabled).
- Session start waits for a non-zero repaint-boundary or media-query viewport.
- `paused` and `hidden` schedule a sink flush after 500 ms.
- `resumed` cancels a pending background flush.
- `detached` ends the session.
- Wrapper disposal/deactivation emits `session_end` once, asks sinks to end,
  then disposes them asynchronously.
- The HTTP sink flushes on batch size, periodically, and before session end.

## Verified implementation coverage

The package test suite covers deterministic fingerprints, list-length and
scroll stability, locale-independent structural item positions, tag
transparency, route separation, modal/visibility filtering, generated widget
names, actionable `InkWell` paths, dormant activation without rebuild,
screenshot mask defaults, route payloads, scroll/swipe attribution, schema-v10
JSON round trips and rejection of unsupported schema versions, semantic modes,
sink factories/mailboxes, health diagnostics, lifecycle ordering, retry bounds,
and stale session/frame protection.

These tests prove repository behavior; they do not replace validation on real,
obfuscated release builds or app-specific navigator/overlay structures.

## Remaining gaps and follow-ups

### 1. Release-build identity matrix

Continue exercising `--obfuscate`, nested navigators, platform views, and
overlay-heavy screens on representative devices. Obfuscated builds without
generated `widgetNames` must fail the compatibility gate rather than invent
cross-build equivalence.

### 2. Screenshot budget device baselines

Unit thresholds live in `benchmark/screenshot_budget_baseline.dart`. The default
rolling budget is 60 ms per 5 s window so eligible captures skip under load
sooner now that paint-generation / dHash coalesce replace the old post-capture
state-signature short circuit. Record multi-tier device measurements before
enabling more aggressive degradation in normal app capture.

### 3. Deferred capture surfaces

Native platform-view adapters, video texture capture, and iOS background upload
services remain out of scope.

### 5. Cross-build compatibility outside the SDK

The SDK correctly emits build metadata plus fingerprint schema version, but it
does not decide when two identities from different APKs are equivalent. The
enhancement/Atlas API should own lookup, confidence, and remap semantics without
weakening the SDK's build-scoped identity invariant.
