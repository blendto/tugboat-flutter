# React Native adapter design note

Status: Decisions recorded, revision 3 · 2026-11-27 · BLE-642 (ADR 0009, rule 4 of the amendment) · spike results for RN 0.88 added in section 15.1 (BLE-681; `event._targetInst` does not exist on 0.88, see 15.2)

Working note, not product docs. It sits in `internal/docs/plans/` with the
other design notes ([native SDK design note](2026-10-12-native-sdk-design-note.md))
because it sequences a milestone and carries open questions. It is not an ADR
and not a host-integration page (`docs/publishing.md`). The parts that become
contracts move to `docs/` when the adapter ships: the `react-native`
canonicalization goes to `docs/design/capture-and-fingerprint.md` (one section
per toolkit, ADR 0009), and the RN column goes into the privacy model's adapter
mapping table (PR #190).

Scope of release 1 of `@tugboat/react-native`: session replay and fingerprints
(sessions, navigation, masked frames, taps, scrolls and text input with stable
fingerprints, the same on Android and iOS). Network evidence is release 2
(BLE-648, BLE-671). Error reporting is release 3. The exploration scene inventory
is later (Q10, decided): 0.1.0 ships without it. Brownfield is unknown, so
release 1 is pure React Native (Q6, decided). The network, inventory and pager
sections fix the seams the later steps need.

Sources: ADR 0009 and its amendment; `core/session-engine/docs/stateful-engine.md`
(including open PR #188, the settled re-sample); open PR #187 (`idSeed`); open
PR #190 (`docs/architecture/native-capture-contracts.md`, "Privacy model",
re-read on its branch; it is the source of truth for masking and is being
revised, so section 3 must be re-checked before release); `docs/design/capture-and-fingerprint.md`;
the Views, Compose and SwiftUI adapters (`ToolkitRegion.kt`, `AnimationProbe.kt`,
`LayerWalk.swift`); `core/session-engine/src/tap_evidence.cpp`; the Flutter
`tugboat_dio` package. Upstream React Native claims are marked **[verified]**
(read in current upstream docs on 2026-11-27), **[memory]** (known to the author,
not re-read) or **[spike]** (a pass/fail item in the spike, section 15). Nothing
marked [memory] or [spike] is a fact until the spike passes.

## 1. Summary of decisions

| # | Decision |
| --- | --- |
| 1 | New Architecture only. A TurboModule carries batched facts and a Fabric component carries the mask mark. The old architecture is not supported. |
| 2 | Native owns pointer facts, scroll offsets, focus, frame timing, pixels and mask rectangles. JS owns identity: it resolves the touched target from the React tree and sends identity parts. |
| 3 | The RN mask is one native container view, `<Tugboat.Mask override="inherit" or "sensitive">` (`<Tugboat.Sensitive>` is sugar), implementing the PR #190 contract as written. JS sends marks. Native reads rectangles at draw time (Q2, decided). |
| 4 | Navigation facts come from the navigation container state, diffed in JS. A navigator that appears late sends `push` for its initial route. Expo Router uses the same path. |
| 5 | A new JS context ends a session the RN adapter started and starts a new one. Brownfield is excluded from release 1 unless a waiting client needs it. |
| 6 | One npm package, autolinked. The Expo plugin only enforces minimums in release 1. Published native artifacts (BLE-638, BLE-639) are a blocker. |
| 7 | The identity token is a portable role from host component names, never component function names. `testID` is the alias. |
| 8 | Network is recorded in JS by wrapping `XMLHttpRequest` (release 2). It contradicts the roadmap's "native network for free" row. |
| 9 | Release 0.1.0 ships without the exploration scene inventory (Q10, decided). Its design is kept under "Later" (section 11). |
| 10 | Pager pages use an explicit `[page:N]` segment. Its format is fixed now because it is in the fingerprint. |
| 11 | A gated spike (section 15) comes before BLE-644. Nothing marked [spike] ships until it passes. |

## 2. Bridge

### 2.1 Architecture support

- React Native 0.82 runs entirely on the New Architecture. `newArchEnabled=false`
  and `RCT_NEW_ARCH_ENABLED=0` are ignored there. 0.81 and Expo SDK 54 are the
  last versions that allow the legacy architecture. Interop layers stay for
  third-party libraries. **[verified]** (RN 0.82 release post)
- The New Architecture became the default in 0.76. **[memory]**
- A TurboModule spec file name starts with `Native`, and `codegenConfig` in
  `package.json` names the generated output. **[verified]** (RN docs)

Decision: support **React Native 0.76 and later with the New Architecture on**
(Expo SDK 52 and later). Hermes is the tested engine. The old architecture is
not supported: the opt-out is gone in 0.82, a second renderer path doubles the
privacy surface, and the interop layer runs legacy libraries on the new stack,
not new code on the old one. The module detects the old architecture
(`global.nativeFabricUIManager` absent, **[spike]**), logs once and stays
dormant.

Amendment rule 4 says device tests run with Fabric on and off. With the old
architecture unsupported the "off" leg has nothing to test (Q1).

### 2.2 TurboModule and JSI

One TurboModule, `NativeTugboat`, in front of the native host:

| Direction | Mechanism | Used for |
| --- | --- | --- |
| JS to native | `post(batch: string): void`, async, fire and forget | All facts |
| JS to native | `attach(options): Promise<AttachResult>` | Start or re-attach (section 6) |
| JS to native | `getHostInfo()`, synchronous, once at start | Platform, density, session state |
| Native to JS | `NativeEventEmitter` | `sceneSample`, `sessionStarted`, `sessionEnded`, activation state |

Rules:

- **Batched.** JS queues facts and flushes once per frame-idle turn (bounded at
  50 ms), and at once for a tap anchor. Each batch carries `jsNowMs`
  (`performance.now()`), so native maps JS timestamps onto the host monotonic
  clock to within one transit delay. JS never reads the wall clock for evidence.
- **No synchronous call on a touch path.**
- **JSON strings**, the engine's message format, so the conformance fixtures
  are the same on every adapter.
- **Never throws into the app.**
- **Lifetime.** The module instance belongs to one React instance. The host
  (engine, outbox, session) is a process singleton and outlives it.
- **Depends on the native SDKs, not the engine** (ADR 0003).

### 2.3 Where each fact comes from

| Fact | Source | Why |
| --- | --- | --- |
| `input.pointer` down, move, up, `x`, `y` | Native (`Window.Callback` wrapper; key-window gesture recognizer) | The before-frame freezes on `down`, before JS runs. |
| `scroll` offsets, phases, `maxScrollExtent` | Native, observing the scroll views | RN `onScroll` does not bubble, so JS cannot see every scroll view. Section 5.1. |
| `focus {kind}` | Native (opt-in `captureFocusChanges`) | Section 5.2. |
| Tap and scroll target identity (anchors) | JS, touch handlers on `<Tugboat.Root>` | Identity is derived from the React tree. |
| `navigation` | JS, navigation container state | Route names exist only in JS. |
| Mask rectangles | Native, at draw time | Section 3. |
| Pixels | Native pixel runtime | Raw pixels never enter JS. |
| `scene.watch`, `scene.frame` | Later (section 11) | Not in 0.1.0. |
| `scene.inventory` | Later (section 11) | Not in 0.1.0. |
| `evidence.networkCall` | JS (release 2) | Section 9. |
| Lifecycle, launch, exit, delivery, outbox | Native host | ADR 0009. |

### 2.4 Tap timing

The engine wants the target resolved at the pointer **down** position and
attached to the `up` fact (stateful-engine.md section 9.1: the adapter resolves
"at the **down** position against the current tree"). Flutter resolves the tap
after `up`; React Native resolves at `down` because the touched fiber is known
then. This is a recorded deviation. Both attach the evidence to `up`.

Flow:

1. Native sees `down`, requests the before-frame, stamps the touch.
2. JS sees the same touch through `onTouchStartCapture` on `<Tugboat.Root>`
   (observes, never becomes the responder), resolves the target (section 10)
   and posts `tapAnchor {touchId, anchor}`.
3. Native matches JS and native touches by **`nativeEvent.timestamp` plus the
   touch `identifier`**, not by time and point. `pageX` is relative to the RN
   root, which in a brownfield app is not the window, so a point match is wrong
   there. Matching by timestamp and identifier needs the native event to expose
   the same values **[spike]**.
4. On `up`, native attaches the matching anchor. If none has arrived within a
   bound (proposal: 100 ms, on the host queue only, never the UI thread), the tap
   goes out with a failure reason (section 5.3).
5. **Facts behind a held `up` are held too**, native and JS alike, so order is
   preserved. A navigation fact that arrives during the hold is applied after
   the `up`.

Fact order of a press that navigates: native `up`, then the JS `navigation`
fact (the `onPress` runs on JS at touch end, after the anchor was posted at
`down`). That is the order Android Views produces. Stateful-engine.md section
9.3 item 6 says each adapter must document it because it decides `direct` versus
`delayedLikely`.

The fiber of the touched node was assumed to be `event._targetInst` **[memory]**.
**Spike (15.2): that field does not exist on RN 0.88.** `event.target.__internalInstanceHandle`
is the fiber there. The resolver tries `_targetInst`, then `event.target.__internalInstanceHandle`,
then a tag search, and falls back to route-only identity (`low`), never throws.

## 3. Masks

PR #190's `docs/architecture/native-capture-contracts.md` (Privacy model, and
its "React Native" section) is the source of truth. This section says only what
is specific to React Native and links the contract for the rules. Re-check
against #190 before release.

