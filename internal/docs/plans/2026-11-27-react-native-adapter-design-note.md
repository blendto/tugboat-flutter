# React Native adapter design note

Status: Draft for review, revision 2 · 2026-11-27 · BLE-642 (ADR 0009, rule 4 of the amendment)

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
(BLE-648, BLE-671). Error reporting is release 3. Network, scene inventory and
pager sections fix the seams those later steps need.

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
| 3 | The RN mask is one native container view, `<Tugboat.Sensitive>`, with the shared model's one override (`sensitive`). JS sends marks. Native reads rectangles at draw time. This deviates from the ADR 0009 sentence "JS sends mask rectangles" (Q2). |
| 4 | Navigation facts come from the navigation container state, diffed in JS. A navigator that appears late sends `push` for its initial route. Expo Router uses the same path. |
| 5 | A new JS context ends a session the RN adapter started and starts a new one. Brownfield is excluded from release 1 unless a waiting client needs it. |
| 6 | One npm package, autolinked. The Expo plugin only enforces minimums in release 1. Published native artifacts (BLE-638, BLE-639) are a blocker. |
| 7 | The identity token is a portable role from host component names, never component function names. `testID` is the alias. |
| 8 | Network is recorded in JS by wrapping `XMLHttpRequest` (release 2). It contradicts the roadmap's "native network for free" row. |
| 9 | The scene inventory is built in JS. Native runs the frame watch and forwards `scene.sample`. |
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
| `scene.watch`, `scene.frame` | Native (`Choreographer`, `CADisplayLink`) | Drawn frames are native. |
| `scene.inventory` | JS | Identity parts are in JS (section 11). |
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

The fiber of the touched node is `event._targetInst` **[memory, spike]**, a React
internal that other RN SDKs read **[memory]**. The resolver checks it and falls
back to route-only identity (`low`), never throws.

## 3. Masks

PR #190 defines the privacy model. This section maps React Native onto it and
does not restate it. Re-check against #190 before release; it is being revised.

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

