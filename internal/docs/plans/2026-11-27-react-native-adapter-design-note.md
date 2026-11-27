# React Native adapter design note

Status: Draft for review · 2026-11-27 · BLE-642 (ADR 0009, rule 4 of the amendment)

Working note, not product docs. It sits in `internal/docs/plans/` with the
other design notes ([native SDK design note](2026-10-12-native-sdk-design-note.md))
because it sequences a milestone and carries open questions. It is not an ADR
and not a host-integration page (`docs/publishing.md`). The parts that become
contracts move to `docs/` when the adapter ships: the `react-native`
canonicalization goes to `docs/design/capture-and-fingerprint.md` (one section
per toolkit, ADR 0009), and the masking API goes to the shared privacy
contract (BLE-633).

Scope of release 1 of `@tugboat/react-native`: session replay and fingerprints
(sessions, navigation, masked frames, taps, scrolls and text input with stable
fingerprints, the same on Android and iOS). Network evidence is release 2
(BLE-648, BLE-671). Error reporting is release 3. Sections 7 to 12 fix the
seams those later releases need, so release 1 does not block them.

Sources: ADR 0009 and its amendment; `core/session-engine/docs/stateful-engine.md`
(including open PR #188 for the settled re-sample); open PR #187 (`idSeed`);
`docs/design/capture-and-fingerprint.md`; the Views, Compose and SwiftUI
adapters; the Flutter `tugboat_dio` package and the native `network_call`
helpers. Upstream React Native claims are marked **[verified]** (read in the
current upstream docs on 2026-11-27), **[memory]** (known to the author, not
re-read) or **[spike]** (must be proved on a device before it is relied on).

## 1. Summary of decisions

| # | Decision |
| --- | --- |
| 1 | New Architecture only. A TurboModule carries batched facts and a Fabric component carries masks. The old architecture is not supported. |
| 2 | Native owns pointer facts, frame timing, pixels and mask rectangles. JS owns identity: it resolves the touched target from the React tree and sends identity parts. |
| 3 | JS sends mask **marks** (level and id), not rectangles. Native reads each mask view's real bounds in the draw turn. This deviates from the ADR 0009 text and needs sign-off (Q2). |
| 4 | Navigation facts come from the navigation container's state, diffed in JS. Expo Router uses the same path. |
| 5 | A JS context that goes away and comes back ends the session and starts a new one, unless no RN navigation fact was sent. |
| 6 | One npm package with `android/` and `ios/` native code, autolinked. The Expo config plugin only enforces minimum OS versions in release 1. |
| 7 | The identity token comes from a portable role table over host component names, never from component function names (minifiers rename them). `testID` is the alias. |
| 8 | Network is recorded in JS by wrapping `XMLHttpRequest`, one route resolver for both OSes, with a request mark so native adapters skip. |
| 9 | The scene inventory is built in JS. Native runs the frame watch and forwards `scene.sample` to JS. |
| 10 | Pager pages need one engine change: an explicit `[page:N]` path segment the novelty rule never collapses (BLE-677). |

## 2. Bridge

### 2.1 Architecture support

Facts about React Native:

- 0.82 runs entirely on the New Architecture. `newArchEnabled=false` and
  `RCT_NEW_ARCH_ENABLED=0` are ignored there. 0.81 and Expo SDK 54 are the
  last versions that allow the legacy architecture. Interop layers stay for
  third-party libraries. **[verified]** (RN 0.82 release post)
- The New Architecture became the default in 0.76. **[memory]**
- Codegen turns a typed spec into native scaffolding. A TurboModule spec file
  name starts with `Native`, and `codegenConfig` in `package.json` names the
  output. **[verified]** (RN docs, "Pure C++ Modules")

Decision: support **React Native 0.76 and later with the New Architecture
on** (Expo SDK 52 and later). Hermes is the tested engine.

The old architecture is not supported:

- Maintainers removed the opt-out in 0.82, so the population that would need
  it shrinks to apps on 0.76 to 0.81 that turned the default off.
- Every piece below (TurboModule, Fabric component, fiber-based identity,
  mask view) is written once against the new stack. A second path for the old
  renderer doubles the privacy surface.
- The interop layer lets a legacy library run on the new architecture. It
  does not let our new-architecture code run on the old one.

On the old architecture the module detects the missing Fabric UI manager
(`global.nativeFabricUIManager` is absent **[spike]**), logs one warning, and
stays dormant. No capture starts.

Consequence for the amendment: rule 4 says device tests run with Fabric on
and off. With the old architecture unsupported, the "off" leg has nothing to
test. Q1 asks to amend rule 4. The flattening test stays: a mask inside
layout-only parents, with Fabric on, must still be found.

### 2.2 TurboModule and JSI

One TurboModule, `NativeTugboat`, in front of the native host:

| Direction | Mechanism | Used for |
| --- | --- | --- |
| JS to native | `post(batch: string): void`, asynchronous, fire and forget | All facts: identity, navigation, mask marks, scene inventory answers, evidence |
| JS to native | `attach(options): Promise<AttachResult>` | Start or re-attach (section 5) |
| JS to native | `getHostInfo(): HostInfo`, synchronous, once at start | Platform, density, whether a session is active |
| Native to JS | `NativeEventEmitter` events | `sceneSample` request, activation state, session ended |

Rules:

- **Batched.** JS queues facts and flushes once per frame-idle turn
  (`requestAnimationFrame`, bounded at 50 ms), and at once for a tap's anchor.
  One `post` per flush. Each batch carries `jsNowMs` (`performance.now()` at
  flush). Native computes the clock offset from it, so JS timestamps map onto
  the host monotonic clock with an error of one transit delay. JS never reads
  the wall clock for evidence.
- **No synchronous JSI call on a touch path.** A sync call blocks the JS thread
  on the native queue. `getHostInfo` is the only one and it runs once.
- **Serialized JSON string, not object graphs.** It keeps the engine message
  format (stateful-engine.md section 3) and the conformance fixtures the same
  on every adapter, and holds no JS objects on the native side.
- **Never throws into the app.** Every JS entry point is wrapped. A native
  failure resolves to a no-op.
- **Lifetime.** The module instance belongs to one React instance. The host
  (engine, outbox, session) is a process singleton and outlives it (ADR 0009,
  consequences). Section 5 covers what that means.
- **The package depends on the native SDKs, not on the engine.** Android:
  `com.gettugboat.sdk:tugboat-android`. iOS: the `Tugboat` module. Adapters
  never compile the core (ADR 0003).

### 2.3 Where each fact comes from

| Fact | Source | Why |
| --- | --- | --- |
| `input.pointer` down, move, up, with `x`, `y` | Native: `Window.Callback` wrapper on Android, a gesture recognizer on the key window on iOS (as the Views and SwiftUI adapters) | The pre-interaction frame freezes on `down`, before JS can run. Native sees every touch, including ones RN does not route. |
| Tap target and scroll target identity | JS: touch handlers on the root wrapper | Identity is derived from the React tree (ADR 0009). |
| `navigation` | JS: navigation container state | Route names exist only in JS. |
| Mask rectangles | Native: mask views and the native view walk | Section 3. |
| `capture.request` answer, pixels | Native pixel runtime | Raw pixels never enter JS. |
| `scene.watch`, `scene.frame` | Native: `Choreographer` (Android), `CADisplayLink` (iOS) | Drawn frames are a native fact. |
| `scene.inventory` | JS | Identity parts are in JS (section 9). |
| `evidence.networkCall` | JS, in release 2 | Section 7. |
| Lifecycle, launch, exit, delivery, outbox | Native host | ADR 0009. |

**Tap identity timing.** The engine wants the target resolved at the **down**
position and attached to the `up` fact (stateful-engine.md section 9.1: "tap
evidence travels with the fact"). RN hands a capture-phase handler a touch
event whose target is the node the user touched. The flow:

1. Native sees `down`, requests the before-frame, stamps `downMonoUs`.
2. JS sees the same touch through `onTouchStartCapture` on `<TugboatRoot>`
   (it observes and never becomes the responder). It resolves the target
   (section 8) and posts `tapAnchor {downTimeMs, x, y, anchor}`.
3. Native, on `up`, attaches the anchor whose down time and point match. If
   none arrived within a bound (proposal: 100 ms, held on the host queue only,
   never on the UI thread), the tap goes out with `failureReason:
   identity_unavailable`.

The hold is a new bound, so it needs a benchmark (amendment rule 2).
`event._targetInst` (the fiber of the touched node) is a React internal
**[memory]**, and other RN SDKs read it **[memory]**. It can change in any
React version, so the resolver checks it and falls back to route-only identity
(`low` confidence). It never throws. The fiber walk needs a **[spike]** on
React 18 and 19 and Hermes.

## 3. Mask geometry and Fabric

### 3.1 The problem

Under Fabric, the JS tree is not the view tree:

- React commits to the shadow tree on the JS thread. Mounting native views is
  a later step on the UI thread. For a short window JS is ahead of the screen.
- Layout is computed in C++ off the JS thread. JS has no synchronous layout
  for a fiber. `measureInWindow` is asynchronous. Web-like DOM APIs on refs
  (`getBoundingClientRect`) are newer **[memory, spike]**.
- Fabric removes layout-only views from the native hierarchy (view
  flattening). A `View` that only lays out children may not exist natively.
  `testID` and `nativeID` stop the removal for a view, and `collapsable={false}`
  keeps it. **[verified]** (RN docs, "View flattening" and "View")
- Reanimated and gesture-handler move views on the UI thread without JS
  knowing the new position **[memory]**.

So rectangles computed in JS can be stale, wrong, or point at a view that has
no native counterpart. For a mask, a wrong rectangle is a privacy bug.

### 3.2 Decision: JS sends marks, native reads rectangles

- **Identity needs no geometry.** The tap target comes from the touch event
  (the node the native hit test chose), not from a JS hit test over
  rectangles. What the user touched and what JS names are the same node.
- **Masks are native views.** `<Tugboat.Mask>` renders a Fabric component,
  `TugboatMaskView`, a container view with its own component descriptor. It is
  not a core `View`, so it is not a layout-only candidate, and it forms a view
  so a flattened parent cannot take it **[spike: confirm on both OSes, inside
  `collapsable` parents]**.
- **Rectangles are read at draw time.** As in the SwiftUI and Android adapters
  (native SDK design note, section 2), the host calls its mask supplier in the
  same main-thread turn as `PixelCopy` / `drawHierarchy`. The supplier walks the
  native view tree and reads each mask view's window bounds. The rectangles
  describe the copied frame, not the layout when the request arrived. Animated,
  scrolled and gesture-moved views are right because native reads where the view
  is.
- **Automatic masks need no JS either.** Under the default `allTextAndMedia`,
  the native walk masks text (`ReactTextView`, `RCTParagraphComponentView`, text
  inputs) and media (`ReactImageView`, `RCTImageComponentView`) as the Views and
  UIKit walks do. The class names are **[memory]** and the table is part of the
  spike. Unknown drawing surfaces (Skia canvases, maps, video, `WebView`,
  `SurfaceView`, `TextureView`) are masked over their whole bounds (fail-closed,
  native design note section 2.1).
- **Coordinates.** Window coordinates in dp (Android) or points (iOS),
  normalized into capture-boundary space by the pixel runtime (ADR 0006). The
  pointer `x`, `y` use the same space.

### 3.3 Fail closed

`<Tugboat.Mask>` is a JS component plus a native view. On mount, JS registers
the mask id with the host (`expectMask(id, level)`). The native view attaches
with the same id (`maskId` prop). At draw time the host checks:

| Condition | Result |
| --- | --- |
| Every expected mask id has a live native view attached to the window with readable bounds | Use the view rectangles |
| An expected id has no live view, the view is detached, or its bounds cannot be read | **Mask the whole frame** |
| The host cannot read the native view tree at all | Mask the whole frame |
| JS never registered the id but a native `TugboatMaskView` exists | Use it (native truth wins) |

The id pairing makes "cannot be found" detectable: the host knows how many
masks JS believes are mounted. A mask unmounted in JS and not yet unregistered
holds the whole-frame fallback for at most one flush, which errs toward masking
more.

This satisfies amendment rule 4 (a native view that cannot be flattened, the
frame masked whole when it cannot be found). Device tests, Fabric on:

- a mask inside nested layout-only `View`s with default `collapsable`;
- a mask under an animated (Reanimated) transform and inside a `ScrollView`;
- a mask unmounted mid-capture;
- a mask whose native view fails to attach (test hook);
- each case checks the captured pixels under the rectangle.

### 3.4 Mapping onto the shared privacy model (BLE-633)

BLE-633 (in progress) defines the masking levels and inheritance once. From the
issue text: four dimensions (text and input, images, touch, hide), and an
override inherits from the nearest ancestor. The level names and the contract
type are not written yet, so this section fixes the shape of the mapping, not
the names.

| Model element | React Native |
| --- | --- |
| A level per dimension | Props on `<Tugboat.Mask>`: `text`, `images`, `touch`, `hide`, each a level or `inherit` (the default). Level names are BLE-633's. |
| Nearest-ancestor inheritance | The native view hierarchy. A leaf (text, image) takes its value from its nearest `TugboatMaskView` ancestor that sets that dimension. Because the mask view is never flattened, native ancestry equals React ancestry. No JS pass is needed. |
| App-wide default | `Tugboat.start({ mask })`. The default is `allTextAndMedia`. |
| `tugboatSensitive` on other toolkits | `<Tugboat.Mask hide>`. The marked bounds join the union and never leave it (native design note section 2.1). |
| Touch | Whether tap anchors, scroll offsets and text-input facts under the subtree are recorded. JS stops resolving at a `touch`-off mask, and native sends pointer facts inside its rectangle with no anchor. |
| Cannot place a mask | Mask more: the whole frame (section 3.3). |
| A level that relaxes the default | If its view cannot be found nothing is relaxed and the default masking applies. Only tightening masks trigger the whole-frame rule. |

The adapter only supplies levels per mask view. If BLE-633 resolves
inheritance in the host, the host walks the view hierarchy. If it resolves in
the engine from a tree of mask nodes, native sends the ancestor chain (mask id,
parent id) with the rectangles. The RN component does not change either way.

## 4. Navigation

### 4.1 React Navigation

Facts **[verified]** (React Navigation docs, navigation container): the
container has `onStateChange` (the new state on every change; rely only on
`index` and `routes`, the rest is internal), `onReady`, and a ref with
`getRootState`, `getCurrentRoute`, `getCurrentOptions` and `addListener`
(`state`, `options`, `ready`).

Design:

- API: `Tugboat.trackNavigation(navigationRef)` (or a `<Tugboat.NavigationTracker>`
  component). It subscribes with `addListener('state')` and `ready`, so it
  does not replace the app's own `onStateChange`.
- **Navigator ids.** Each navigator state has a `key`. `navigatorId` is that
  key. A nested navigator is a screen of its parent, so `parentNavigatorId` is
  the enclosing state's key.
- **Route instance ids.** `route.key`, stable per instance. `name` is the
  route name.
- **Diff.** On each state event, JS diffs the previous and next stack of each
  navigator by route keys. A key added on top is `push`, the top removed is
  `pop`, the top replaced is `replace`, a non-top key removed is `remove`.
  Several changes in one state (a `reset`) go out in order as the equivalent
  facts. Tab and drawer index changes are not `push` or `pop`: nothing is sent,
  and the route key follows the focused leaf (as SwiftUI tabs do).
- **Seed.** On `ready`, send `navigation session_start` with the visible chain
  last (stateful-engine.md section 8.1). Each nested navigator sends one.
- **Route key.** The focused path of route names from the root, joined with
  `/` (for example `Main/Tabs/Home`). No params. Names are developer strings,
  the same on both OSes. Q4 asks whether to use only the leaf name.
- **`overlayKind`.** From `getCurrentOptions().presentation` of the focused
  route when it is `modal`, `transparentModal` or `formSheet`, else `page`.
  `transitionMs` follows the engine's defaults per kind until measured.
  **[spike]**
- **No native duplicates.** `react-native-screens` (native stack) creates real
  fragments and `UIViewController`s. The native hosts' own screen tracking
  (activity and fragment callbacks, the optional `viewDidAppear` exchange) must
  not emit routes for them. The RN adapter claims the RN root view with the host
  and the other tracking stands down for it (section 12, Q6).

### 4.2 Expo Router

Expo's docs cover screen tracking with `usePathname` and
`useGlobalSearchParams`, an experimental focus-mark API in newer SDKs, and
advise against `onReady` / `onStateChange` where possible. **[verified]** (Expo
docs, screen tracking). Expo Router being built on React Navigation is
**[memory]**.

Design: use the same container-state path through the navigation ref Expo
Router exposes (`useNavigationContainerRef`, **[memory, spike]**). Route names
are file-structure names (`(tabs)/index`, `profile/[id]`), so the route key is
already a pattern with no params, and groups like `(tabs)` are stable
file-system facts. `usePathname` is not used: it is the concrete URL and can
hold ids. The experimental focus API is not used because it can change.

### 4.3 Other navigation

Wix `react-native-navigation` is native navigation and out of scope for
release 1. A manual `Tugboat.setScreen(name)` (one navigator, push semantics)
covers custom navigators. Q5.

## 5. Hot reload and a recreated bridge

The host is a process singleton. JS state is per JS context. The engine keeps
route stacks and a live session. ADR 0009 requires the adapter to "re-attach
to, or explicitly end, the running session".

| Event | What happens to JS | Rule |
| --- | --- | --- |
| Fast Refresh of an app file | Modules re-run, React state kept | `start` with an equal config is a no-op (native `start` is idempotent). The tracker unsubscribes on unmount and resubscribes, with no new seed while the same container lives. |
| Full reload (Metro `r`, `DevSettings.reload`, OTA reload), Bridgeless host recreate | New JS context, all JS state gone, module `invalidate()` on the old instance | Detach, then attach (below). |
| Android activity recreate with a surviving React host | JS survives | Nothing. Native re-wraps the new window (existing rule). |
| Brownfield: RN screen closed, host destroyed, later reopened | JS gone, native screens continue | Detach, then attach. |

Detach and attach:

1. On module `invalidate()` the host marks the RN adapter **detached**. Facts
   from RN surfaces in that state carry no anchors (`identity_unavailable`).
   Masking is not affected: native masks need no JS. Mask bookkeeping resets,
   and any frame with an unmatched `TugboatMaskView` is masked whole.
2. On the next `attach` the host decides:
   - **No RN navigation fact was sent in the session:** re-attach silently.
   - **Otherwise: end the session and start a new one** (`session_end`, new
     `idSeed`, new session id). JS then sends its `session_start` seeds into
     the new session.

Why end, not re-attach: the engine drops a navigation seed once a session has
had a live navigation (stateful-engine.md section 8.1). The new JS context
starts its navigators from their initial routes, so the engine's stacks and the
real stacks disagree. Re-sending state would need a new "replace all stacks"
fact. Ending costs one short session in production (OTA reload is rare) and
many in development, which is acceptable. A host `restart` call is needed: today
a new session starts through `activate` with a new request id, which is the
wrong signal. Q7.

Edge: after a detach, native pointer facts continue and no JS listens. After a
grace period with no attach (proposal: 5 s), the host treats RN surfaces as
opaque: whole-frame mask, no tap anchors. Fail closed.

## 6. Packaging

| Item | Decision |
| --- | --- |
| npm package | `@tugboat/react-native`, one package: TypeScript source and build output, `android/`, `ios/`, `app.plugin.js`. Peer deps: `react`, `react-native` (>=0.76); optional peers `react-native-pager-view`, `@react-navigation/native`, `expo`. |
| Codegen | `codegenConfig` of type `all` (TurboModule `NativeTugboat` plus component `TugboatMaskView`), Java package `com.tugboat.reactnative`. |
| Android | Gradle library `com.tugboat.reactnative`. Depends on `com.gettugboat.sdk:tugboat-android` from Maven Central. minSdk 26 (`PixelCopy.request(Window)`; below it the session carries events without frames, as in the native note). |
| iOS | `TugboatReactNative.podspec`, depending on the `Tugboat` pod (`TugboatSDK.podspec`). RN on iOS builds with CocoaPods, so a published podspec is required. Today `TugboatSDK` is unpublished and `TugboatAlamofire` is SwiftPM only. iOS 15. |
| Autolinking | RN CLI and Expo autolinking find the package from `package.json`, `android/build.gradle` and the podspec. No `react-native.config.js` in release 1. |
| Expo config plugin | `app.plugin.js` at the package root re-exporting a compiled plugin, with `expo` as an optional peer. **[verified]** (Expo docs, plugins for libraries). Plugins run at `expo prebuild` and may edit `AndroidManifest.xml` and `Info.plist`. **[verified]** Release 1 plugin: enforce minimum SDK and deployment target, and fail prebuild with a clear message when the New Architecture is off. |
| Expo Go | Cannot load custom native code **[memory; the Expo pages read did not say]**. Documented requirement: a development build or prebuild. |
| Versions | Independent (ADR 0008). The npm package pins exact native versions, and the compatibility table gets a row. |
| Start | Release 1 starts from JS (`Tugboat.start` in the app entry). A native early-start hook (Android `Application` init, iOS app delegate) for cold-launch signals is release 2, with plugin support for manifest and `Info.plist` config. Q8. |
| Workspace | A new npm workspace in this repo (none exists today). Out of scope for this PR. |

## 7. Network evidence (release 2, BLE-648 / BLE-671)

Recorded in **JS**, not by native HTTP adapters, so there is one route
resolver and one set of semantics on both OSes.

React Native's `fetch` and axios's RN adapter sit on `XMLHttpRequest`
**[memory]**. The adapter wraps `XMLHttpRequest.prototype.open`, `send` and the
`loadend` family once, at `install`.

Known gaps **[memory]**: `expo/fetch` (a native fetch that does not use XHR) and
libraries that call native networking directly (file transfer modules, image
loaders). They are not recorded, and the docs say so.

### 7.1 JS API (matches `tugboat_dio` and the native helpers)

```ts
import { Tugboat } from '@tugboat/react-native';

Tugboat.network.install({
  // Same contract as Dio's routeResolver: return an app-owned path.
  routeResolver: ({ method, url }) =>
    url.startsWith('https://api.example.com/orders') ? '/orders' : null,
  errorBodyUrls: [],        // same policy and defaults as tugboat_dio
  errorBodyDenyUrls: [],
});

// Manual, for transports the wrapper cannot see (same shape as beginNetworkCall).
const call = Tugboat.beginNetworkCall('POST', '/orders');
call.complete({ statusCode: 201, attemptCount: 1, errorResponseBody });
call.fail({ failure: 'network_error' /* or 'cancelled' */, statusCode, attemptCount });
```

Semantics, copied from `tugboat_dio` and `Tugboat.beginNetworkCall`:

- The resolver runs once per request, at `send`, only while Tugboat accepts
  evidence. It receives the method and URL string, never headers or bodies.
- The result is trimmed. `null`, `undefined`, empty or a throw: **record
  nothing**. The route rules (single leading slash, no scheme, query, fragment,
  escape or whitespace) are the engine's.
- One call per request, finished once. A second `complete` or `fail` is a
  no-op. A call that is not recorded gets a no-op token.
- Outcome: a response with a status is `complete`; `error` or `timeout` is
  `fail` network_error; `abort` is `fail` cancelled.
- Error body only for status 400 or more, only for `responseType` `''`, `text`
  or `json` (a binary response keeps none), cut to 64 KiB before it crosses to
  native, then bounded again by the engine. The URL policy is checked at the
  request URL and at `responseURL`. A redirect hop between them is not visible
  in XHR.
- No request body, successful response body, header, cookie or query is read.
- `attemptCount` is omitted by the wrapper (XHR has no retry). Retry libraries
  use the manual API.
- Times: JS `performance.now()` at `send` and at `loadend`, mapped to the host
  monotonic clock with the offset of section 2.2. One `evidence.networkCall`
  message goes out at the end. The engine applies the method, route and
  duration rules (evidence-messages.md).

### 7.2 Request mark

Every request the wrapper sees is marked **whether or not** the resolver
recorded it. An empty route means the app chose not to record that call, and a
native adapter with its own resolver must not record it instead.

Mechanism: the wrapper adds a request header (`x-tugboat-js`) before `send`.
Native adapters (`tugboat-okhttp`, and an iOS one when it exists) skip a
request that carries it and remove it where the HTTP stack allows. OkHttp can.
An `NSURLProtocol` cannot rewrite the header reliably, so on iOS it may reach
the server. That is documented as harmless. The alternative, a native "claim"
call matched by time, is fragile. The header changes the native adapters'
contract, so it lands with release 2. Q9.

## 8. Identity: canonicalization for `toolkit: react-native`

This moves into `docs/design/capture-and-fingerprint.md` when the adapter
ships. The hash, `fingerprintParts` and confidence tiers are shared. Anchors
add `toolkit: "react-native"` (already in the engine's closed set), which is not
a hash input. JS computes the parts. It never hashes.

- **Source.** The committed (current) fiber tree of the JS root, read from the
  touched fiber up to the route root. Read-only.
- **Why not function names.** Hermes release builds are minified, so
  `fiber.type.name` is unreliable, as R8 class names are on Android. Identity
  uses only values that survive minification: host component names from view
  configs, string `testID`, numbers, and component **references** compared by
  identity (our own `Tugboat.Tag`, a registered pager).
- **Token.** A portable role from a versioned table over host component names,
  so iOS and Android agree:

  | Role | Source (host names **[memory]**, finalized in the spike) |
  | --- | --- |
  | `Pressable` | a fiber with `onPress`, `onPressIn` or `onLongPress` in its props, on its nearest host node |
  | `TextInput` | `AndroidTextInput`, `RCTSinglelineTextInputView`, `RCTMultilineTextInputView` |
  | `Switch` | `AndroidSwitch`, `RCTSwitch` |
  | `Scrollable` | `RCTScrollView` |
  | `Image` | `RCTImageView` |
  | `Text` | `RCTText`, `RCTVirtualText` |
  | `View` | `RCTView` |
  | `Node` | anything else |

  A third-party component gets the role of its host root. Its JS name never
  enters.
- **Segments.** `Token#<ordinal>`; with a `testID`, `Token#<testID>`
  (`Token#<testID>#<ordinal>` when it repeats), as for Views. Ordinals count
  same-token siblings after filtering, in child order.
- **Excluded.** Nodes not rendered (`display: none`), zero opacity, zero size,
  `pointerEvents: 'none'` subtrees, SDK components. A `Modal` is its own native
  window and a separate surface. The native note covers dialogs: captured, not
  wrapped for pointer facts (known gap).
- **Kept.** Pressables, text inputs, switches, scrollables, nodes with a
  `testID`, maskable leaves. Everything else collapses.
- **Lists.** A cell of `FlatList`, `SectionList` or FlashList adds
  `[item:<index>]` from the cell's `index` prop (`CellRenderer` or the FlashList
  cell container, **[memory, spike]**). Without it the segment is `[item]` at
  `low` confidence. The index, not the key, matches Flutter and Android.
- **Pager.** Section 10.
- **Route key.** Section 4: the focused path of route names, no params. Without
  the tracker: `rn:root`, `low`. Paths start below the screen element of that
  route (the provider of the navigation route context in the fiber, **[memory,
  spike]**, else the root).
- **Alias.** The nearest `testID` at or above the target gives `tagFingerprint`
  and does not change the structural fingerprint. `accessibilityLabel`,
  `placeholder`, visible text and `nativeID` never enter (locale evidence).
  `<Tugboat.Tag id>` is a JS-only wrapper (no native view) for apps whose
  `testID` is dynamic (`item-${id}`) and so unfit as identity. Q3.
- **Confidence.** Floor of the route's and the path's. The path is `high` with
  an alias, `medium` with its own `testID` or in a list item, `low` otherwise.
  A route from the tracker is `medium`.
- **Coordinates.** dp on Android, points on iOS (RN layout units), window
  origin. Scroll offsets are relative to the content start.
- **Same on both OSes** given the same `testID`s, route names and structure.
  The role table is the only place platform names appear. The conformance test
  is a cross-OS fixture: one React tree, both host-name sets, one fingerprint.
- **Cross-build stability** is not promised (AGENTS.md). A React Native release
  that renames a host component is a table change and a schema-version question.

## 9. Settled re-sample and the scene inventory

Facts (stateful-engine.md section 4.3.2, PR #188): the engine owns the settled
re-sample. It emits `scene.watch {armed}` and `scene.sample`, takes
`scene.frame {}` from the host (at most once per 100 ms while armed), and takes
the answer as `scene.inventory {resample: true, ...}`. Exploration metadata
(`trigger`, `surface`, `viewport`, `scroll`, per-element `visibleFraction`,
`tag`, `positional`) rides on the fact.

For React Native:

| Piece | Owner |
| --- | --- |
| Novelty, windows, caps, de-duplication | Engine |
| `scene.watch`: arm and disarm drawn-frame callbacks, send `scene.frame` | Native host. No JS. |
| `scene.sample` | The native host receives the effect and emits a `sceneSample` event to JS. **JS answers.** |
| The inventory (elements, identity, `tag`, `positional`) | **JS**, from the fiber tree of the visible route, using section 8. |
| Element boxes and `visibleFraction` | JS asks for window boxes in one batched call **[spike]**. If no usable source exists, native fills boxes by `reactTag` for the elements JS names. |
| `viewport`, `scroll`, `surface` | Native knows window size, insets and keyboard. JS knows the primary scrollable. Split by field. |
| Stale answers | The engine drops them (after a route change or a newer watch, or unsolicited). JS echoes the request token. |

Why JS builds it: identity parts exist only in JS. If native built the
inventory, its fingerprints would be native-view fingerprints, not RN
fingerprints, and would not match taps. The cost is that a sample needs the JS
thread, so a busy JS thread delays or loses it. That is the right failure: a
lost sample is a lost inventory, not a lost tap. JS builds in an idle turn and
caps the fiber walk at the engine's element limit while counting
`totalElements`.

Production capture builds no inventory and keeps `scene.watch` unarmed
(`emitSceneInventory` off), as on every adapter. Exploration inventory is
Blend-internal, so it can slip past release 1 if the box-source spike fails
(Q10). `resampleSettledInventory` stays an engine capability and needs nothing
from RN beyond the two effects above.

## 10. Pager pages (BLE-677)

Today the engine keeps a pager's page position apart from collapsed list
positions only through Flutter widget names (`PageView#`, `Scrollable#`;
stateful-engine.md section 4.3.2, "Who owns what"). Two RN pages built from one
component would share every path, and a page reached by swiping would not be
novel.

Proposal: a **toolkit-neutral explicit segment**, `[page:N]`, that the adapter
puts in the canonical path and the engine's novelty rule never collapses
(`[item:N]` still collapses). One engine change and one conformance fixture,
reusable by Views `ViewPager2`, UIKit and Compose pagers. The Flutter rule
stays. Because the page index is in the path it is part of the fingerprint,
which is right for pages: different pages are different targets. This needs the
BLE-677 engine and fixture work. Q11.

How JS marks pages:

| Source | Detection |
| --- | --- |
| `react-native-pager-view` (`PagerView`) | The pager's host component (name to confirm **[spike]**). Its direct children are pages, in child order. `@react-navigation/material-top-tabs` also uses it **[memory]**. |
| Horizontal `ScrollView` or `FlatList` with `pagingEnabled` | The prop on the scroll fiber. `[page:N]` replaces `[item:N]` for its cells. |
| Anything else | `Tugboat.registerPager(Component)` (reference match) or a `<Tugboat.Pager>` wrapper. |

The page index is the child order for `PagerView` and the cell `index` for
lists. A pager inside a list row gives `[item]` then `[page:N]`. Bottom tabs and
drawers need no marking: each tab is its own route, so the route key differs.

## 11. Session ids

PR #187: the host supplies a required `idSeed` (32 secure-random bytes) on
`session.start`, and the engine derives `session-<UUIDv4>` and `event-<UUIDv4>`
from it. The native hosts mint it from the OS secure random source, and mint
the installation id too.

React Native needs nothing extra:

- JS never mints a session id, event id or seed. `Math.random` is not a secure
  source. Ids JS creates (call tokens, mask ids, request tokens) are local,
  never sent as identity, and never in a fingerprint.
- `attach` returns the current session id for diagnostics only.
- A new session after a reload (section 5) gets a new seed from the host.
- Installation id: the host mints it. JS may pass a host-app override through
  `start`, as the Android and Swift configs accept one.

## 12. Hybrid apps and the host seam

Native screens around RN views (and the reverse) share one session and one
outbox (ADR 0009). The adapter needs one thing from the host that does not
exist yet: **a claim**. The RN adapter claims the React root view (an RN
surface). Inside it:

- the Views, UIKit and SwiftUI adapters must not resolve taps or emit routes,
  and must not build native-view fingerprints;
- they still contribute their text and media masks and secure-window handling
  (masks are a union, never a subtraction).

Outside it, native adapters run as usual. Anchors carry `toolkit`, so the
consumer separates them. Q6 asks for this host API in the Kotlin and Swift hosts
before the adapter ships.

## 13. Testing

- **Conformance.** Golden fixtures for identity parts to fingerprints, one set
  per role-table entry, plus the cross-OS pair of section 8.
- **Mask device tests** (amendment rule 4): section 3.3, Fabric on.
- **UI-thread budget** (rule 2): module `post`, the native tap hold, the mask
  supplier. JS-thread cost of the touch handler is measured too. Held by a
  benchmark in the adapter's tests.
- **Reload tests:** Fast Refresh, `DevSettings.reload`, host recreate (section 5).
- **Old architecture:** dormant with one log line, no crash.
- **Fiber-internals canary:** a test that fails loudly when a new React or RN
  version breaks the fiber walk, since identity falls back to `low` quietly.

## 14. Open questions for the user

| # | Question | Recommendation |
| --- | --- | --- |
| Q1 | Support the old architecture? If not, amend rule 4 ("Fabric on and off"). | No. Support RN 0.76+ with the New Architecture only, dormant with a log on the old one. Amend rule 4 to "Fabric on, mask inside layout-only parents". Revisit only if a customer is on 0.76 to 0.81 with the opt-out. |
| Q2 | JS sends mask **marks** and native reads rectangles at draw time, instead of JS sending rectangles (the ADR 0009 text). OK to deviate? | Yes. JS rectangles can be stale under Fabric. Amend the ADR 0009 sentence in the BLE-644 PR. |
| Q3 | `testID` as the alias. Add a JS-only `<Tugboat.Tag>` for dynamic ids? | Yes. `testID` stays the default and the docs say it must be stable. |
| Q4 | Route key: the path of names (`Main/Tabs/Home`) or the leaf name? | The path. The leaf alone collides (`Home` in two navigators). |
| Q5 | Manual `Tugboat.setScreen` for custom navigators; Wix RNN support? | Add `setScreen`. No Wix in release 1. |
| Q6 | Add a host "claim" API (RN root owns taps and routes, native tracking stands down for it) to the Kotlin and Swift hosts before release 1? | Yes. File it as its own issue; it blocks release 1. |
| Q7 | Add a host `restart` call (end and start a new session) for the detach rule? | Yes, with the "end unless no RN navigation fact was sent" policy. |
| Q8 | JS start only in release 1, native early start in release 2? | Yes. JS start is simpler and the Expo plugin stays small. Revisit when cold-launch evidence matters. |
| Q9 | Request mark by header (`x-tugboat-js`), stripped where possible. Accept that iOS may send it to the server? | Yes, in release 2. Revisit if native OS-level network lands with a better side channel. |
| Q10 | Is exploration scene inventory in release 1? | No. Ship it when the box-source spike passes. Production capture needs none. |
| Q11 | Engine change for `[page:N]` (BLE-677) instead of more Flutter-name rules? | Yes. One fixture, reusable by every toolkit. |
| Q12 | Tap-anchor hold: 100 ms on the host queue before sending `identity_unavailable`. | Yes as a start. Set the number from the benchmark. |

## 15. Could not verify

- The touch-event fiber field `event._targetInst`, fiber `elementType`,
  `memoizedProps` and the route-context provider walk (all **[memory]**, all in
  the spike).
- Host component names in the role table, and the cell `index` props for
  `FlatList` and FlashList.
- That a custom Fabric component container is never flattened on both OSes. The
  docs read describe `collapsable`, `testID` and `nativeID`, not custom
  descriptors.
- That `global.nativeFabricUIManager` is absent on the old architecture.
- That `expo/fetch` does not use XHR, and the Expo Go limit.
- `useNavigationContainerRef` in Expo Router, and that Expo Router is built on
  React Navigation.
- Web-like DOM APIs (`getBoundingClientRect`) as a box source.
- BLE-633's level names and whether inheritance resolves in the host or the
  engine (the issue is in progress; only its description was read).
- Sections 5 and 12 depend on host APIs (`restart`, claim) that do not exist.
- PRs #187 and #188 were read as open; their final text may change.