### 3.1 The problem

Under Fabric the JS tree is not the view tree. React commits the shadow tree on
the JS thread and mounts views later on the UI thread. Layout runs in C++ off
the JS thread, and JS has no synchronous layout for a fiber. Fabric removes
layout-only views (view flattening); `testID`, `nativeID` and
`collapsable={false}` keep a view. **[verified]** (RN docs, "View flattening" and
"View"). Animation libraries move views on the UI thread without JS knowing
**[memory]**. JS rectangles can therefore be stale or point at a view that does
not exist. For a mask that is a privacy bug.

### 3.2 Mapping onto the privacy model

The component implements the contract as written. Nothing is added to it.

| Contract | React Native |
| --- | --- |
| `MaskOverride = inherit \| sensitive`, absent means `inherit` | `<Tugboat.Mask override="inherit" \| "sensitive">`: one prop with exactly those two values, absent is `inherit`. `<Tugboat.Sensitive>` is sugar for `override="sensitive"`, named for Flutter parity (`TugboatSensitive`). No per-dimension props, no `reveal`, no touch masking. |
| `MaskLevel`, default `allTextAndMedia` | `Tugboat.start({ maskLevel })`. Only `allTextAndMedia` is implemented. This config parses a string, so the contract requires a parse point and a test: JS validates at `start`, native re-validates, and an unknown value becomes `allTextAndMedia`, never a narrower level. |
| Inheritance and the effective mask | Resolved in the host from the native view tree. Native ancestry equals React ancestry because the mask view is never flattened **[spike]**. No mask tree goes to the engine. |
| Override is not identity | A mask never changes tags, paths or fingerprints. Conformance fixture: the same React tree with and without the mask component gives the same fingerprints. |
| Fail-closed ladder | Element at its own bounds, then the **region host** (the React root view), then the whole frame (section 3.3). |
| `MaskCoverage` and the engine's closed reasons | Reported per frame with existing reasons only: `regionUnreadable`, `treeUnreadable`, `animating`, `interop`, `webView`, `renderer`, `surfaceLayer`, `unclassifiedLayer`, `overlayWindow`. A new reason is a contract change in the engine's `capture_types`; none is proposed. |
| `sensitive` covers the region and every descendant at its own bounds | RN children overflow their parent by default, so the host unions the bounds of the descendants, not only the mark view's bounds. |
| Secure input, bundled asset (used by narrower levels) | Not needed at `allTextAndMedia`. When a narrower level is added, a secure input is a text input with `secureTextEntry` or an email, phone or visible-password keyboard type, and a bundled asset is an image whose source came from a `require()` of a local file (resolved asset source), as the contract says. An unknown source is not a bundled asset. |
| Classification gaps are violations | Anything `allTextAndMedia` says it masks must be classified. Section 3.4 boxes every unknown native view, so an unclassified view is masked, not left visible. |
| Touch | An accepted residual in the contract: a tap inside a `sensitive` region still records the target identity and position. The RN adapter does not suppress it. The follow-up is the contract's. |
| Tests | The contract's two properties (a mark adds and never removes, an unplaceable mask masks more) plus section 3.5. The contract says "New Architecture on and off"; with the old architecture unsupported (Q1, decided) the off leg is dropped and the contract text needs the same amendment. |

### 3.3 The mask view

- `<Tugboat.Mask>` renders a Fabric component, `TugboatMaskView`, with its own
  component descriptor and `collapsable={false}` set anyway. It is a real
  container view, so a flattened parent cannot remove it **[spike]**.
- **Layout-neutral.** The view uses the shadow-node layout of a plain `View` (no
  props that add size, margin or position), passes its style prop through, and
  draws nothing. Adding it must not move a pixel; a layout test checks a tree
  with and without it **[spike]**.
- **Rectangles are read at draw time.** The host's mask supplier runs in the same
  main-thread turn as `PixelCopy` / `drawHierarchy`, as the SwiftUI and Android
  adapters do (native note, section 2). It reads the real window bounds of each
  mark and of every descendant, so scrolled, animated and overflowing content is
  where native has it. JS sends marks, not rectangles (Q2, decided).
- **Expected marks.** On mount JS registers `expectMask(id)` (no level). The
  native view attaches with the same `maskId`.
- **"Missing" means never created.** An expected id whose native view was
  **never created** after a bound (proposal: two flushes) cannot be placed: mask
  the **region host** and report `regionUnreadable`. A view that was created and
  is now **detached** is not missing: a detached view draws nothing. That matters
  because `react-native-screens` detaches covered screens, `removeClippedSubviews`
  detaches off-screen rows, and inactive tabs stay mounted **[memory]**. A rule
  that fired on detachment would mask the whole frame constantly. A detached view
  that reattaches is masked from the first frame it is drawn in.
- **If the region host cannot be read**, mask the whole frame.
- **Overlays and modals** follow the contract: content behind a modal, sheet,
  menu, drawer or scrim is still painted, so it is masked as if the overlay were
  absent, and the overlay's own content is masked too. The walk skips only what is
  not painted (hidden, offscreen, zero-sized, detached). It never prunes a screen
  because another screen or a scrim covers it. For React Native this means an
  attached `react-native-screens` screen under a pushed or modal screen is still
  walked, and a transparent modal or a translucent scrim does not exempt what is
  behind it. A `Modal` on Android is a separate Dialog window that the
  activity-window copy does not paint; the frame carries `overlayWindow` and the
  Dialog's content is not in the pixels (a gap for pointer facts, section 5.5).
- **Animating.** The existing adapters mask the whole frame while something
  animates whose layout bounds do not describe where it draws (Android
  `AnimationProbe.kt`: a running legacy `View` animation or `LayoutTransition`;
  iOS `LayerWalk.swift`: non-empty `animationKeys()`, reason `animating`). The RN
  walk reuses those probes on the React root's native subtree. Whether Reanimated
  and `react-native-screens` transitions are covered is a **[spike]** item.

### 3.4 Automatic masks under `allTextAndMedia`

- **Allowlist by type, not by name.** The walk classifies native views by an
  allowlist of RN-core view classes referenced **by type** in the native code
  (`ReactTextView`, `ReactEditText`, `ReactImageView`, `ReactViewGroup`,
  `ReactScrollView` and equivalents on iOS; names **[memory]**), so R8 and Swift
  stripping cannot change the result. Text and text input are `text`. Image is
  `media`.
- **Every unknown native view is `media` and boxed.** Skia canvases, maps, video,
  `WebView`, `SurfaceView`, `TextureView` and any third-party native component off
  the allowlist are masked over their whole bounds, as SwiftUI does for its
  unverified layer allowlist. Plain RN containers (`ReactViewGroup`, scroll views)
  are walked, not boxed.
- **RN's own view classes must be classified.** The allowlist names RN's text,
  text input and image view classes on each OS and version in the supported
  range (spike item S3). A text, input or image class that is not classified is a
  violation of the contract, not a residual.
- **Unverified RN version, or an unknown drawing view:** mask the **React root
  view whole** (region host, reason `regionUnreadable`). This is the posture
  Compose takes on an unverified version. An unknown drawing view that cannot be
  boxed (its bounds cannot be read) takes the same fallback.

### 3.5 Device tests (Fabric on)

- a mark inside nested layout-only `View`s, default `collapsable`;
- a mark with **overflowing children**;
- a mark under an animated transform, and inside a `ScrollView`;
- a mark unmounted mid-capture;
- a mark whose native view is never created (test hook): region host masked;
- a **covered stack screen** (`react-native-screens`) with a mark: no whole-frame
  mask, no leak, and the covered screen's text still masked while attached;
