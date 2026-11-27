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

Capture occurrence IDs are opaque strings. Each new session uses
`session-<UUIDv4>` and each controller event uses `event-<UUIDv4>`, with
lowercase canonical UUIDs generated independently on the device. Collector
diagnostics use their component prefix and a UUIDv4. Older SDKs used
`session-<epoch microseconds>` and `event-<counter>`. The native Android and
Swift SDKs send the UUID form too (the shared session engine derives it from
host-supplied entropy; `conformance/capture_id_vectors.json` pins the format
for the engine and Dart). Preserve either shape
verbatim when joining related events. Use `startedAt`, `atMs` and
`triggeredAt` for timing. Capture IDs never enter a fingerprint.

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

A capture session lasts one wrapper lifetime. Only `detached`, wrapper
disposal, or deactivation ends it. Backgrounding (`paused` or `hidden`) does
not end the session: it cancels in-flight capture work (a route or tap capture
that has not settled is dropped), flushes pending delivery, and suspends
capture until `resumed`, which forces a `lifecycle` frame capture in the same
session. There is no inactivity rollover, by design: time in the
background or idle never starts a new session. The `app_backgrounded` and
`app_foregrounded` events mark the boundaries of background time, so consumers
and backends that measure session duration or engagement should discount the
time between them. Flutter does not reliably deliver `detached`; the
operating system can terminate a backgrounded process without it. Expect long
sessions that span many foreground visits, and sessions that end without
`session_end`. Nothing restarts a session after `detached`: if the wrapper
survives it (for example an Android host that keeps a cached engine across
activity destruction) and the app later resumes, the SDK still records
`app_foregrounded` and the `lifecycle` frame under the ended session, after its
`session_end`. Consumers should not treat `session_end` as the last event of a
session.

The native Android SDK (`tugboat-android`, unpublished) follows the same
contract: `TugboatConfig.enabled` (default `false`), `Tugboat.activate` /
`deactivate`, and the same four lifecycle states. Its `stop()` is not
`disabled`: it ends the session and forgets the config and any activation
request.

Identity fields (session schema **v10** only):