| Model (PR #190) | React Native |
| --- | --- |
| Dimensions `text`, `media`, `region` | Same. No `touch` and no `hide` dimension. |
| App level, `MaskLevel` | `Tugboat.start({ maskLevel })`. Only `allTextAndMedia` is implemented natively; an unknown level resolves to `allTextAndMedia`. |
| Override `inherit` or `sensitive` | One component, `<Tugboat.Sensitive>`, a native container view, named for Flutter parity (`TugboatSensitive`). No per-dimension props. `sensitive` masks its `region` and every descendant at its own bounds. The default is `inherit`, which is no mark. |
| No relaxing or reveal level | None exists in the component. A descendant cannot loosen an ancestor. |
| Inheritance | Resolved **in the host** from the native view tree, as Views does. Native ancestry equals React ancestry because the mark view is never flattened **[spike]**. The adapter sends no mask tree to the engine. |
| Override is not identity | A mask never changes tags, paths or fingerprints. Conformance fixture: the same React tree with and without `<Tugboat.Sensitive>` gives the same fingerprints. |
| Fail closed order: element bounds, region host, whole frame | Element at its own bounds, then the **region host** (the React root view), then the whole frame. |
| `MaskCoverage` (`precise`, `wholeHost`, `wholeFrame`) with the engine's closed reasons | Reported per frame. Reasons reuse the existing list (below). Any new reason is a contract change in the engine's `capture_types`, and none is proposed. |
| Reach: descendants at their own bounds, even outside the marked bounds | RN children overflow their parent by default, so the host unions the bounds of the mark's descendants, not only the mark view's bounds. |

Reasons used, all existing: `regionUnreadable` (an expected mark has no native
instance, or the root's bounds cannot be read), `treeUnreadable`, `animating`,
`interop` / `webView` / `renderer` / `surfaceLayer` (unknown native views that
are boxed), `unclassifiedLayer` (iOS), `overlayWindow` (a window the copy cannot
see). A mode of `wholeHost` means the React root view is boxed.

### 3.3 The mask view

- `<Tugboat.Sensitive>` renders a Fabric component, `TugboatSensitiveView`, with
  its own component descriptor and `collapsable={false}` set anyway. It is a real
  container view, so a flattened parent cannot remove it **[spike]**.
- **Layout-neutral.** The view uses the same shadow-node layout as a plain `View`
  (a Yoga node with `flex` default, no props that add size, margin or position),
  passes its style prop straight through, and draws nothing. Its child stacking
  is unchanged. Adding it to a tree must not move a pixel; a layout test checks a
  tree with and without it **[spike]**.
- **Rectangles are read at draw time.** The host's mask supplier runs in the
  same main-thread turn as `PixelCopy` / `drawHierarchy`, as the SwiftUI and
  Android adapters do (native note, section 2). It reads the real window bounds
  of each mark and of every descendant, so scrolled, animated and overflowing
  content is where native has it.
- **Expected marks.** On mount JS registers `expectMask(id)` (no level: the only
  override is `sensitive`). The native view attaches with the same `maskId`.
- **"Missing" means never created.** An expected id whose native view was **never
  created** after a bound (proposal: two flushes) means the mark cannot be placed:
  mask the **region host** and report `regionUnreadable`. A view that was created
  and is now **detached** is not missing: a detached view draws nothing, so
  nothing needs masking. That matters because `react-native-screens` detaches
  covered screens, `removeClippedSubviews` detaches off-screen rows, and inactive
  tabs stay mounted **[memory]**. A rule that fired on detachment would mask the
  whole frame constantly. A detached view that reattaches is masked from the
  frame it is drawn in.
- **If the region host cannot be read** (the root view bounds), mask the whole
  frame.
- **Animating.** The existing adapters mask the whole frame while something is
  animating whose layout bounds do not describe where it draws (Android
  `AnimationProbe.kt`: a running legacy `View` animation or `LayoutTransition`;
  iOS `LayerWalk.swift`: `animationKeys()` non-empty, reason `animating`). The RN
  walk reuses those probes on the React root's native subtree. Property and
  transform animations are covered by the real bounds. Whether Reanimated and
  `react-native-screens` transitions are covered by the probes is a **[spike]**
  item.

### 3.4 Automatic masks under `allTextAndMedia`

- **Allowlist by type, not by name.** The walk classifies native views by an
  allowlist of RN-core view classes referenced **by type** in the native code
  (`ReactTextView`, `ReactEditText`, `ReactImageView`, `ReactViewGroup`,
  `ReactScrollView` and equivalents on iOS; **[memory]** names), so R8 and Swift
  symbol stripping cannot change the result. Text and text input are `text`.
  Image is `media`.
- **Every unknown native view is `media` and boxed.** Skia canvases, maps, video,
  `WebView`, `SurfaceView`, `TextureView` and any third-party native component
  not on the allowlist are masked over their whole bounds, as SwiftUI does for
  its unverified layer allowlist (`unverifiedLayerAllowlist`). Plain RN
  containers (`ReactViewGroup`, scroll views) are walked, not boxed.
- An RN version whose allowlist is unverified masks the region host (reason
  `regionUnreadable`), the same posture as Compose on an unverified version.

### 3.5 Device tests (Fabric on)

- a mark inside nested layout-only `View`s, default `collapsable`;
- a mark with **overflowing children** (children outside the mark's bounds);
- a mark under an animated transform, and inside a `ScrollView`;
- a mark unmounted mid-capture;
- a mark whose native view is never created (test hook): region host masked;
- a **covered stack screen** (`react-native-screens`) with a mark under the top
  screen: no whole-frame mask, no leak;
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
| Codegen | `codegenConfig` of type `all` (TurboModule `NativeTugboat`, component `TugboatSensitiveView`), Java package `com.tugboat.reactnative`. |
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
  | `Switch` | `AndroidSwitch`, and the iOS name **[spike: confirm]** |
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
  a numeric `index` prop together with a `cellKey` (or the FlashList cell
  container's `index`), **[spike]**. It adds `[item:<index>]`. Without a match the
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

## 11. Settled re-sample and the scene inventory

Facts (stateful-engine.md section 4.3.2, PR #188): the engine owns the settled
re-sample. It emits `scene.watch {armed}` and `scene.sample`, takes `scene.frame
{}` from the host (at most once per 100 ms while armed), and takes the answer as
`scene.inventory {resample: true, ...}`. Exploration metadata (`trigger`,
`surface`, `viewport`, `scroll`, per-element `visibleFraction`, `tag`,
`positional`) rides on the fact.

| Piece | Owner |
| --- | --- |
| Novelty, windows, caps, de-duplication | Engine |
| `scene.watch`: arm drawn-frame callbacks, send `scene.frame` | Native host. No JS. |
| `scene.sample` | Native receives the effect and emits `sceneSample` to JS. **JS answers.** |
| The inventory (elements, identity, `tag`, `positional`) | **JS**, from the visible route's fiber tree, using section 10. |
| Element boxes and `visibleFraction` | **Primary: native, by React tag.** JS names the elements (tag plus identity); native fills the window box and visible fraction from the mounted view. `getBoundingClientRect` and DOM-like APIs are an optional alternative, not relied on **[spike]**. |
| `viewport`, `scroll`, `surface` | Native (window, insets, keyboard); JS names the primary scrollable. |
| Stale answers | Dropped by the engine. JS echoes the request token. |

JS builds it because identity parts are in JS; a native-built inventory would carry
native-view fingerprints that do not match RN taps. A busy JS thread delays or loses
a sample, which is the right failure. JS builds in an idle turn and caps the fiber
walk at the engine's element limit while counting `totalElements`. Production
capture builds no inventory and keeps `scene.watch` unarmed.

**The user must confirm (Q10):** if the app graph that fingerprints join to is
built from exploration inventories, then release-1 fingerprints need an inventory
to join to, and inventory is in release 1. This note had put inventory after
release 1.

## 12. Pager pages (BLE-677)

Today the engine keeps a pager's page position apart from collapsed list positions
only through Flutter widget names (`PageView#`, `Scrollable#`). Two RN pages built
from one component share every path.

Proposal: an explicit, toolkit-neutral segment **`[page:N]`** in the canonical
path, never collapsed by the novelty rule (`[item:N]` still collapses). Because it
is in the path it is in the fingerprint, so **its format is fixed now**:
`[page:<zero-based index>]`, placed after the pager's own `Scrollable` token
segment. The engine work (rule and fixture) moves with inventory (Q10, Q11).

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
  role-table entry; **same fingerprint with and without `<Tugboat.Sensitive>`**;
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
| S1 | Fiber walk: `event._targetInst`, `.return`, `memoizedProps` | Resolves the touched node and its ancestors on every matrix cell, in release builds. |
| S2 | Route-context provider walk, including the React 19 provider shape, compared against exported `NavigationRouteContext` by reference | Finds the route of a control on every cell. |
| S3 | Host component names per OS and version (text input, switch, scroll, horizontal scroll, image, text, view, pager) | The role table is complete and the same per role on both OSes. |
| S4 | FlatList and FlashList (v1 and v2) cell recognition and `index` by prop shape | `[item:index]` matches the data index on every list type. |
| S5 | The custom mask component: not flattened (with `collapsable={false}` set anyway), layout-neutral, ancestry preserved, inside `react-native-screens`, scroll views, `removeClippedSubviews` | A tree with and without it lays out identically and each mask is found. |
| S6 | Old-architecture detection (`nativeFabricUIManager`) | Dormant with one log, no crash. |
| S7 | Touch matching by `nativeEvent.timestamp` and `identifier` between JS and native | 100% matched on a scripted run, including brownfield offsets. |
| S8 | Scroll matching: native scroll start to the scrollable ancestor anchor by React tag | Correct anchor for nested and horizontal scrolls. |
| S9 | Native hit view: React-managed or not (native-stack back button, native tab bar, `Alert`) | Native decides `opaque_platform_view` or `system_ui` at `down`. |
| S10 | Animation probes cover Reanimated and `react-native-screens` transitions | No unmasked content during a scripted transition, or the probe is extended. |
| S11 | Box source by React tag from native | Window box and visible fraction match the screen on both OSes. |
| S12 | Android late start: JS `start` after the first resume | Frames and pointer facts work with the adopt-activity seam or the early initializer. |
| S13 | Modal, iOS: the key-window frame and the root wrapper cover a `Modal` | Frame correct and anchor resolved, or the gap is documented. |
| S14 | Debug versus release Hermes: identical fingerprints for a script on both OSes | Equal. |

## 16. Open questions for the user

| # | Question | Recommendation |
| --- | --- | --- |
| Q1 | Support the old architecture? Amend rule 4? | No. 0.76+ New Architecture only; amend rule 4 to "Fabric on, mark inside layout-only parents". |
| Q2 | Native reads mask rectangles at draw time instead of JS sending them (ADR 0009 text)? | Yes. Amend the ADR sentence in the BLE-644 PR. |
| Q3 | `testID` as the alias, plus a JS-only `<Tugboat.Tag>`; a switch to keep `testID` out of the path? | Yes to all. Docs say `testID` must be stable and carry no user data. |
| Q4 | Route key: path of names or leaf name? | The path. The leaf collides. |
| Q5 | `Tugboat.setScreen` for custom navigators; Wix? | Add `setScreen`. No Wix in release 1. |
| Q6 | Host seam: extend `ToolkitRegion` for RN and build the Swift equivalent (section 8)? | Yes. Release 1: pure RN ("RN owns its root"). Full hybrid claim later, unless a waiting client is brownfield. |
| Q7 | Host `restart`, and end the session on a new JS context? | Restart yes. Always end on a new JS context for RN-started sessions; exclude brownfield (native-started sessions never ended by JS). |
| Q8 | JS start in release 1? | Yes, only with the Android adopt-current-activity seam or an early initializer. Otherwise native early start. |
| Q9 | Request mark by header? | Defer, lean no. A header to customers' servers can break CORS-strict and signed requests. Reconcile with the roadmap first (section 9). |
| Q10 | Is exploration scene inventory in release 1? | **User to confirm.** If the app graph is built from exploration inventories, fingerprints need inventory, so yes. Otherwise no. |
| Q11 | `[page:N]` engine change? | Fix the segment format now (it is in the fingerprint). Engine rule and fixture move with inventory. |
| Q12 | Tap-anchor hold, 100 ms? | Start at 100 ms. Gate release on the unresolved-tap rate (taps with `resolution_error`); fix the reason to `resolution_error`, not `identity_unavailable`. |
| Q13 | Should a tab switch emit a navigation fact? | Yes in release 1: `replace` on the tab navigator, departing the old tab top. Switch to an engine `activate` fact when it exists. Otherwise the visible route does not move and later facts are misattributed. |

## 17. Release 1 work not yet tracked

New issues this note implies:

1. The spike (section 15), gated before BLE-644.
2. Android `ToolkitRegion` for React Native (async anchor, region route key, no
   host-path prefix, suppress fragment navigation under the host).
3. Swift region seam (the same, for iOS).
4. Host `restart` (end and start a session).
5. Android adopt-current-activity on late start, or an early initializer.
6. RN scroll facts (native offsets, JS ancestor anchors matched by tag).
7. RN focus and text-input facts (native `focus {kind}`, role `TextInput`).
8. Navigation: late-navigator `push`, seed on every session start, tab-switch
   decision (Q13), same path string in facts and anchors.
9. Tap failure reasons mapped onto the engine's closed set, plus the
   unresolved-tap counter.
10. Publishing prerequisites: `TugboatSDK` podspec and `tugboat-android` on Maven
    Central (BLE-638, BLE-639).
11. ADR 0009: rule 4 amendment (no Fabric-off leg) and the mask-rectangles
    amendment (Q2); the RN column in PR #190's adapter mapping table.
12. RN masking device tests (section 3.5).
13. Fingerprint conformance: debug versus release Hermes, iOS versus Android, with
    and without `<Tugboat.Sensitive>`.

## 18. Could not verify

- Everything marked **[memory]** or **[spike]**: the touch event's fiber field and
  fiber internals, host component names, list cell props, scroll matching,
  `nativeEvent.timestamp` parity, `onScroll` not bubbling, `react-native-screens`
  and `removeClippedSubviews` detach behavior, animation library behavior, Expo Go's
  limit, `expo/fetch`, `useNavigationContainerRef`, Expo Router on React Navigation,
  DOM-like box APIs.
- That a custom Fabric component is never flattened (the docs read cover
  `collapsable`, `testID`, `nativeID`, not custom descriptors).
- PR #190 is being revised; section 3 follows its current branch. PRs #187 and
  #188 were read open.
- The native hosts' stamped fingerprint schema version and the BLE-670 alias work.
- `LiveActivities` was read from source; the failure of a late JS start is a spike
  item, not observed.
- The `restart` and region-extension host APIs do not exist yet.