- a **transparent modal** over a screen: both are masked;
- a **clipped list row** (`removeClippedSubviews`) with a mark;
- an **inactive tab** that stays mounted and holds a mark;
- a **native-stack push** while a mark is on the screen below;
- an unknown third-party native view: boxed;
- each case checks pixels under the expected rectangle.

## 4. Navigation

### 4.1 React Navigation

Facts **[verified]** (React Navigation docs): the container has `onStateChange`
(use only `index` and `routes`; the rest is internal), `onReady`, and a ref with
`getRootState`, `getCurrentRoute`, `getCurrentOptions` and `addListener`
(`state`, `options`, `ready`).

Design:

- `Tugboat.trackNavigation(navigationRef)` subscribes with
  `addListener('state')` and `ready`, so it does not replace the app's own
  `onStateChange`.
- **Ids.** `navigatorId` is the navigator state `key`. `parentNavigatorId` is the
  enclosing state's key. The route `instanceId` is `route.key`.
- **Diff.** Per navigator, by route keys: a key added on top is `push`, the top
  removed is `pop`, the top replaced is `replace`, a non-top key removed is
  `remove`. A `reset` goes out as the equivalent facts, in order.
- **Seeds on every session start.** The tracker sends `navigation session_start`
  (visible chain last, stateful-engine.md section 8.1) at `ready` **and every
  time native reports `sessionStarted`** (activation, a new request id, a
  restart), not only once at container ready. Otherwise a second session has no
  stack.
- **Late navigators send `push`.** The engine drops a `session_start` seed once
  a session has had a live navigation (section 8.1). A lazy tab, an auth switch
  that mounts a new navigator, or a navigator in a brownfield screen mounts after
  that point, so it sends `push` for its initial route, as Flutter's nested
  observers do. A seed is only for navigators that exist at session start.
- **One path string everywhere.** The route key is the path of route names from
  the root to the route (`Main/Tabs/Home`), no params. The navigation fact's route
  `name` and every anchor's `routeKey` use that same string.
- **Controls outside the focused leaf.** A tab bar or a JS header belongs to the
  navigator's host route, not to the focused tab. Its anchor's route root is the
  **nearest enclosing route** found by the route-context provider walk
  (`Main/Tabs`), not the focused leaf. A tab-bar button then has the same
  fingerprint on every tab. Controls inside a leaf use the leaf path. Without a
  provider the root is `rn:root`.
- **`overlayKind`** from `getCurrentOptions().presentation` of the focused route
  (`modal`, `transparentModal`, `formSheet`; else `page`). `transitionMs` follows
  the engine defaults until measured **[spike]**.
- **Tab switch** sends no navigation fact today, as SwiftUI tabs do (decision log:
  the engine's visible route does not move). Q13.
- **No native duplicates.** `react-native-screens` creates real fragments and
  view controllers. Native fragment and view-controller navigation tracking is
  suppressed under the RN root (section 8).

### 4.2 Expo Router

Expo documents screen tracking with `usePathname` and `useGlobalSearchParams`,
an experimental focus-mark API in newer SDKs, and advises against `onReady` and
`onStateChange` where possible. **[verified]** Expo Router being built on React
Navigation is **[memory]**.

Use the same container-state path through the navigation ref Expo Router exposes
(`useNavigationContainerRef`, **[spike]**). Route names are file-structure names
(`(tabs)/index`, `profile/[id]`), so the key is already a pattern with no params.
`usePathname` is not used (concrete URLs can hold ids). The experimental focus API
is not used.

### 4.3 Other

Wix `react-native-navigation` is out of scope. `Tugboat.setScreen(name)` covers
custom navigators (Q5).

## 5. Scroll, text input, tap rules

### 5.1 Scroll facts

The engine wants `scroll {scrollableId, phase, offset, maxScrollExtent, anchor}`,
the anchor attached at `start` (stateful-engine.md section 9.1).

- **Offsets and phases: native.** The host observes scroll views: Android
  `OnScrollChangedListener` and the scroll views' listeners, iOS KVO on
  `contentOffset` of `UIScrollView`s (as the Views and SwiftUI adapters). RN
  `onScroll` does not bubble to a root wrapper **[memory]**, so JS cannot see every
  scroll view. `scrollableId` is the native view's stable id (the React tag).
- **Anchor: JS, with the down anchor.** When JS resolves a touch it also walks
  the touched fiber's ancestors and sends the anchors of every **scrollable
  ancestor** with the down anchor, keyed by the scroll view's React tag (the
  native `reactTag` of the host node, **[spike]**). Native matches a scroll start
  to the nearest enclosing scrollable by tag and attaches that anchor.
- A scroll with no matching anchor (a programmatic scroll, an anchor not yet
  arrived) goes out without one.
- Horizontal scroll views (`AndroidHorizontalScrollView`) are scrollables like
  any other (section 10).

### 5.2 Text input

A text input is a tap anchor with role `TextInput` (section 10). Focus is the
engine's opt-in `focus {kind: text_input|other|none}` fact, sourced natively:
Android `OnGlobalFocusChangeListener` (the focused view is an edit text), iOS
begin- and end-editing notifications. Typed text is **never** recorded and never
read by JS. Secure and obscured inputs are masked as `text`.

### 5.3 Tap failure reasons

`identity_unavailable` is not in the engine's closed set
(`tap_evidence.cpp`): `no_target_at_point`, `no_scene_inventory`,
`no_actionable_candidate`, `outside_capture_boundary`, `stale_route_generation`,
`opaque_platform_view`, `system_ui`, `resolution_error`. Map onto it, no contract
change:

| Situation | Reason |
| --- | --- |
| Hold timed out, JS detached, JS threw | `resolution_error` |
| The touched native view is not React-managed (section 5.4) | `opaque_platform_view` |
| System-owned UI (an alert, a system picker, the status bar) | `system_ui` |
| JS ran and found no actionable fiber at or above the touched node | `no_actionable_candidate` |
| The touch is outside the capture boundary | `outside_capture_boundary` |
| Route changed between down and resolution | `stale_route_generation` |

### 5.4 Target selection and native-only targets

- **Selection rule, as Flutter.** Walk up from the touched fiber. The target is
  the **innermost** fiber with an actionable role (`Pressable`, `TextInput`,
  `Switch`, `Scrollable`) at or above the touched node. A bare `View` or `Text`
  under a pressable resolves to the pressable.