- `activationRequestId` — host request correlation
- `captureSessionId` — SDK-emitted session (`session.id`)
- `collectorSessionId` — HTTP transport ID after accept
- `explorationRunId` — exploration control plane
- `appInfo.installationId` (collector `session_start`) — one id per app
  install: an SDK-minted UUID persisted on first launch (seeded from
  `identifierForVendor` on iOS), or the host's own id when it passes one.
  Sent since 0.11.5; earlier sessions carry none. See
  [collector integration](../integration/collector.md#installation-id).

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

While a transition runs, the current route is already the destination but the
tree still shows the departing route (or the pushed route is not built yet).
So no scene inventory is emitted in that window: a capture request the
transition suppresses (an input observation after system back, a focus change
as a dialog opens) and a scroll inventory (a marquee on the page below) emit
none, and the route capture emits the destination's inventory once the
transition settles. Before, such inventories listed the departing route's
controls under the destination's route key.

"Settles" means the transition has run, not that its duration has passed.
The route capture is due a transition duration after the Navigator callback,
but the animation runs on frames and can lag behind (jank, fake time), and a
covered route goes offstage only in the frame after its cover's animation
ends. So once due, the capture, and the end of the transition window for
every other trigger, goes at once only when no animation of the routes the
change moves runs and no frame is due; otherwise it waits until two frames
have passed with none of them running, bounded by the route barrier timeout.
Before, the `route` inventory of a pushed unnamed page could still include
the page below it, and a `struct:` route key
computed over both pages, which that page's first taps then carried while
every later inventory of the page had another key.

It is not yet a production-accepted guarantee. Production acceptance #13/#14
remains open: rapid/nested modal chains and programmatic/automatic navigation
can still be absent or degraded. Treat those observations as SDK capture gaps,
not as coherent replay evidence.

Pointer work and post-interaction capture are serialized through a controller
queue. An error in one queued task is caught and logged so later taps, scrolls,
and route captures continue.

A programmatic scroll (one no pointer drives: `jumpTo`, an auto-scrolling
marquee) captures no frame, so it builds no scene inventory of its own (see
[Re-sample](#re-sample-moments-plus-novelty-and-trigger)); its scroll-start,
scroll-update and scroll-end inventories are built for the viewport semantic
map only, and only once the render tree is laid out. When a frame is under
way before its post-frame callbacks, or one is scheduled, the inventory waits for the next
post-frame callback and is dropped if the session, capture lifecycle or route
changed meanwhile; otherwise it is built at once, as before. Building it with
layout dirty hit-tested stale boxes and tripped `!debugNeedsLayout` in
`RenderFractionalTranslation`. A scroll a pointer drives keeps its inventories
at once, and a scroll inventory that fails is logged and never reaches the
host's scroll notification. A scroll notification carries no pointer, so a
programmatic scroll that starts while any finger is down counts as
pointer-driven: its inventory is still built at once, and with layout dirty
it can fail (logged, inventory lost) or read stale boxes in release. Production builds no scroll inventory and
schedules nothing.

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

`TugboatTag` (or the `.tugboatTag(id)` extension) and a `ValueKey<String>`
add a `tagFingerprint` alias. The nearest one at or above the control wins,
and the lookup ends at the SDK's capture root, so the SDK's own root key and
anything above it are never tags. A tag is transparent to structural identity:
adding it does not change the target fingerprint, and it does not raise
confidence. With `.tugboatTag(id, accessibility: true)` the id is also
published as a `Semantics` identifier (platform accessibility identifier). The
SDK's `Semantics` node is already excluded from structural identity, and the
identifier is not part of the fingerprint or state signature. The option is
off by default. Enable it on a single control, not on a container: on a
container the identifier sits above the whole subtree, so it does not identify
the controls inside it. On Material buttons (`ButtonStyleButton` and Material 3
`IconButton`) the identifier sits on a label-less parent node with the button's
bounds rather than on the labelled button. Screen-reader focus is unchanged,
id-based lookups work, and role-based button queries do not match.
`TugboatSubView` (or `.tugboatSubView(label)`) adds a developer-owned subview
label for route-internal state and scroll attribution. `.tugboatSensitive()` is
equivalent to `TugboatSensitive`.

The native sections below still raise confidence to `high` for an alias. Since
Flutter 0.12.x a tag no longer does; aligning the native SDKs is tracked with
the 0.12.x catch-up.

### Android Views canonicalization

The native Android SDK (`tugboat-android`, ADR 0009, not yet published)
builds the same parts for Android Views. The hash, `fingerprintParts`, and
confidence tiers are shared; anchors add `toolkit: "view"`, which is not a
hash input.

- **Token.** The nearest platform class (`android.*`, which R8 never renames)
  in the view's superclass chain, plus `#<resource entry name>` when the view
  has a resource id. A custom `MyButton : MaterialButton : Button` is
  `Button`; androidx classes are library code, so a `RecyclerView` is
  `ViewGroup`.
- **Segments.** `Token#<ordinal>` without an id, `Token#<entry>` with one
  (`Token#<entry>#<ordinal>` when the same id repeats). Ordinals count
  same-token siblings after filtering.
- **Excluded.** Views that are not `VISIBLE`, have zero alpha or zero size,
  or are SDK-owned, with their subtrees.
- **Kept.** Actionable views (clickable, long- or context-clickable,
  checkable, editable), views with a resource id, scrollables, and maskable
  leaves (text, image, web, video, surface, texture). Everything else
  collapses. Accessibility actions are not inspected.
- **Lists.** `RecyclerView` children add `[item:<adapter position>]`;
  `AbsListView` children add `[item:<first visible position + index>]`.
- **Route key.** Inside a shown fragment: the Jetpack Navigation destination
  current when it was shown, else its tag, else its class name (`low`
  confidence, because R8 may rename it); paths start below the fragment's
  view. Elsewhere: the activity's current destination, else the activity
  class name; paths start below `android.R.id.content`. A destination is
  its route pattern without arguments (`checkout/{id}?step={s}` is
  `checkout`), else its id's entry name; Compose anchors and navigation
  facts use the same key.
- **Alias.** The `tugboatTag` view tag, else the resource entry name when no
  other view under the route root has the same id. It gives `tagFingerprint`
  and does not change the structural fingerprint. UI test tools read the
  same `android:id` as the resource-id, so `View.tugboatTag` has no
  accessibility option and the SDK installs no `AccessibilityDelegate`.
- **Confidence.** The floor of the route's and the path's. The path is `high`
  with an alias, `medium` when the target has its own id or sits in a list
  item, and `low` otherwise.
- **Obfuscated resource names.** When the SDK's own probe id does not resolve
  to its own entry name, resource ids are dropped from tokens.
- **Coordinates.** Pointer positions and scroll offsets are logical pixels
  (dp): physical pixels divided by display density.

### Compose canonicalization

The Compose adapter (`tugboat-compose`, ADR 0009, not yet published) reads
Compose content for the Views adapter, which hashes it. Anchors add
`toolkit: "compose"`, which is not a hash input.

- **Source.** The merged semantics tree of each `AndroidComposeView`,
  through `ViewRootForTest.semanticsOwner` reached with `runCatching`.
- **Token.** The `Role` (`Button`, `Checkbox`, `Switch`, `RadioButton`,
  `Tab`, `Image`, `DropdownList`), then `TextField` for editable nodes,
  `Scrollable` for nodes with a scroll range, and `Node` otherwise.
- **Segments.** `Token#<ordinal>`; ordinals count same-token siblings after
  filtering, in paint order.
- **Excluded.** Unplaced or zero-size nodes, with their subtrees.
- **Kept.** Actionable (click, long click, toggle, progress), editable,
  scrollable, maskable (text, editable text, `Role.Image`, content
  description), or tagged nodes. Everything else collapses.
- **Host path.** The `AndroidComposeView` is a kept view with the token
  `Compose`; the full path is the host's Views path followed by the node
  path (`Compose#0/Button#1`), so it is unique with several hosts.
- **Lists.** A child of a node with `CollectionInfo` adds
  `[item:<CollectionItemInfo index>]`. Without it (lazy layouts set none)
  it adds `[item]`: the order on screen changes as the list scrolls, so it
  is not identity, and such rows share one fingerprint at `low` confidence.
- **Route key.** The host view's Views route (above): the same
  `trackNavigation` route pattern without arguments, else the hosting
  activity (or the fragment around a `ComposeView`).
- **Alias.** `Modifier.tugboatTag`, then `testTag`. Both are `high`
  confidence and do not change the structural fingerprint.
  `tugboatTag(tag, accessibility = true)` also sets `testTag(tag)` for UI
  tests; the anchor and the structure signature are the same as without it.
  A node keeps one `testTag` (the first in the modifier chain), so the
  option is off by default; the alias is the `tugboatTag` either way.
- **Confidence.** As for Views: `high` with an alias, `medium` in an
  indexed list item, `low` otherwise, floored by the route.
- **Semantics unavailable.** The anchor is the host view's identity
  (`Compose#0`, `toolkit` still `compose`) and the whole frame is masked.

### SwiftUI canonicalization

The native Apple SDK (module `Tugboat`, ADR 0009, not yet published) builds
the same parts for SwiftUI. The hash, `fingerprintParts`, and confidence tiers
are shared; anchors add `toolkit: "swiftui"`, which is not a hash input.
Without VoiceOver the in-process accessibility tree of a SwiftUI hosting view
is empty, and SwiftUI text, images and buttons are not UIKit views, so
identity comes from developer tags and from the UIKit views SwiftUI does use,
plus, only when the app opts in, the accessibility tree (ADR 0010).

- **Tags first.** `.tugboatTag("checkout")` places an invisible,
  non-interactive marker view behind its content. A tap inside the smallest
  tagged frame at the point, in the same window and hosting root as the hit
  view, resolves to that tag: `tagFingerprint` (`routeKey` + `tag`), `high`
  confidence, `widgetType: SwiftUIView`, and no `role`, `actions` or
  `enabled`. A screen under a sheet never wins. The tag is transparent to
  structural identity. `.tugboatTag("checkout", accessibility: true)` (off by
  default) also sets the tag as the tagged content's
  `accessibilityIdentifier`, never the marker's. A tagged tap never reads
  accessibility identifiers, so the target fingerprint, canonical path, tag
  alias and structure signature are the same with or without it. On a
  container SwiftUI gives every element inside the identifier. With two
  identifiers on one view the outermost wins, so an app identifier applied
  before `.tugboatTag` is replaced by the tag and one applied after it wins.
- **UIKit roles.** Otherwise the target is the nearest view, from UIKit
  hit-testing at the point, with a role: `TextField` (`UITextField`,
  `UITextView`), a list cell, `Scrollable` (`UIScrollView`), or
  `Representable` (a `UIViewRepresentable` host, or an app-defined view inside
  a hosting view). A tap on bare SwiftUI drawing without a tag has no target
  (`no_actionable_candidate`).
- **Accessibility tree (opt-in, ADR 0010).**
  `TugboatConfig.swiftUIAccessibilityIdentity` is `.off` by default, and
  then the tree is never built or read, even with VoiceOver running. With
  `.on`, or `.sampled(rate:)` drawn in once per process launch, and only on
  a verified iOS major (iOS 18; elsewhere as `.off`), a tap that has no
  target or resolves to a list cell or scroll view asks the tree for the
  smallest element whose frame contains the point. The descent enters only
  containers whose frame contains the point and reads at most 256
  elements. Only `accessibilityIdentifier` (tested for being set),
  `accessibilityTraits` and frames are read; labels and values never are.
  The path gets `AXIdentified#<k>` for an element with an identifier, else
  `AX<Role>#<k>` with `role` from the traits (`switch`, `button`, `link`,
  `textField`, `adjustable`, `image`, `header`; `AXElement` and no `role`
  otherwise). `widgetType` is `SwiftUIView`, with no `actions` or
  `enabled`; confidence follows the path rules (`low`, `medium` in a list
  cell). The identifier's value is never sent and is not an alias. The
  first qualifying tap of a process resolves as with the option off and
  schedules `accessibilityActivate()` on its hosting view for the main
  queue's next turn (skipped when VoiceOver or Switch Control runs); the
  tree's cost then lasts for the process. Tagged, text-input, UIKit-control
  and representable taps never ask. Sampled-in processes give some taps a
  deeper path, so a different fingerprint: an identity-source change.
- **Segments.** `Token#<ordinal>` for each role view between the route root
  and the target, plus `Host#<ordinal>` for nested hosting views. Ordinals
  count same-token siblings after filtering. Hidden, transparent and
  zero-size views are excluded with their subtrees. Visible text, images and
  layer classes never enter identity.
- **Lists.** A `List` cell (`UICollectionView` on iOS 16+, `UITableView` on
  iOS 15) adds `[item:<section>.<row>]` from its index path; a tapped cell
  ends with `Cell#0`.
- **Route key.** The name of the `.tugboatScreen` on top of the visible
  chain of navigators, else `host:<16 hex>`, the identity hash of the
  nearest hosting controller's Swift type name (`medium`; `low` when the
  type contains `AnyView`, since type-erased roots share one key), else
  `swiftui:window` (`low`).
  Paths start below that hosting controller's view. Screens belong to the
  root navigator `swiftui-screens` unless a `.tugboatNavigator(name)`
  encloses them (`swiftui-screens/<name>`, nested in the enclosing
  navigator and hosted by the `.tugboatScreen` around it). The visible
  chain runs from the root through the child navigator, hosted by the top
  screen or by no screen, whose top screen is on screen (between
  `onAppear` and `onDisappear`), the most recently appeared where several
  are (a child with no host only when its appearance is newer than its
  parent's own); its deepest top screen is the key, the route the last
  `session_start` seed ends on. A tab switch changes the key to the shown
  tab's top without a navigation fact. A sheet's screen keys the targets
  inside the sheet, whether it is a route on the presenting navigator or
  the root of the sheet's own navigator. `presentation:` sets the route's
  `overlayKind`, never the route key.
- **Confidence.** The floor of the route's and the path's. The path is
  `high` with a tag, `medium` inside a list cell, and `low` otherwise.
  Accessibility-tree segments never raise it.
- **Coordinates.** Pointer positions and scroll offsets are points in window
  coordinates; scroll offsets are relative to the resting start of the
  content (the adjusted inset included).

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
  confidence, because a `ValueKey<String>` on any ancestor also counts as a tag.
  The native SDKs still use `high` for an alias (see their sections).
- `medium`: usable structural path and/or structural route fallback;
- `low`: ambiguous structure, bare collapsed item, or insufficient actionable
  evidence.

Confidence is evidence quality, not a uniqueness guarantee. Consumers should
corroborate low-confidence matches rather than treating them as ground truth.

In exploration mode (scene inventory emission on), a `tap` interaction that
carries a `targetFingerprint` also carries the fields below. Production taps
(since 0.12.4) carry `routeKey` only and keep the rest of the lean envelope
(`route` and `targetFingerprint`):

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
  Production taps carry it too: it is the key already computed for their
  fingerprint, so it changes no fingerprint, route key or inventory hash.
  Taps from SDKs before 0.12.4 do not carry it in production.
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
  `route_change.overlayKind`, which keeps its own closed set and matches type
  names more loosely: a custom `PopupRoute` whose type name contains
  `BottomSheet` or `Dialog` (`_PaywallBottomSheetRoute`) is `overlayKind:
  sheet` or `dialog` but `surface.kind: popup`. A build that obfuscates type
  names loses the sheet, dialog and menu matches.
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
  outside a nested navigator), where the shell is a second retained root in
  the same overlay entry as the sheet's host. A root in an overlay entry of
  its own (a text selection toolbar, a toast in an app overlay above the
  `Navigator`) is transient and does not hide the class.
  - A root is a retained widget with no retained parent left once the modal
    barrier has hidden what is under it. An app widget between the SDK's root
    and the `Navigator` (a provider or overlay host in the `MaterialApp`
    builder) is such a hidden parent and does not stop the surface from being
    named.
  - Two framework containers are looked through when their one retained child
    is the next link: for a `dialog` only, a `Dialog`
    (`Dialog.fullscreen(child: CouponDialog())` gives `CouponDialog`), and,
    for a `popup` only, the `Scaffold` a custom popup route builds around its
    builder when that child is the body (`Scaffold(body: builder(context))`).
    A sheet whose builder returns a `Dialog` or a `Scaffold`, and a dialog
    whose builder returns a `Scaffold`, are not looked through, and a
    `Dialog` with more than one retained child names nothing.
  - A host-named route keeps its name as `routeKey` and still reports
    `widgetClass`, so one named popup route reused for two paywall classes has
    one route key and two `widgetClass` values.

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

- **Units: every value is in Flutter logical pixels** of the render view
  (device-independent pixels, the coordinates `RenderBox.localToGlobal` and
  pointer events use), not device pixels, despite the `Px` in the names of
  `widthPx` and `heightPx` (and `offsetPx` and `maxExtentPx` below). Multiply
  by `devicePixelRatio` to get device pixels.
- `devicePixelRatio` is the render view's own ratio of device pixels to those
  logical pixels (its `ViewConfiguration`). It is `FlutterView.devicePixelRatio`
  unless the host scales its UI through its binding: a host that sets the
  ratio to `1.75 * 1.0549` on a 1.75 phone lays out 390 logical pixels wide,
  and the view's own 1.75 would put every box 19 to 72 px off.
- `widthPx` and `heightPx` are the size of the capture boundary's box in those
  logical pixels, after every transform between it and the view (a
  `Transform.scale`, a `FittedBox`): the box `boundsNorm` is a fraction of. With
  no transform it is the boundary's layout size. It can be smaller than the
  display (system bars, insets, host layout around the SDK's root).
- `boundaryOffset` is the top-left of that box in the view's logical
  coordinates.
- `insets` is the view padding (`FlutterView.viewPadding`: status and navigation
  bars, cutouts), top, bottom, left and right, divided by `devicePixelRatio`.
  It is not reduced by the keyboard and is read from the view, so a
  `MediaQuery` override inside the app does not change it.
- `keyboardInset` is the bottom view inset (`FlutterView.viewInsets.bottom`)
  divided by `devicePixelRatio`, 0 when no keyboard is shown.
- `referenceFrame` is always `captureBoundary`: the only frame boxes are
  normalized in.
- The object is left out when the boundary has no laid-out `FlutterView` to
  read.

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
  an embedded view) is not reported. The formula is exact for any translation
  and scale between the boundary and the view, including a host binding that
  scales the whole UI; under a rotation or skew `widthPx`, `heightPx` and
  `boundaryOffset` describe the boundary's axis-aligned bounding box, so it is
  approximate.

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

### Re-sample: moments plus novelty, and `trigger`

Every scene inventory carries `trigger`, the reason it was taken:

| `trigger` | Taken when |
| --- | --- |
| `initial` | the first capture of a session |
| `resume` | the app returns to the foreground |
| `route` | the visible route changes |
| `tap` | a tap, at pointer-up or by its after-capture; a re-sample after a tap |
| `scroll` | a frame captured during a scroll or at its end; a re-sample after a scroll end |
| `gesture` | the after-capture of a swipe, pan or zoom; a re-sample after one |
| `settled` | a re-sample with no interaction (a page that loads) |
| `manual` | a manual capture |

`trigger` is not part of `inventoryHash`, `routeKey` or the emission
de-duplication key, and it is never added to viewport semantic maps.

**Re-sampling** is on by default in exploration mode (it needs
`emitSceneInventory: true`) and catches what appears after an inventory
without a new capture: a control an interaction reveals (Blend's onboarding
Continue, shown once a row is picked), content that loads (a `FutureBuilder`,
a skeleton or a full-screen spinner replaced by content), and what a scroll
brings into view. Production captures (`emitSceneInventory: false`, the
default) run none of it: no watch, no frame callback, no timer and no extra
field. To turn it off in exploration, set `resampleSettledInventory: false` on
`TugboatReplayConfig`; route, tap, initial, resume, manual, gesture and
frame-tied scroll inventories are emitted either way.

The rules:

1. **Moments.** A re-sample is asked for by a moment: a tap or gesture whose
   inventory was built (the main case: controls revealed by interaction), the
   end of a scroll, and any inventory a capture builds, including one that
   finds nothing to list yet (a full-screen spinner). The next re-sample is
   labelled with the moment that asked for it (`tap`, `gesture`, `scroll`),
   else `settled`, and the label is used once. A programmatic scroll end
   does not replace a pending `tap` or `gesture` label (a tap that animates a
   `PageView`, a tap beside a running marquee). A re-sample is never taken on
   a rebuild or a frame as such.
2. **When.** One watch per route visit (route epoch) decides when, with the
   settled watch's frame rules. An armed watch parks one post-frame callback
   and holds no timer, so a page that draws no frame is never re-sampled. A
   drawn frame opens a window, 400 ms at first; a window with no frame in it
   means the page is quiet and it is re-sampled; frames in every window force
   a re-sample after 2 s of continuous activity, so content beside a spinner
   that never stops, or a control revealed under a looping animation, is
   still caught. A re-sample that finds nothing new doubles the window up to
   6.4 s; one that emits, or any new inventory a capture builds, resets it. A
   programmatic scroll end (an auto-scrolling marquee ends one every frame)
   only labels the next re-sample and arms the watch if it is not: it builds
   nothing and does not reset the back-off.
3. **Novelty.** Per route visit the SDK remembers the controls and content
   already sent, by canonical path with list positions collapsed (`[item:N]`
   becomes `[item]`, the normalisation of the structural route signature),
   and the states each was sent in: enabled or disabled. Every inventory a
   capture builds counts, whether it is emitted or an exact repeat of one
   already emitted this session. A re-sample is emitted only when it adds a
   path not yet sent in this visit, or lists a sent path in a state not yet
   sent (a button enabled). Content entries (images, large text) count, so
   loaded content replacing a skeleton or spinner is new when it adds paths
   the skeleton did not have. The SDK does not detect loading states: a
   skeleton that keeps the same controls in place and only changes how they
   look (not whether they are enabled) is not new.
   - **Pages of a `PageView` stay apart.** The page position of a `PageView`
     (the `[item:N]` after its own `Scrollable`, up to the next `Scrollable`)
     is not collapsed. Its pages are different screens under one route, and
     two pages built from one widget class (Blend's first and third
     onboarding pages are both `OnboardingGridPage`) would otherwise share
     every path, so a page reached by `nextPage` would never be new. Rows of
     a list inside a page collapse as usual.
   - **Exact repeats.** A re-sample whose de-duplication key and every
     entry's enabled state match an inventory already sent this session is
     not emitted. One that flips only a state keeps its
     fingerprints and so its de-duplication key (a disabled control has its
     enabled twin's fingerprint); it is emitted once per state. An emitted
     re-sample adds its key to the de-duplication set, so a later capture
     that builds the same content does not repeat it.
4. **Backstop.** At most 50 re-sampled inventories per route visit
   (`inventoryResampleCapPerVisit`). Novelty bounds a visit on its own; the
   cap only stops a page that keeps adding new kinds of controls for ever.
   It replaces the old cap of five settled inventories per route key per
   session, which starved screens whose pages share one route, such as an
   onboarding `PageView`. When it is reached the watch stops for that visit.
5. **Ending.** The watch ends on any visible route change, capture pause,
   lifecycle pause or hide, session end and dispose. It never ends on a timer.

**Positional inventories follow frames.** A scroll inventory is positional:
it records where the content is, and its job is to match a captured frame.
So during a scroll a scene inventory is built only when a frame is captured
for that moment (`captureScrollScreenshots` and its interval, and the
after-capture at the end of a scroll a pointer drives), and it is emitted only
when its content differs from the last inventory sent: a different
`inventoryHash`, element count, or a box that moved on a 2% grid. A scroll start and an update with no frame build none; a programmatic
scroll end (no frame) leaves its scene inventory to the re-sample. Every
captured frame keeps a matching inventory, sent then or earlier. The viewport
semantic map keeps its own scroll cadence.

**Known gaps.**

- A new list row built from the same template as a row already sent (a
  paginated list loading more of the same) is not new, because positions are
  collapsed; the rows reach an inventory with the next frame-tied scroll
  inventory or capture. Two template-identical pages of a `PageView` are
  kept apart (above), but two template-identical tabs of any other paging
  widget are not.
- A control revealed by a timer while an animation keeps running (a
  looping arrow) is caught by the forced check, up to 2 s late at first and
  up to 6.4 s late once the back-off has grown.
- Keeping a `PageView`'s page position costs an auto-advancing carousel one
  re-sample (`scroll`) per page it has not shown yet in the visit: a looping
  4-page carousel sends its first inventory and 3 more, then nothing; one
  with a large `itemCount` sends one per page move (15 in 30 s at a page
  every 2 s) until the backstop of 50 per visit.
- A layout change that adds no control (a box that grows, a loop between two
  layouts) is not new; a frame-tied scroll inventory still records new
  positions.

### What is and is not retained

The structural pipeline does not use or serialize arbitrary `Text`,
accessibility, tooltip, or icon-label strings as target identity. The opt-in
SwiftUI accessibility-tree identity (ADR 0010) reads traits and whether an
`accessibilityIdentifier` is set; it never reads labels or values, and never
sends the identifier's value.

Developer-authored identity strings can still be emitted:

- named routes;
- the `.tugboatTag(id)` / `TugboatTag.id` value in target fingerprint parts,
  plus its hash alias;
- the `.tugboatSubView(label)` / `TugboatSubView.label` value;
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
  segment and is no longer a tap's identity, so a control inside one (a
  `Switch` trailing a `ListTile` with no callbacks) moves, and so does a
  control around one (a `GestureDetector` or `InkWell` with `onTap` around a
  `ListTile` with no callbacks, which now names the outer control). A disabled control takes its enabled twin's fingerprint, so
  a disabled `TextField` (schema 6: `.../TextField#0`) moves to its enabled
  path, and a production tap on a disabled control carries that fingerprint.

Nothing else moves: an enabled control on a named route, with no overlay host,
theme wrapper or bare `InkWell` above or inside it, keeps its schema 6
fingerprint, and so does its production tap.

- **Roles.** `Semantics` with `onTap` or `onLongPress`, a `Listener` with
  `onPointerUp`, and a `RawGestureDetector` with a `TapGestureRecognizer` or
  `LongPressGestureRecognizer` are low-level `button` roles. Such a widget is a
  control of its own only outside every control and around no schema 6 role:
  inside a control it is the control's plumbing, and around one (a pointer-up
  `Listener` around a button) it is a layer of that control, so neither adds an
  entry or a path segment. A control of its own gets a path for itself
  (`.../Semantics#0`) but is not a parent in any other path, so the content
  below it keeps its schema 6 path. As a list row it takes the row's
  `[item:N]` position instead and is the parent of the row's content. The `Listener` that `Navigator` builds and the
  dismiss `Semantics` of a `ModalBarrier` are never controls. A `MouseRegion`
  is never a role. Framework widgets that build a low-level role around no
  control are reported: a bottom sheet's drag handle, a `SelectionArea` around
  plain text.
- **Disabled controls** are listed with `enabled: false` and no tap action. They
  are never tap targets (`enabled != false` gates tap selection and the
  pathless snap), and exploration taps on them stay unresolved as before.
  For the controls tested (Material buttons, `IconButton`, `CupertinoButton`,
  `Checkbox`, `Switch`, `ActionChip`, `TextField`, `ListTile.enabled`; also
  probed: radios, sliders, `CupertinoSwitch`, `FilterChip`, toggle tiles),
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
- **Controls under `ExcludeSemantics`.** An app that gives a button one
  semantics node of its own (`Semantics(label: ..., child: ExcludeSemantics(
  child: ElevatedButton(...)))`, Blend's `SemanticButton`) hides the button's
  subtree from the token map like any excluded subtree. A tap on it keeps the
  path of the nearest retained widget above the wrapper (the pointer-down
  fallback of 0.10.10), at `low` confidence, in both modes.
  - **Inside a scrollable, the hidden control names the tap** when the hit
    path shows it and its path is its own. On the path: the first
    `RenderExcludeSemantics` the token map recorded as a subtree root (one
    inside the hidden subtree, such as the button's own `Icon`, is looked
    past), and below it a chain of single children to the first role, a
    control that is not a scrollable, which the hit reaches. Its own path:
    every element from that root up to the retained widget whose path the
    tap takes (Blend's `PillButton`) has a single child and is no list
    container. Then the tap's `role`, `enabled`, `actions`, `widgetType` and
    box are the hidden control's instead of the scrollable's, in both modes,
    and when its `onPressed` animates the scrollable the pointer-down rule
    below keeps it. So Blend's onboarding Continue (in a `PageView`, under
    `Visibility` and `AnimatedOpacity`) is that button. Before, its tap took
    the `PageView`'s fingerprint, or in exploration a row that listed that
    fingerprint as an alias. The rule follows only the two chains, never the
    subtree, so production pays a few element visits for taps through such
    a wrapper inside a scrollable and nothing for others.
  - **Unchanged:** a hidden control with no enclosing control keeps the path
    above the wrapper and no role, as since 0.10.10. The tap still names the
    scrollable, as before, when the path is not the control's own (two
    hidden buttons in one row, list rows or `PageView` pages whose only
    retained widget is the scrollable's own, which would otherwise share one
    fingerprint), when a fork sits above the first hidden control (two
    buttons under one wrapper, a hidden list). A hidden control
    inside another control (an `InkWell` around the wrapper) keeps that
    control as its identity. No fingerprint, `routeKey` or `struct:`
    signature moves outside the case above.
  - **Exploration inventories** list the hidden control as an entry: its
    fingerprint and `canonicalPath` are what a tap at the control's centre
    resolves to, its `role`, `actions` and `enabled` are the control's, and
    `boundsNorm` is its paint box, so an exploration tap on it joins an
    inventory. It is left out when the excluded subtree hides no control or
    more than one (a scrollable is not the control; the controls in it
    count), when a tap at its centre does not reach it (it ignores pointers
    or is covered), when that tap resolves to another control, when two
    hidden controls or an existing entry share the fingerprint, and when
    other entries or other hidden controls sit under its path (a page or a
    section, not the button). A scrollable whose centre lands on the hidden
    control keeps its own entry, resolved as before this rule, so the
    control's entry keeps its own box. An inventory that lists such a
    control has a new `inventoryHash`.
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
  route (a text selection toolbar and handles, also in an outer overlay or
  for a sheet on a nested navigator), when a toast shows in an app overlay
  above the `Navigator`, and when the app wraps the `Navigator` in its own
  widgets, so the key does not flip. A
  host-named route (`RouteSettings(name: ...)`) keeps its name, and an inline
  builder with no nameable class keeps the runtime type (sheet) or `struct:`
  key (dialog). A dialog whose builder returns a `Dialog` around one app class
  is keyed by that class (`dialog:CouponDialog`).
- **Known limits.** Two sheets or dialogs with no nameable class and the same
  structure still collide; name the class or pass `RouteSettings(name: ...)`. A
  custom `PopupRoute` cannot be told from its type name, so it keeps its
  `struct:` key. A disabled control whose inner controls fork (a disabled
  `TextField` with a suffix button) keeps its own path, so enabling it changes
  its fingerprint. Disabled twins that still differ, as in schema 6: an
  `InputChip` disabled by `isEnabled` (the role reads only its callbacks), a
  `CupertinoTextField` and a `SearchBar`. A pointer-up `Listener` or tap
  `Semantics` around a `ListTile` with no callbacks or around a scrollable is
  neither a control nor part of one. A `GestureDetector`, `InkWell`, `ListTile` or tap
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
`allTextExceptActionable`, `sensitiveInputsOnly`, and `nonAssetImagesOnly`.
The levels, the `TugboatSensitive` override and the rule that an adapter
that cannot place a mask masks more are defined once for every SDK in
[Privacy model](../architecture/native-capture-contracts.md#privacy-model).

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

On the kept path, a hit entry that is capture chrome can still name its
control. A tap on a button's padding hits the button's own gesture `Listener`
first; skipping it would start the climb above the `GestureDetector` and land
on the `InkWell`, a layer the scene inventory lists only as an alias. The
fresh path folds that alias back to the inventory primary, but after a
navigating tap the inventory cannot see the old screen. So on the kept path a
chrome entry whose climb reaches an actionable, addressable control resolves to
that control, the same layer a glyph tap and the scene inventory report. This
does not apply when a control hidden under `ExcludeSemantics` names the hit
(its own rule above handles it), and the fresh path is unchanged.

A control that stays mounted while the app navigates (a persistent bottom bar
outside the `Navigator`) is not absorbed, so its pointer-up hit test succeeds
but runs under the destination route. When the route changed since pointer-down,
a usable pointer-down hit path therefore wins over the fresh hit test, and the
fingerprint belongs to the route the tap happened on. Exploration
mode resolves at pointer-down and has no such window.

A tap whose `onTap` starts an animated scroll (`PageController.nextPage` on a
page of grid tiles) makes that scrollable ignore pointers at once, so the
pointer-up hit test stops at the scrollable. When the fresh target is a
scrollable and the pointer-down hit path resolves to a control inside it (its
canonical path extends the scrollable's), the pressed control wins and is not
re-anchored to the inventory built at pointer-up, which sees the scrollable
over it. A tap on the scrollable itself, outside any control, keeps the
scrollable. This makes production taps agree with exploration ones, which
resolve at pointer-down; it reuses the kept hit path and the existing token
map, so production taps do no extra tree walk.

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

The sink hub isolates synchronous and asynchronous sink failures, including
failed futures from `start()` and `dispose()`. A factory whose `create()`
throws is skipped; the session and the other sinks still start. Capture
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
cross-build equivalence. The `tugboat_build` package generates `widgetNames`
for an app's public widget classes; private, generic, and framework widgets
stay unnamed, so a generated map does not by itself close this gap.

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