- **Anchor fields.** `widgetType` is the role token, `role` the role,
  `actions` (`tap`, plus `longPress` when `onLongPress` is set), `enabled`
  (false when `disabled` or `accessibilityState.disabled`; a disabled control
  keeps its enabled twin's fingerprint, like Flutter). Plus `toolkit:
  "react-native"`.
- **Native-only targets inside the root.** The native-stack back button, native tab
  bars, `Alert`, pickers and date pickers are real native views, not React nodes.
  Native sees them at `down`: the hit view is not React-managed (no React tag,
  **[spike]**), so native decides **at once**, with no hold, to send `opaque_platform_view`
  (or `system_ui` for a system dialog). The hold only applies when the hit view is a
  React-managed view and JS has not answered.

### 5.5 `<Tugboat.Root>`

- One component wraps the app at the JS root. It renders a plain `View` with
  `collapsable={false}` (or `onTouchStartCapture` on an existing root), registers
  the root view with native (`registerRoot(rootTag)`), and carries the touch
  handlers. It never becomes the responder.
- **Expo Router:** place it in the root layout (`app/_layout.tsx`) around the
  layout's output. There is one React root.
- **Multiple RN roots** (brownfield: several `RCTRootView`s or React surfaces):
  each root mounts its own `<Tugboat.Root>`, registers its `rootTag`, and has its
  own tracker and path root. Facts carry the `rootTag`.
- **RN `<Modal>`.** On Android it is a Dialog window, a separate window the
  activity-window copy does not see. The host reports `overlayWindow` for it
  (existing behavior) and the Dialog's contents get no pointer facts or anchors.
  This is a documented gap, as for native dialogs (native note, known gaps). On
  iOS a `Modal` is a presented view controller and the key-window capture includes
  it; its React tree is under a different RN root surface node, so the root
  wrapper must also cover it **[spike]**.

## 6. Hot reload and a recreated bridge

The host is a process singleton. JS state is per JS context.

| Event | JS | Rule |
| --- | --- | --- |
| Fast Refresh | State kept | `start` with an equal config is a no-op (native `start` is idempotent). Tracker resubscribes, no new seed while the container lives. |
| Full reload, OTA reload, Bridgeless host recreate | New JS context | Detach, then attach (below). |
| Android activity recreate, React host survives | JS survives | Nothing. |
| Brownfield: RN screen closed, host destroyed, reopened | JS gone, native screens continue | Excluded from release 1 (below). |

Rule: a new JS context **always ends a session the RN adapter started** and starts
a new one, with a new `idSeed` (`session_end`, then seeds). The engine drops a
navigation seed once a session had a live navigation, and the new JS context
restarts its navigators at their initial routes, so re-attaching would leave
stale stacks. Cost: one short session on an OTA reload in production, many in
development. This needs a host `restart` (Q7).

Detach state: from `invalidate()` to the next `attach`, RN surfaces carry no
anchors (`resolution_error`). Masking is unaffected: native masks need no JS, and
an expected mark with no native instance masks the region host. After a grace
period with no attach (proposal: 5 s) the host treats RN surfaces as opaque.

**Brownfield is excluded** from this rule. A session started by the **native app**
(its own `Tugboat.start`) is never ended by a JS context change. The RN adapter
only attaches; its navigators send `push` facts for their initial routes (section
4.1). Stale entries from the dead context remain on the engine's stack: a known
gap. Closing an RN screen in a native app never ends the app's session. Full
brownfield support waits for a client that needs it (Q6).

## 7. Packaging

| Item | Decision |
| --- | --- |
| npm package | `@tugboat/react-native`: TypeScript source and build, `android/`, `ios/`, `app.plugin.js`. Peer deps `react`, `react-native` (>=0.76); optional peers `react-native-pager-view`, `@react-navigation/native`, `expo`. |
| Codegen | `codegenConfig` of type `all` (TurboModule `NativeTugboat`, component `TugboatMaskView`), Java package `com.tugboat.reactnative`. |
| Android | Gradle library depending on `com.gettugboat.sdk:tugboat-android` from Maven Central. minSdk 26. |
| iOS | `TugboatReactNative.podspec` depending on the `Tugboat` pod (`TugboatSDK.podspec`). RN on iOS builds with CocoaPods, so a published podspec is required. iOS 15. |
| Autolinking | RN CLI and Expo autolinking from `package.json`, `android/build.gradle` and the podspec. |
| Expo config plugin | `app.plugin.js` at the package root re-exporting a compiled plugin, `expo` an optional peer. **[verified]** Plugins run at `expo prebuild` and may edit `AndroidManifest.xml` and `Info.plist`. **[verified]** Release 1: enforce minimum SDK and deployment target; fail prebuild when the New Architecture is off. |
| Expo Go | Cannot load custom native code **[memory]**. A development build or prebuild is required. |
| Versions | Independent (ADR 0008). Exact native pins; a compatibility-table row. |
| Workspace | A new npm workspace in this repo. Out of scope here. |

**Blocker: publishing.** `tugboat-android` on Maven Central and the `TugboatSDK`
podspec on CocoaPods are unpublished today (BLE-638, BLE-639). `TugboatAlamofire`
is SwiftPM only. The adapter cannot ship until both are published.

**Android late start.** The host learns activities only from lifecycle callbacks
registered at `Tugboat.start` (`LiveActivities`: created and resumed are seen
after registration). A JS `Tugboat.start` runs after the first activity has
resumed, so the host finds no window and takes no frames or pointer facts for it
**[verified from `LiveActivities.kt`; the failure path is a spike item]**. Two
fixes: an **adopt-current-activity** seam on the host (find the resumed
activity at start), or an **early initializer** that registers the callbacks
before JS (a `ContentProvider` or `Application` init). This affects Q8: JS start
is acceptable only with the adopt seam or the early initializer.

## 8. Host seam: regions

Android already has a region seam: `ToolkitRegion.kt` (Compose uses it). The Views
adapter consults registered regions before its own rules. The Swift host has no
equivalent. The RN adapter extends the Android seam and needs a Swift one. It
differs from Compose in four ways:

| Difference | Compose today | React Native needs |
| --- | --- | --- |
| Tap target | `targetAt(host, x, y)` is synchronous | The anchor is **asynchronous** (JS answers after `down`). The seam needs a pending-anchor result or a hold. |
| Route key | The Views route (the host's activity, fragment or destination) | The **region supplies its own route key** (path of route names). |
| Path prefix | `Compose#0/...` (host path prefix) | **No host-path prefix.** `Compose#0/` would put an Android-only segment in RN fingerprints and break cross-OS equality. |
| Navigation | The host's own tracking continues | Native **fragment and view-controller navigation is suppressed** under the RN root (`react-native-screens` creates real ones). |

Region host: the React root view (one per registered root). Masks: the host walks
RN's native subtree with the allowlist of section 3.4 and uses the region
coverage modes (`precise`, `wholeHost`).

For a pure RN app ("RN owns its root", release 1) this is enough. Hybrid apps with
native screens and RN screens in one session need more (taps outside the root keep
native fingerprints, mixed navigation); that is the later full "claim" (Q6).

## 9. Network evidence (release 2, BLE-648 / BLE-671)

Recorded in **JS**, with one route resolver for both OSes.

**Contradiction recorded.** `internal/docs/roadmap/native-capabilities.md` row 6
says RN gets OS-level network "for free" (an OkHttp interceptor and
`URLProtocol`, because `fetch` uses them). This note proposes JS wrapping instead.
The two cannot both record the same request. Reconcile before release 2: either
the native capability is off for RN-originated traffic, or JS wrapping is
dropped. The reason for JS: one app-owned route resolver and one set of
semantics on both OSes.

`fetch` and axios's RN adapter sit on `XMLHttpRequest` **[memory]**. The adapter
wraps `XMLHttpRequest.prototype.open`, `send` and the `loadend` family at
`install`. Known gaps **[memory]**: `expo/fetch`, and libraries that call native
networking directly.

### 9.1 JS API (matches `tugboat_dio` and the native helpers)

```ts
Tugboat.network.install({
  routeResolver: ({ method, url }) =>
    url.startsWith('https://api.example.com/orders') ? '/orders' : null,
  errorBodyUrls: [],        // same policy and defaults as tugboat_dio
  errorBodyDenyUrls: [],
});

const call = Tugboat.beginNetworkCall('POST', '/orders');
call.complete({ statusCode: 201, attemptCount: 1, errorResponseBody });
call.fail({ failure: 'network_error' /* or 'cancelled' */, statusCode });
```

Semantics, as `tugboat_dio` and `Tugboat.beginNetworkCall`:

- The resolver runs once per request at `send`, only while evidence is accepted.
  It sees the method and URL string, never headers or bodies.
- The result is trimmed. `null`, `undefined`, empty or a throw: **record nothing**.
  The route rules are the engine's.
- One call per request, finished once; later terminal calls are no-ops.
- `load` with a status is `complete`; `error` or `timeout` is `fail` network_error;
  `abort` is `fail` cancelled.
- Error body only for status 400 or more and `responseType` `''`, `text` or
  `json`, cut to 64 KiB before it crosses, bounded again by the engine. The URL
  policy checks the request URL and `responseURL`.
- No request body, success body, header, cookie or query is read.
- `attemptCount` is omitted by the wrapper. Times: JS `performance.now()` at
  `send` and `loadend`, mapped by the batch offset. One `evidence.networkCall`
  message at the end.

### 9.2 Request mark

Every request the wrapper sees is marked, whether or not it was recorded, so a
native adapter with its own resolver does not record what the app chose not to.
Mechanism proposed: a request header (`x-tugboat-js`) the native adapters skip
and strip where the stack allows. **Defer, lean no (Q9):** a header added to
customers' servers can break CORS-strict endpoints and signed requests (signature
over headers), and on iOS it cannot be stripped. Reconcile with the roadmap first;
prefer a native side channel that adds nothing to the request.

## 10. Identity: canonicalization for `toolkit: react-native`

Moves to `docs/design/capture-and-fingerprint.md` when the adapter ships. The hash,
`fingerprintParts` and confidence tiers are shared. Anchors carry
`toolkit: "react-native"` (already in the engine's closed set), not a hash input.
JS computes the parts and never hashes. The adapter emits the current shared
fingerprint schema version (7 in the design doc today; the native hosts' stamp
and the BLE-670 alias work are to be confirmed before release).

- **Source.** The committed fiber tree, from the touched fiber up. Read-only.
- **Why not function names.** Hermes release builds minify them. Identity uses
  values that survive minification: host component names from view configs,
  string `testID`, numbers, and component **references** compared by identity
  (our own components, registered pagers).
- **Token: a portable role from host component names.** The table is versioned.

  | Role | Source (host names **[memory]**, finalized in the spike) |
  | --- | --- |
  | `Pressable` | a fiber with `onPress`, `onPressIn` or `onLongPress`, on its nearest host node |
  | `TextInput` | `AndroidTextInput`, `RCTSinglelineTextInputView`, `RCTMultilineTextInputView` |
  | `Switch` | `AndroidSwitch`; iOS `RCTSwitch` (spike 15.4, 0.88) |
  | `Scrollable` | `RCTScrollView`, **`AndroidHorizontalScrollView`**, and any other per-OS scroll host (without it, carousels differ across OSes) |
  | `Image` | `RCTImageView` |
  | `Text` | `RCTText`, `RCTVirtualText` |
  | `View` | `RCTView` |
  | `Node` | anything else |

  A third-party component gets the role of its host root. Its JS name never enters.
- **Segments.** `Token#<ordinal>`; with a `testID`, `Token#<testID>`
  (`Token#<testID>#<ordinal>` if it repeats). Ordinals count same-token siblings
  after filtering.
- **testID in the structural segment.** A dynamic `testID` (`item-${id}`) therefore
  changes the structural fingerprint, not only the alias. `testID` values must not
  carry user data (ids, names, emails): they enter the path. Config switch
  `identity.testIdInPath` (default on) lets an app turn it off; `Tugboat.Tag`
  (below) is the stable alternative.
- **Excluded.** Not rendered, zero opacity, zero size, `pointerEvents: 'none'`
  subtrees. **SDK components are transparent**: they add no segment, and their
  children are still walked (not excluded with their subtree).
- **Kept.** Pressables, text inputs, switches, scrollables, nodes with a `testID`,
  maskable leaves. Everything else collapses.
- **Lists.** A list cell is recognized **without function names** by its prop shape:
  a numeric `index` prop together with a `cellKey` (`FlatList`, spike 15.5); FlashList 2 does
  not match this and needs a second branch (`ViewHolder` props, not yet run). It adds `[item:<index>]`. Without a match the
  segment is `[item]` at `low`. The index, not the key, matches Flutter and Android.
- **Pager.** Section 12.
- **Route key.** Section 4: the path of route names of the nearest enclosing
  route, no params. The route is found by comparing a provider fiber's context
  against the exported `NavigationRouteContext` **by reference**, including the
  React 19 provider shape **[spike]**. Without a tracker: `rn:root`, `low`.
- **Alias.** The nearest `testID` at or above the target gives `tagFingerprint`
  and does not change the structural fingerprint apart from the segment rule
  above. `accessibilityLabel`, placeholder, visible text and `nativeID` never
  enter. `<Tugboat.Tag id>` is a JS-only wrapper for stable ids (Q3).
- **Confidence** follows Flutter 0.12, not the older native sections: a tag does
  **not** raise confidence to `high`. `high` is reserved. `medium` is a usable
  structural path (own `testID`, list item); `low` is ambiguous structure or a
  route fallback. The floor of route and path applies.
- **Coordinates.** dp on Android, points on iOS, window origin.
- **Guarantee, narrowly stated.** The same source and the same React Native
  version give identical fingerprints in **debug and release Hermes builds on
  both OSes**. A different React Native version may rename a host component and
  is a role-table change and a schema-version question. Cross-build stability is
  not promised (AGENTS.md). The test: one app, four builds (debug and release,
  iOS and Android), compare fingerprints for a fixed interaction script.

## 11. Later: settled re-sample and the scene inventory

**Decided (Q10, 2026-11-27): `@tugboat/react-native` 0.1.0 ships without the
exploration scene inventory.** Release-1 fingerprints do not depend on it. This
section keeps the design for the release that adds it. Nothing here is built
now: no `scene.watch` effect is executed, no frame callback runs, no inventory
is sent.

Facts (stateful-engine.md section 4.3.2, PR #188): the engine owns the settled
re-sample. It emits `scene.watch {armed}` and `scene.sample`, takes `scene.frame
{}` from the host (at most once per 100 ms while armed), and takes the answer as
`scene.inventory {resample: true, ...}`. Exploration metadata (`trigger`,
`surface`, `viewport`, `scroll`, per-element `visibleFraction`, `tag`,
`positional`) rides on the fact. A host that does not run the watch ignores
both effects, which is what 0.1.0 does.

| Piece | Owner (later) |
| --- | --- |
| Novelty, windows, caps, de-duplication | Engine |
| `scene.watch`: arm drawn-frame callbacks, send `scene.frame` | Native host. No JS. |
| `scene.sample` | Native receives the effect and emits `sceneSample` to JS. **JS answers.** |
| The inventory (elements, identity, `tag`, `positional`) | **JS**, from the visible route's fiber tree, using section 10. |
| Element boxes and `visibleFraction` | **Primary: native, by React tag.** JS names the elements; native fills the window box and visible fraction from the mounted view. `getBoundingClientRect` and DOM-like APIs are an optional alternative **[spike, later]**. |
| `viewport`, `scroll`, `surface` | Native (window, insets, keyboard); JS names the primary scrollable. |
| Stale answers | Dropped by the engine. JS echoes the request token. |

JS builds it because identity parts are in JS; a native-built inventory would
carry native-view fingerprints that do not match RN taps. A busy JS thread
delays or loses a sample, which is the right failure.

Later spike items (not in the gated spike of section 15): box source by React tag
on both OSes; a JS fiber walk capped at the engine's element limit.

## 12. Pager pages (BLE-677)

Today the engine keeps a pager's page position apart from collapsed list positions
only through Flutter widget names (`PageView#`, `Scrollable#`). Two RN pages built
from one component share every path.

**The segment format is fixed now, because it is in the fingerprint** (Q11,
decided): `[page:<zero-based index>]`, placed after the pager's own `Scrollable`
token segment, never collapsed. Tap and scroll anchors in 0.1.0 already carry it.
The **engine rule** (the novelty rule keeping `[page:N]` apart, plus its fixture)
is **later**, with the inventory it serves.

| Source | Detection |
| --- | --- |
| `react-native-pager-view` | The pager's host component (name **[spike]**); direct children are pages in child order. |
| Horizontal `ScrollView` or `FlatList` with `pagingEnabled` | The prop on the scroll fiber. |
| Anything else | `Tugboat.registerPager(Component)` (reference match) or `<Tugboat.Pager>`. |

Bottom tabs and drawers need no marking.

## 13. Session ids

PR #187: the host supplies a required `idSeed` (32 secure-random bytes) on
`session.start`; the engine derives session and event ids from it; the host mints
the installation id. React Native needs nothing extra. JS never mints a session id,
event id or seed (`Math.random` is not a secure source). Ids JS creates (call
tokens, mask ids, touch ids) are local and never identity. A new session after a
reload gets a new seed from the host. `attach` returns the session id for
diagnostics only.

## 14. Testing

- **Conformance.** Golden fixtures for identity parts to fingerprints; one per
  role-table entry; **same fingerprint with and without `<Tugboat.Mask>`**;
  **debug versus release Hermes** and **iOS versus Android** for one script
  (section 10).
- **Mask device tests:** section 3.5, Fabric on.
- **UI-thread budget** (amendment rule 2): `post`, the tap hold, the mask supplier,
  and the JS touch handler. Held by a benchmark.
- **Unresolved-tap rate** (Q12): a counter of taps sent with a failure reason, per
  session, in the sample app and in canaries.
- **Reload:** Fast Refresh, full reload, host recreate.
- **Old architecture:** dormant with one log line.
- **Fiber-internals canary:** fails loudly when a new React or RN version breaks
  the fiber walk.

## 15. The spike

One gated issue, **before BLE-644**. Pass or fail per item. A failed item changes
the design and returns here.

Matrix: React Native **0.76**, a mid version (0.79 to 0.81), and **0.82 or later**;
**React 18 and 19**; Hermes **release** builds (minified) and debug; **Android and
iOS**; Fabric on. Sample app with React Navigation (native-stack, bottom tabs) and
Expo Router.

| # | Item | Pass |
| --- | --- | --- |
| S1 | Fiber walk: `event._targetInst` (absent on 0.88; see 15.2), `.return`, `memoizedProps` | Resolves the touched node and its ancestors on every matrix cell, in release builds. |
| S2 | Route-context provider walk, including the React 19 provider shape, compared against exported `NavigationRouteContext` by reference | Finds the route of a control on every cell. |
| S3 | Host component names per OS and version (text input, switch, scroll, horizontal scroll, image, text, view, pager) | The role table is complete and the same per role on both OSes. |
| S4 | FlatList and FlashList (v1 and v2) cell recognition and `index` by prop shape | `[item:index]` matches the data index on every list type. |
| S5 | The custom mask component: not flattened (with `collapsable={false}` set anyway), layout-neutral, ancestry preserved, inside `react-native-screens`, scroll views, `removeClippedSubviews` | A tree with and without it lays out identically and each mask is found. |
| S6 | Old-architecture detection (`nativeFabricUIManager`) | Dormant with one log, no crash. |
| S7 | Touch matching by `nativeEvent.timestamp` and `identifier` between JS and native | 100% matched on a scripted run, including brownfield offsets. |
| S8 | Scroll matching: native scroll start to the scrollable ancestor anchor by React tag | Correct anchor for nested and horizontal scrolls. |
| S9 | Native hit view: React-managed or not (native-stack back button, native tab bar, `Alert`) | Native decides `opaque_platform_view` or `system_ui` at `down`. |
| S10 | Animation probes cover Reanimated and `react-native-screens` transitions | No unmasked content during a scripted transition, or the probe is extended. |
| S12 | Android late start: JS `start` after the first resume | Frames and pointer facts work with the adopt-activity seam or the early initializer. |
| S13 | Modal, iOS: the key-window frame and the root wrapper cover a `Modal` | Frame correct and anchor resolved, or the gap is documented. |
| S14 | Debug versus release Hermes: identical fingerprints for a script on both OSes | Equal. |

### 15.1 Spike results (BLE-681, 2026-11-27)

**Scope actually run.** The user narrowed the spike mid-way ("get a working 0.0.1,
don't overengineer"): **React Native 0.88.1 only (React 19.3.0), New Architecture,
Android phone first, iOS simulator debug as a cross-check.** The 0.76 and mid
version matrix and the React 18 leg were dropped, so they are **not tested** (the
0.76.9 and 0.80.3 apps were created and `pod install`ed, nothing more). Everything
below is therefore an observation of one RN version; do not read it as the matrix
passing.

| Where | What |
| --- | --- |
| Android | Nokia 5.4 (Android 12, 720x1560), arm64, `assembleRelease` APK (Hermes bytecode, R8 off), real touches by `adb shell input tap`/`swipe`, `uiautomator dump`, `dumpsys activity top`, logcat. Spike package `com.tugboatspike.s88`, uninstalled afterwards. |
| iOS | iOS 27.2 simulator (iPhone 18 Pro), **Debug** only, real UIKit touches from an XCUITest, a native hierarchy dump written by the mask view. iOS **Release was not run** (time-box). |
| App | React Navigation 7 (native-stack, bottom-tabs), `react-native-screens` 4.30.1, `@shopify/flash-list` 2.3.3, a custom Fabric component `TugboatMaskView` (autolinked library with iOS `.mm` and Android Kotlin, codegen on). Probe code: [spike probes](2026-11-27-react-native-spike-probes.md). |
| Env facts | **iOS debug:** `nativeFabricUIManager` is an `object`, `RN$Bridgeless` is `true`, `__turboModuleProxy` is `undefined`. **Android release:** the env line showed `os: android`, `osVersion: 31` (API level), RN `0.88.1`, React `19.3.0`, `dev: false`, Hermes `Build: "Release"`, bytecode version 99; the Fabric and bridgeless fields were cut off in the capture, so they are **not recorded for Android** (the Fabric mask view and `react-native-screens` did render there). The Android lines quoted in this section are copied from the session output; the capture files were overwritten (see the probes doc). |

Result key: **pass** (observed), **fail**, **fallback** (works another way), **partial**,
**not run**.

| # | Item | Android (phone, release) | iOS (sim, debug) | Verdict |
| --- | --- | --- | --- | --- |
| S1 | Touched fiber | `event._targetInst` **absent**. `event.target` works | same | **fallback** (see 15.2) |
| S2 | Route-context walk, React 19 shape | path found, compared by reference | same | **pass**, with a duplicate-segment caveat (15.3). React 18 shape **not run** |
| S3 | Host names | table in 15.4, complete for core roles | table in 15.4 | **partial**: roles differ by OS, pager not run |
| S4 | List cell index | `FlatList` pass; FlashList v2 **fail** (rule as written) | same | **partial** (15.5) |
| S5 | Custom mask view | native views exist for the mask with `collapsable={false}` and for a mask without it, but the without-prop case also had `testID` and `onLayout` (15.6); layout neutral | same, plus the hierarchy dump | **pass with `collapsable={false}`**. "Survives without the prop" is **not isolated**. `react-native-screens`, `removeClippedSubviews` and animation **not run** |
| S6 | New Architecture detection | not logged (see Env facts) | `nativeFabricUIManager` = `object` | **pass on iOS** for "present"; Android **not recorded**. The old-architecture "absent" leg **not run** |
| S7 | Touch matching by timestamp + identifier | `nativeEvent.timestamp` is on the `uptimeMillis` scale (consistent with `MotionEvent.eventTime`); native side **not hooked** | **20 of 20** JS touches equal a native `UITouch.timestamp * 1000` within 0.001 ms; `identifier` was always `0` (single touch) | **pass** iOS, **partial** Android; multi-touch and brownfield offsets **not run** |
| S8 | Scroll matching by view tag | JS tag equals the native view id (`#54` = 84 outer, `#48` = 72 horizontal) | JS tag equals `UIView.tag` (84 outer scroll) | **pass** for tag equality. Native scroll-start to anchor matching **not run** |
| S9 | Native hit view: React-managed or not | **not run** | native-stack back button hit view is `_UIButtonBarButton` with `tag=0`; the JS root handler also fired | **partial** (15.6) |
| S10 | Animation probes | not run | not run | **not run** |
| S12 | Android late start | not run | n/a | **not run** |
| S13 | Modal, iOS | n/a | not run | **not run** |
| S14 | Debug vs release fingerprints | identity parts exist in release; no comparison made | debug only | **not run** |

Network (asked for in the narrowed scope; not an S item):

| Check | Result |
| --- | --- |
| Native OkHttp interceptor on Android (release) | **pass.** `NetworkingModule.setCustomClientBuilder(CustomClientBuilder { b -> b.addInterceptor { ... } })` in `Application.onCreate` saw `REQ` and `RES 200` for both a `fetch` and an `XMLHttpRequest` (`https://example.com/`). It also saw the probe's own `http://localhost` posts, i.e. everything RN's networking module sends. Observed live in logcat; the lines are quoted in the probes doc, the capture file was not retained. |
| JS wrapper on `XMLHttpRequest.prototype.open/send` (Android release) | **pass.** Saw the `fetch` call (it rides on XHR) and the direct XHR, with method, URL, status, duration and `responseURL`. Observed live; lines quoted in the probes doc, capture file not retained. |
| Not covered | Image loads (Fresco), `WebView`, libraries with their own OkHttp, `expo/fetch`; iOS (`URLProtocol` or the same JS wrapper) not run. |

### 15.2 S1: the touched fiber (changes the design)

- **`event._targetInst` does not exist in React Native 0.88 / React 19.3.** The
  touch event's own keys are `_defaultPrevented, _type, _bubbles, _cancelable,
  _composed, _rnIsDirect, _timeStamp, _nativeEvent, _dispatchConfig`. Section 2.4
  named `_targetInst` as the primary source (and the S1 row of section 15): that is
  wrong for this version. Older RN versions were **not run**, so whether they have
  `_targetInst` is unverified here.
- **What works** (every probed target, 0 misses). Android release: `Text` in a `Pressable`,
  `Switch`, `TextInput`, horizontal-scroll rows, the outer scroll, tab buttons, `FlatList`
  and `FlashList` rows (the `Switch`, `TextInput` and horizontal-scroll lines are from the
  first Android capture, which was overwritten; they are quoted in the probes doc). iOS
  debug: the same set, kept in `ios88-debug.log`.
  `event.target` is a `ReactNativeElement` whose own keys are `__nativeTag`,
  `__internalInstanceHandle` and `__viewConfig`. `event.target.__internalInstanceHandle`
  **is the host fiber** (`.return`, `.memoizedProps`, `.type` are all there).
  Proposed resolution order for the adapter: `_targetInst` (if present; unverified on older RN), then
  `event.target.__internalInstanceHandle`, then a search of the committed tree by
  `nativeEvent.target` (the React tag). The tag search is written in the probe but
  was never needed here.
- From the fiber the walk read, in the release build: host `type` strings,
  `memoizedProps.testID`, `onPress` (a function on the `Pressable` composite fiber),
  and `stateNode.canonical` for the tag. The innermost-actionable rule resolved a
  tap on a `Text` inside a `Pressable` to the `Pressable`, a tap on a `Switch` to
  `Switch`, a tap on `TextInput` to `TextInput`, and a tap inside a list row to the
  row's `Pressable`.
- **It is still an internal.** `__internalInstanceHandle` is a double-underscore
  field. The fiber-internals canary (section 14) must cover this exact path.
- **Function names in the release build.** Names of RN core components such as
  `Pressable`, `Text` and `View` came back readable and some wrappers came back as
  `object`. This was not a minification test (I did not confirm Metro's minify
  flag), so the rule stays: identity never uses function names.
- **Native-side identity for a tap** (the alternative the orchestrator asked
  about): Android exposes `testID` as the accessibility `resource-id`
  (`uiautomator` showed `btn-a`, `sw`, `hscroll`, `fl-1`, ...), the accessibility label
  as `content-desc`, and the native class and React tag in `dumpsys` (`#6` = `btn-a`
  = JS tag 6). iOS exposes `testID` as `accessibilityIdentifier` and the React tag as
  `UIView.tag`. So native can read a `testID`, a class and a tag for the hit view
  **without JS**. That gives a working **degraded identity** (class, `testID`,
  tag; no ancestor structure) when JS is unavailable, but it cannot produce the
  fingerprint's structural path: the flattened parents are not native views
  (15.7). JS identity stays primary.

### 15.3 S2: the route walk

- React 19 provider shape: the provider fiber has `tag === 10` and its `type` **is the
  Context object** (`type.$$typeof`, `type.Provider === type`); React 18 has
  `type._context`. The probe handles both; only the React 19 form ran.
  `NavigationRouteContext` (exported by `@react-navigation/native`) compared **by
  reference** against `fiber.type`, and `memoizedProps.value.name` gave the route
  name. This works in the release build on Android and in debug on iOS.
- **Caveat found:** the walk returned `Main/Main/Feed` for a tab screen inside the
  stack screen `Main` (expected `Main/Feed`), and the iOS log also shows `Detail/Detail`
  for a plain stack screen, while the tab route `Feed` was not doubled. So the doubling
  follows **native-stack screens**, not nested navigators: the stack route appears to be
  provided twice. A tap on the native-stack back button returned an **empty** route
  (the target is outside any route provider). The probe did not log `route.key`, so the
  cause is unconfirmed. The adapter needs to collapse consecutive providers with the
  same `route.key` (and a test for it).

### 15.4 S3: host component names (Fabric, RN 0.88.1)

Names are the fiber's host `type` string (the view config name). Native classes are
what the native allowlist (section 3.4) sees.

| Role | Android host type | Android native class | iOS host type | iOS native class |
| --- | --- | --- | --- | --- |
| View, `Pressable` | `RCTView` | `ReactViewGroup` (a `Pressable` is clickable and focusable) | `RCTView` | `RCTViewComponentView` |
| Text | `RCTText` | `ReactTextView` | `RCTText` | `RCTParagraphComponentView` |
| Text input | `AndroidTextInput` (single and multiline) | `ReactEditText` | `RCTSinglelineTextInputView`, `RCTMultilineTextInputView` | `RCTTextInputComponentView` |
| Switch | `AndroidSwitch` | `ReactSwitch` | `RCTSwitch` | `RCTSwitchComponentView` |
| Vertical scroll, `FlatList`, `FlashList` | `RCTScrollView` + a plain `RCTView` content child | `ReactScrollView` | `RCTScrollView` + child `RCTScrollContentView` | `RCTScrollViewComponentView` |
| Horizontal scroll | **`AndroidHorizontalScrollView`** + child `AndroidHorizontalScrollContentView` | `ReactHorizontalScrollView` | `RCTScrollView` + child `RCTScrollContentView` | `RCTScrollViewComponentView` |
| Image | `RCTImageView` | `ReactImageView` (Fresco) | `RCTImageView` | image component view |

- Differences the role table must absorb: text input (`AndroidTextInput` vs two iOS
  names), switch (`AndroidSwitch` vs `RCTSwitch`), horizontal scroll (a separate
  Android type), and the **content-view hosts**: iOS uses `RCTScrollContentView` for
  every scroll view, Android uses `AndroidHorizontalScrollContentView` for the
  horizontal one and a plain `RCTView` child for vertical ones (a tap on the list body
  targeted an `RCTView` child of the `RCTScrollView`). The content child must not get
  its own segment, or ordinals differ between OSes; because the Android vertical content
  child is an ordinary `RCTView`, it has to be recognized by position (direct child of a
  scroll host), not by type.
- Third-party hosts seen: `RNCSafeAreaProvider`, `RNSScreenStack`, `RNSScreen`,
  `RNSScreenContentWrapper`, `RNSScreenStackHeaderConfig`, plus `RNSScreenContainer`
  (Android) vs `RNSScreenNavigationContainer` and `RNSSafeAreaView` (iOS). The
  `DebuggingOverlay` host appears in iOS debug only. Role `Node` for all of them.
- `react-native-pager-view` was not in the app: pager name **not run**.

### 15.5 S4: list cells

- **`FlatList` (`VirtualizedList`) passes by prop shape, no function names.** The
  `CellRenderer` fiber's props include `cellKey`, a numeric `index`, `item`,
  `prevCellKey`, `horizontal`, `inversionStyle`, `onUpdateSeparators`. Taps in rows
  gave `index` equal to the data index: iOS `fl-1`, `fl-3`; Android release `fl-4`
  and `fl-6` (after a scroll).
- **`FlashList` 2.3.3 fails the rule as written** (`cellKey` or a `CellContainer`
  host): every tap in a FlashList row returned `cell: null`. FlashList 2 renders
  rows through `ViewHolder` (inside `ViewHolderCollection`); from its source
  (`recyclerview/ViewHolderCollection.tsx`, `ViewHolder.tsx`) the props are `index`,
  `item`, `trailingItem`, `layout`, `refHolder`, `onSizeChanged`, `target="Cell"`,
  `renderItem`, `extraData`, `CellRendererComponent`. A rule
  of "numeric `index` plus `target === 'Cell'`" is the likely second branch.
  **Not verified by a run**; FlashList 1 not run.

### 15.6 S5 and S9: the custom mask view, and native hit views

- **Survives flattening with `collapsable={false}` (iOS dump, `TugboatMaskView` tags in
  the hierarchy).** In three nested layout-only `View`s, the mask view was present and
  the three wrapper `View`s were flattened away (the mask's parent in the native tree is
  the scroll content view). **Caveat, not isolated:** the "without the prop" mask (A2)
  also had a `testID` and an `onLayout`, and either of those keeps a plain `View`, as
  does the `nativeID` and `onLayout` on the row B wrapper. The one mask with none of
  those (row D) was created with `collapsable={false}`. So the run shows the production
  shape works and does **not** show that a custom Fabric component survives without the
  prop; section 18's open question stays open. On Android the mask views exist as native
  `ViewGroup`s (the `uiautomator` tree shows `maskA` and `maskA2` with their `testID`s).
  Keep `collapsable={false}`.
- **Layout neutral.** Rows A (mask, `collapsable={false}`), A2 (mask without it), B
  (plain wrapper) and C (no wrapper) sit on an exact 29 dp (iOS) / 55 px (Android)
  pitch, and the mask's `onLayout` rectangle equals its child text's rectangle
  (390 x 17). Nothing moved.
- **Overflow (iOS dump):** a 200 x 40 child inside a 100 x 30 mask view has native
  bounds `[86, 175.7, 200, 40]`, outside the mask's `[6, 155.7, 100, 30]`, confirming
  section 3.2's rule that the host must union descendant bounds. Not checked on Android.
- **Native hit view and React management (S9).** `UIView.tag` is `0` for views that
  are not React component views, and non-zero for React ones; the native-stack back
  button's hit view was `_UIButtonBarButton` with `tag=0`. But views **inside** a
  React component view (`RCTUITextField`, `RCTEnhancedScrollView`) are also `tag=0`,
  and `conformsToProtocol:@protocol(RCTComponentViewProtocol)` is true for **every**
  `UIView` (it is a category), so it is not a usable test. The rule needs "walk to the
  nearest `tag != 0` ancestor, and treat a known allowlist of internal subviews as that
  ancestor", plus a check that the hit view is inside the React root. The JS root
  touch handler **also fired** on the nav-bar tap, so on iOS a tap on a native-stack header
  reaches JS with the target set to an ancestor (`RNSScreenStack`). Section 5.4 decides
  native-only targets natively at `down`, which still holds, but JS must not assume every
  touch it receives hit a React-managed view. `Alert`, native
  tab bars and Android: **not run**.

### 15.7 What this changes (recommendation for 0.0.1)

The plan holds on 0.88.1 (the only version run). The note's decision stays **0.76 and later**
(section 2.1, Q1, section 7); nothing below 0.88.1 was run, so 0.76 to 0.87 is untested
and a narrower range (for example 0.82 and later) is a scope option, not a result. Proposed
changes to the note:

1. **Identity source (sections 2.4, 10, 14).** Use `event.target.__internalInstanceHandle`
   first, `_targetInst` as a fallback (unverified on older RN), the tag search as the last
   resort. The canary tests this path on every RN bump. `_targetInst` is not usable on 0.88.
2. **Native degraded identity.** When JS identity is missing, native can still send
   class, `testID` (a11y id / `accessibilityIdentifier`) and React tag for the hit view.
   Treat it as `low` confidence; it is not a structural path.
3. **Role table (section 10).** Use the 15.4 names; scroll hosts keep the `Scrollable` role; the scroll
   *content* child (see 15.4), `RNS*` and `RNC*` hosts are `Node` (transparent); absorb the
   per-OS names.
4. **Lists (section 10).** `FlatList`: numeric `index` plus `cellKey`. `FlashList` 2:
   add a second branch for `ViewHolder` props; verify before relying on it.
5. **Route walk (section 4, 10).** React 19 shape confirmed; collapse duplicate
   consecutive providers by `route.key`.
6. **Mask (section 3.3).** A custom Fabric component with `collapsable={false}` survives
   flattening on 0.88 (the without-prop case is not isolated); keep `collapsable={false}`; the hierarchy-dump technique in the probes doc is reusable
   for the device tests.
7. **Network (section 9).** Both routes work on Android: a native OkHttp interceptor
   through `NetworkingModule.setCustomClientBuilder`, and a JS `XMLHttpRequest`
   wrapper. They would **double-record** if both were on. If network is pulled forward
   from release 2 into 0.0.1 (the user's narrowed goal; decision 8 and section 9 currently
   say release 2), the JS wrapper is the smaller change (one resolver, both OSes, iOS
   native path not yet tested); if the native interceptor is chosen, JS wrapping must stay
   off. The roadmap contradiction is not resolved by this spike.
8. **Time-to-working.** A custom Fabric view, the identity walk and the network hooks
   all built and ran on 0.88 (the iOS probe needed fixes to my own probe code, not to
   RN); the risk is the untested legs below, not these.

**Still open (not run):** 0.76 and a mid version; React 18; iOS Release and
debug-vs-release fingerprint equality (S14); `react-native-screens` detach,
`removeClippedSubviews`, Reanimated and transitions (S5, S10); Android late start
(S12); iOS `Modal` (S13); `Alert` and Android hit-view rules (S9); old-architecture
detection when absent (S6); multi-touch identifiers and Android native timestamp
parity (S7); the pager; FlashList 1 and the FlashList 2 second rule; Expo Router.

## 16. Decisions on the open questions

**DECIDED 2026-11-27.** The user accepted every recommendation, with the Q10 answer
below.

| # | Question | Decision |
| --- | --- | --- |
| Q1 | Support the old architecture? Amend rule 4? | **DECIDED.** No. 0.76+ New Architecture only. Amend rule 4 (and the "on and off" line in PR #190's React Native section) to "Fabric on, mark inside layout-only parents". |
| Q2 | Native reads mask rectangles at draw time instead of JS sending them (ADR 0009 text)? | **DECIDED.** Yes. Amend the ADR sentence in the BLE-644 PR. |
| Q3 | `testID` as the alias, plus a JS-only `<Tugboat.Tag>`; a switch to keep `testID` out of the path? | **DECIDED.** Yes to all. `testID` must be stable and carry no user data. |
| Q4 | Route key: path of names or leaf name? | **DECIDED.** The path. |
| Q5 | `Tugboat.setScreen` for custom navigators; Wix? | **DECIDED.** Add `setScreen`. No Wix in release 1. |
| Q6 | Host seam: extend `ToolkitRegion` for RN and build the Swift equivalent (section 8)? | **DECIDED.** Yes. Release 1 is pure React Native ("RN owns its root"). Brownfield is unknown, so the full hybrid claim is later and is revisited when brownfield demand is known. |
| Q7 | Host `restart`, and end the session on a new JS context? | **DECIDED.** Restart yes. Always end on a new JS context for RN-started sessions. Brownfield is excluded (native-started sessions are never ended by JS). |
| Q8 | JS start in release 1? | **DECIDED.** Yes, only with the Android adopt-current-activity seam or an early initializer. |
| Q9 | Request mark by header? | **DECIDED.** Defer, lean no. Reconcile with the roadmap first (section 9). |
| Q10 | Is exploration scene inventory in release 1? | **DECIDED: NO.** `@tugboat/react-native` 0.1.0 ships without it; fingerprints do not depend on it. Inventory items moved to "Later" (section 11). |
| Q11 | `[page:N]` | **DECIDED.** The segment format is fixed now (it is in the fingerprint). The engine rule and fixture are later, with inventory. |
| Q12 | Tap-anchor hold | **DECIDED.** Start at 100 ms. Gate release on the unresolved-tap rate (taps with `resolution_error`). |
| Q13 | Tab switch emits a navigation fact? | **DECIDED.** Yes in release 1: `replace` on the tab navigator, departing the old tab top. Move to an engine `activate` fact when it exists. |

## 17. Release 1 work and where it is tracked

Items that depended on the scene inventory are not here (they are "Later",
section 11; BLE-677, the `[page:N]` engine rule, moved to milestone 7 with it).

| Work | Issue |
| --- | --- |
| The spike (section 15). Gates BLE-644 and BLE-669. | BLE-681 |
| Android: React Native owns its root through `ToolkitRegion` (async anchor, region route key, no host-path prefix, fragment navigation suppressed under the host) | BLE-682 |
| Swift host region seam | BLE-683 |
| Host `restart`, and Android adopt-current-activity on late start (or an early initializer) | BLE-684 |
| RN scroll facts (native offsets, JS ancestor anchors matched by tag) | BLE-685 |
| RN text input taps and focus (native `focus {kind}`, role `TextInput`) | BLE-686 |
| RN navigation: late navigators, re-seeding, tab switches (Q13), `setScreen` | BLE-687 |
| Taps inside a `sensitive` region (the contract's accepted residual) | BLE-688 |
| Tap failure reason mapping; `[page:N]` segment format; fingerprint conformance (debug vs release Hermes, iOS vs Android, with and without the mask component) | BLE-669 |
| ADR 0009 rule 4 and mask-rectangles amendments; the RN column in PR #190's mapping table (and its "on and off" line); RN masking device tests (section 3.5) | BLE-644 |
| Publishing prerequisites: `TugboatSDK` podspec, `tugboat-android` on Maven Central | BLE-638, BLE-639 |
| npm workspace | BLE-643 |

## 18. Could not verify

- Everything marked **[memory]** or **[spike]**: the touch event's fiber field and
  fiber internals, host component names, list cell props, scroll matching,
  `nativeEvent.timestamp` parity, `onScroll` not bubbling, `react-native-screens`
  and `removeClippedSubviews` detach behavior, animation library behavior, Expo Go's
  limit, `expo/fetch`, `useNavigationContainerRef`, Expo Router on React Navigation.
- That a custom Fabric component is never flattened (the docs read cover
  `collapsable`, `testID`, `nativeID`, not custom descriptors).
- PR #190 was re-read on its branch on 2026-11-27 and may change again. PRs #187
  and #188 were read open.
- The native hosts' stamped fingerprint schema version and the BLE-670 alias work.
- `LiveActivities` was read from source; the failure of a late JS start is a spike
  item, not observed.
- The `restart` and region-extension host APIs do not exist yet.
