# Native SDK design note (Android Views + Compose, SwiftUI)

Status: Approved with changes (folded in) · 2026-10-12 · ADR 0009 milestone step 4

Working note, not product docs. It fixes the public API, artifacts, host
threading, engine linking, the toolkit-adapter seam, and identity rules for
the first native SDKs. Implementation starts after it is approved and engine
phase 3d has merged. Decisions that touch shipped artifacts are also logged in
[adr-0009-decisions-log.md](adr-0009-decisions-log.md).

Engine behaviour is in
[stateful-engine.md](../../../core/session-engine/docs/stateful-engine.md).
The collector contract the SDKs must satisfy is fixed for this milestone
(section 9).

## 1. Artifacts and layout

| Artifact | Where | Contains | Depends on |
| --- | --- | --- | --- |
| `com.gettugboat.sdk:tugboat-android` | `platforms/android/tugboat-android` | Kotlin host, JNI bridge, the session engine (CMake), the Views adapter | `capture-runtime` (Gradle project dependency in this build) |
| `com.gettugboat.sdk:tugboat-compose` | `platforms/android/tugboat-compose` | Compose adapter | `tugboat-android`, Compose UI |
| SwiftPM product `Tugboat` (root `Package.swift`) | `platforms/apple/Sources/Tugboat` | Swift host and SwiftUI adapter | `TugboatSessionEngine`, `TugboatCaptureRuntime` |
| SwiftPM target `TugboatSessionEngine` | `core/session-engine` | The engine as a C++ target; Swift imports the C header directly | — |
| `TugboatSDK.podspec` (module `Tugboat`) | repository root | Same sources as the SwiftPM product | `TugboatCaptureRuntime` |
| Android sample `:tugboat-sample` | `platforms/android/tugboat-sample` | One app with a Views screen, a Compose screen, a list, a dialog, and a text field, with navigation between them | the two artifacts above |
| Apple sample | `platforms/apple/Samples/TugboatSwiftUISample` | A SwiftUI app; `project.yml` for XcodeGen | `Tugboat` via a local SwiftPM path |

Notes:

- Compose is a separate artifact so Views-only apps do not pull in Compose.
- Nothing is published in this milestone. Android resolves through
  `.local-maven` and Gradle project dependencies. Apple resolves through
  local SwiftPM paths.
- The CocoaPods name `Tugboat` may already be taken on trunk, so the
  podspec is `TugboatSDK`. The Swift module stays `Tugboat`.
- Only the engine's owning artifacts compile it (ADR 0003): `tugboat-android`
  and the `TugboatSessionEngine` target. The image core stays owned by the
  capture runtimes. Apple must not compile it twice, or static linking in a
  hybrid app hits duplicate symbols.

## 2. Pixel capture

- **Android.** `capture-runtime` only captures a `FlutterSurfaceView` today.
  It gains an additive `capture(window: Window, request, onComplete)` that
  uses `PixelCopy.request(Window, …)` (API 26+) and reports coverage
  `windowComposite`. The coverage vocabulary already reserves that value;
  `native-capture-contracts.md` changes from "forbidden" to "Android window
  path".
  - Additive public API, so `VERSION_NAME` 0.1.0 → 0.2.0 (unpublished). The
    API dump and `verify-android-runtime-api.sh` are updated.
  - The Flutter path is unchanged (logged). The Flutter plugin's pinned
    `capture-runtime` version stays unchanged.
  - **Secure windows.** A window with `FLAG_SECURE` is never copied. The
    runtime returns a new `secureWindow` status, and the host turns it into a
    `capture_diagnostic` instead of an error frame. This is additive to
    `CaptureStatus`.
  - **Separate surfaces.** `PixelCopy.request(Window)` does not include
    `SurfaceView` / `TextureView` layers such as video, maps, or camera. The
    adapter masks their bounds fail-closed (section 2.1).
    `native-capture-contracts.md` states this for `windowComposite`.
- **Apple.** `CaptureRuntime(coverage: .viewHierarchy)` already accepts any
  `UIView`. The host captures the key window itself, so presented sheets and
  alerts are in the frame. `TugboatCaptureRuntime` 0.2.0 (unpublished) adds
  an additive mask supplier that runs in the same main-thread turn as the
  draw (decisions log); the Flutter plugin's pin is unchanged.
- Below the native floor (Android API 26, iOS 15), sessions carry events
  without frames. This is the existing `unsupportedApi` outcome.
- **Masks fail closed.** The adapter computes mask rectangles on the main
  thread at copy (draw) time: the pixel runtime calls the host's mask
  supplier immediately before `PixelCopy.request` / `drawHierarchy`, so the
  masks describe the copied frame, not the layout when the request arrived. If it cannot enumerate the screen
  with confidence (for example, SwiftUI on an iOS major version whose layer
  allowlist is not verified, section 6.3), it masks the whole frame. It never sends an
  unmasked frame. The default stays `allTextAndMedia`. The one exception is an
  explicit app opt-in that trades coverage for detail
  (`ComposeMasking.SemanticsBestEffort`, section 2.1); every capture reports
  which masking applied (`MaskCoverage`).

### 2.1 Mask sources under `allTextAndMedia`

Every region below is masked. Regions marked fail-closed are masked over
their whole bounds because the SDK cannot see inside them.

| Toolkit | Text | Media | Fail-closed bounds |
| --- | --- | --- | --- |
| Android Views | `TextView` (includes `EditText`, buttons) | `ImageView`, `VideoView` | `WebView`, `SurfaceView`, `TextureView` |
| Compose (default `ComposeMasking.WholeHost`) | the whole Compose host | the whole Compose host | the whole Compose host |
| Compose (opt-in `ComposeMasking.SemanticsBestEffort`) | nodes with `Text` or `EditableText` semantics | `Role.Image`, and nodes with a `ContentDescription` (image-like) | `AndroidView` interop bounds; the whole frame when the semantics owner is unavailable (section 6.2); the whole host outside the tested Compose UI range (the opt-in is ignored). **Not masked (accepted by opting in):** content without semantics, such as `Image` / `Icon` / `AsyncImage` with a null `contentDescription`, `drawText`, and Canvas / `drawBehind` / `Modifier.paint` drawing. |
| SwiftUI | allowlisted SwiftUI drawing layers (section 6.3); `UITextField`, `UITextView`, `UILabel` | allowlisted SwiftUI image layers, padded; `UIImageView` | `WKWebView`; any `UIViewRepresentable` host view; any unclassified layer with `contents` inside a hosting view; the whole frame on an iOS major version without a verified allowlist (section 6.3) |

Adapter tests assert each row (section 8).

## 3. Public API

The surface is deliberately small. Everything else comes from the engine
config defaults.

```kotlin
// Android
Tugboat.start(application, TugboatConfig(
    collector = CollectorConfig(baseUrl, apiKey),
    app = AppInfo(name, version, buildNumber, appId, installationId),
    maskLevel = MaskLevel.AllTextAndMedia,   // default
))
Tugboat.setUserId(id); Tugboat.setTraits(map); Tugboat.stop()
Tugboat.trackNavigation(navController)        // Jetpack Navigation, optional
view.tugboatTag = "checkout"                   // Views alias
Modifier.tugboatTag("checkout")                // Compose alias (tugboat-compose)
```

```swift
// Apple
Tugboat.start(TugboatConfig(
    collector: .init(baseURL: url, apiKey: key),
    app: .init(name:, version:, buildNumber:, appId:, installationId:)))
Tugboat.setUserId(_:); Tugboat.setTraits(_:); Tugboat.stop()
someView.tugboatTag("checkout")      // alias, like TugboatTag
someView.tugboatScreen("Checkout")   // route identity for a SwiftUI screen
```

- `start` is idempotent.
- Capture failures never throw into the app.
- `stop` ends the session and drains (C5).

## 4. Host threading and engine linking

- **One engine handle per process, used from one thread.**
  - Android uses a `HandlerThread` named `tugboat-engine`. Timers are
    `Handler.postAtTime` on its looper, which uses the uptime clock the engine
    expects.
  - Apple uses a serial `DispatchQueue` named `tugboat.engine`. Timers are
    `DispatchSourceTimer`, which uses the same mach uptime clock as
    `systemUptime`.
- **Facts.** They are timestamped on the main thread when they happen
  (`MotionEvent.eventTime`, `UIEvent.timestamp`, or the clock for
  non-input facts). The main thread batches them once per frame
  (`Choreographer` / `CADisplayLink`) into one `batch` message posted to the
  engine thread.
- **Effects.**
  - `http.send` runs on a small IO executor (Android `HttpURLConnection`,
    no OkHttp dependency) or a `URLSession` with a delegate queue.
  - `capture.request` hops to the main thread so the adapter can compute
    masks and call the pixel runtime.
  - Every result posts back to the engine thread as a message.
- **Frame bytes** live in a host-side handle table. `frame.release` frees
  them.
- **Linking.**
  - Android: CMake builds `core/session-engine` into `libtugboat_engine.so`
    with `c++_static`. A thin JNI bridge exposes create, submit and destroy.
    The engine's `double_conversion` namespace is already renamed, so it
    cannot clash.
  - Apple: Swift calls the C ABI directly through the target's module map.
    No ObjC++ bridge.
- **Host failure.** Any status other than `ok` from `submit` is logged and
  dropped. Repeated `internal_error` disables capture for the process. The
  host app is never interrupted.

## 5. Toolkit-adapter seam

Adapters produce the facts in stateful-engine.md section 9.1 and 8.1, and
answer `capture.request` with masks plus pixels. The rule from section 2 of
that doc applies: tree reads happen at fact time and travel with the fact.

| Fact | Android Views | Compose | SwiftUI |
| --- | --- | --- | --- |
| Pointer | `Window.Callback` wrapper on each activity window, installed from `ActivityLifecycleCallbacks` | same window callback | A `UIGestureRecognizer` on the key window. It never cancels touches, recognizes simultaneously, and needs no swizzling. |
| Tap target | hit-test of the View tree at the down point | semantics hit-test at the down point | `tugboatTag` frames, then UIKit hit-testing (section 6.3) |
| Scroll | `OnScrollChangedListener`, then compare offsets of known scrollables; `RecyclerView.OnScrollListener` when found | per-frame scroll-range diff over semantics nodes during and after a gesture | KVO on `contentOffset` of `UIScrollView`s (SwiftUI `ScrollView` and `List` are backed by them) |
| Navigation | activity and fragment lifecycle callbacks; `trackNavigation` destinations | `trackNavigation` route patterns; hosting activity as fallback | `.tugboatScreen` appear/disappear, plus view-controller appearance (swizzled, with opt-out) for hosting controllers |
| Focus | `OnGlobalFocusChangeListener` | focused editable semantics node | `UITextField` / `UITextView` begin- and end-editing notifications |
| System input | allowlisted keys from `dispatchKeyEvent`. Predictive back cannot be observed without consuming it: a known gap. | same | none in this milestone |
| Lifecycle | `ProcessLifecycleOwner` | same | scene and application notifications |

**Wrapping `Window.Callback`.** Other SDKs (Sentry, Firebase, Datadog) wrap
the same callback, so the wrapper must chain cleanly:

- Every `Window.Callback` method delegates to the callback it replaced.
  Tugboat only observes and never consumes events.
- On each `onActivityResumed`, the host checks whether the window's callback
  is still ours, possibly behind someone else's wrapper. If another SDK
  replaced it without chaining to us, the host wraps again. It never wraps
  its own wrapper twice: it walks a marker interface through the chain.
- A Robolectric test installs a foreign wrapper before and after ours and
  checks that every method reaches the original callback exactly once.

**SwiftUI view-controller tracking.**

- Swizzling `viewDidAppear` / `viewDidDisappear` is optional. It is enabled
  by default, with an opt-out in `TugboatConfig`. It is installed once,
  through a `dispatch_once`-style guard, with `method_exchangeImplementations`.
- `.tugboatScreen` alone is enough for route keys.
- The sample app sets `.tugboatScreen` on every screen and runs with
  swizzling turned off, so it does not depend on swizzling.

Known gaps for this milestone:

- Dialog and popup windows outside an activity window are captured as
  frames but not wrapped for pointer facts.
- Android predictive back is not observed.
- Compose scroll facts are frame-diffed, so their offsets are approximate.

## 6. Identity (`toolkit` field and canonicalization)

Rules shared by every toolkit, as for Flutter:

- **Fingerprints.** The target fingerprint is the hash of `routeKey` plus the
  canonical path. A developer alias (`tugboatTag`) gives a high-confidence
  `tagFingerprint` and is transparent to structural identity. The hash and
  confidence levels are shared.
- **Never in identity.** Visible text, `contentDescription`, and
  accessibility labels are locale evidence and never enter identity.
- **What is excluded.** Hidden, zero-alpha, zero-size, and SDK-owned nodes
  are excluded. Non-actionable, unidentified containers collapse. Ordinals
  count same-token siblings after filtering. List items get `[item:index]`.
- **The `toolkit` field.**
  - Native anchors carry `toolkit` inside `targetAnchor`: `view`, `compose`,
    or `swiftui`.
  - Flutter anchors stay unchanged, with no field.
  - It is not a hash input.
  - The collector accepts and stores it (section 9).

The rules below go into `docs/design/capture-and-fingerprint.md` as one
section per toolkit, in the PR that implements each adapter.

### 6.1 Android Views

| Rule | What it means |
| --- | --- |
| Token | The nearest **platform** class in the superclass chain (`android.*`, which R8 never renames), plus `#<resource entry name>` when the view has an id. A custom `MyButton : MaterialButton : Button` therefore becomes `Button#checkout`. |
| Kept | Views that are actionable (clickable, long-clickable, checkable, editable, or with accessibility actions), views with an id, scrollables, and leaves that can be masked (text, image, web, video, surface). |
| Lists | `RecyclerView` children use `getChildAdapterPosition`. `AbsListView` children use first-visible position plus their index. |
| Route key | Jetpack Navigation destination route pattern (arguments stripped: `checkout/{id}?step={s}` is `checkout`) or id entry name, then the top fragment's tag, then the fragment class, then the activity class. Activities are kept by the manifest. Fragment class names can be obfuscated, so they score `low` confidence. |
| Alias | The `tugboatTag` view tag, then a unique resource entry name within the route. Both are high confidence. |
| Obfuscation | Resource entry names survive normal release builds. If resource-name obfuscation is enabled, ids are dropped from tokens rather than used. |

### 6.2 Compose

| Rule | What it means |
| --- | --- |
| Token | `Role` (Button, Checkbox, Switch, RadioButton, Tab, Image, DropdownList), then `TextField` for editable nodes, `Scrollable` for nodes with a scroll range, and `Node` otherwise. |
| Source | The merged semantics tree read through `ViewRootForTest.semanticsOwner`. Only nodes that are actionable, editable, scrollable, maskable, or tagged are kept. |
| Stability | `semanticsOwner` is treated as unstable API. It is reached through `runCatching`. `tugboat-compose` pins the Compose UI version range it is tested against. When the owner is unavailable, the anchor falls back to the hosting `View` identity (section 6.1, `toolkit` stays `compose`) and the frame is masked in full. |
| Lists | `CollectionItemInfo` index. Without it (lazy layouts set none) the item is `[item]`: on-screen order is not identity, so the index is dropped and the path confidence is `low`. |
| Route key | The host view's Views route (section 6.1): the same `trackNavigation` route pattern, arguments stripped once by the Views adapter, then the hosting activity (or the fragment around a `ComposeView`). |
| Alias | `Modifier.tugboatTag`, then `testTag`. Both are high confidence. |

### 6.3 SwiftUI

The SwiftUI accessibility probe (branch `spike/swiftui-a11y-probe`) decided
this section. On iOS 26.5 with VoiceOver off:

- every SwiftUI hosting view reports zero accessibility elements and no
  `accessibilityIdentifier`, so the accessibility tree cannot be used
  in-process;
- SwiftUI `Text`, `Button` labels, `Image`, and list-row text are not UIKit
  views. They are drawn into separate CALayers inside the hosting views:

  | Layer class | Matched | IoU |
  | --- | --- | --- |
  | `SwiftUI.ImageLayer` | the star image | 0.76 |
  | the mangled private `…CGDrawingLayer` class | every text element | 0.99–1.00 |

**Identity**

| Rule | What it means |
| --- | --- |
| Alias and tap target | `.tugboatTag` frames, which the modifier registers through anchor preferences, are hit-tested first. Tags are high confidence. |
| Untagged targets | UIKit hit-testing at the down point: `UITextField`/`UITextView`, list cells, `HostingScrollView`, and representable hosts. The token is the UIKit role (`TextField`, `Cell`, `Scrollable`, `Representable`), plus the path of ancestor hosting views. Without a tag or an index path the confidence is `low`. |
| Lists | `List` is a `UICollectionView` on iOS 16+ (`UpdateCoalescingCollectionView` with `ListCollectionViewCell` on iOS 26.5) and a `UITableView` on iOS 15. The cell's index path gives `[item:section.row]`. |
| Scroll | SwiftUI `ScrollView` is a `HostingScrollView` (`UIScrollView`), so KVO on `contentOffset` works. |
| Route key | The `.tugboatScreen` name, then the hosting controller's Swift type name. Swift type names are not obfuscated, but they are long, so they are hashed and score `medium`. |
| Not used | The accessibility tree, and drawing-layer classes. Layers are used for masking only, never for identity. |

**Masking**

- **What is masked.** The mask is the union of:
  - the frames of allowlisted SwiftUI text and image layers inside hosting
    views;
  - UIKit text views (`UITextField`, `UITextView`, `UILabel`);
  - `WKWebView` and `UIViewRepresentable` host bounds, fail-closed.
- **Unclassified layers.** Any layer with `contents` inside a hosting view
  whose class is not on the allowlist is masked fail-closed.
- **Over-masking.** `CGDrawingLayer` is a generic drawing layer that also
  carries shapes and custom drawing. Masking every one of them over-masks,
  which is accepted. It is never treated as "text only".
- **Image padding.** Image layer frames are padded by 4 pt, because the
  probe's image layer was slightly smaller than its layout frame.
- **Versioned allowlist.** Class names are matched as exact strings per iOS
  major version. The `CGDrawingLayer` class is a mangled private Swift type
  and can change between releases. Matching is read-only class-name
  comparison and makes no private API calls.
  - Verified: iOS 26 (`SwiftUI.ImageLayer` and
    `_TtC7SwiftUIP33_863CCF9D49B535DAEB1C7D61BEE53B5914CGDrawingLayer`).
  - Any iOS major version without a verified entry, including 15–25 for now,
    masks the whole frame until it is verified. Each verification is an open
    item in the decisions log.
- **Regression guard.**
  - An XCTest renders a screen known to contain text and an image, and
    fails loudly when no allowlisted class is found.
  - The probe is kept on its spike branch so it can be re-run on each new
    iOS major version.

## 7. Configuration, IDs and metadata

The native host builds `engine.configure` from `TugboatConfig` and the
device. `session_start` requires these fields (section 9):

- `app.version` and `buildNumber`;
- the full `device` object with `screenSize`, `screenDensity`, `screenDpi`,
  and `screenPixelDensity`;
- `ipInfo.ip` (a placeholder, as Flutter does);
- `locale`.

The host refuses to start a session if any is missing. Defaults: limits,
gesture slops, and the claim, settle, and collector timings from
stateful-engine.md section 6.

## 8. Testing

| Kind | What |
| --- | --- |
| JVM unit tests | Host message plumbing, the handle table, header construction, and config validation, with a fake engine transport |
| Robolectric | Views and Compose adapter fact extraction and canonical paths on fixture screens; mask sources per section 2.1; `Window.Callback` chaining |
| Instrumented (emulator) | Window capture plus masks, and end-to-end fact batching |
| XCTest | Host plumbing, the SwiftUI adapter on hosted views, and the layer-allowlist regression guard (section 6.3). Built and run by the local orchestrator. |
| Contract tests, both platforms | Pinned against the engine's actual output: the `session_start` body shape with every required field, and `frameMetadata[].requestedBackend` / `resolvedBackend` equal to `nativeCpuExperimental` |

## 9. Collector contract (fixed for this milestone)

Routes:

- `POST /v1/sessions`, `POST /v1/events/batch` (at most 100 per batch; the
  engine sends 10), and `POST /v1/frames` (multipart). Success is 202 only.
- 400 drops the whole batch and is never retried, so the SDK must be strict
  before sending.

Headers:

- `X-Tugboat-API-Key`, mirrored as `X-PMKit-API-Key` like Flutter;
- `X-Platform`, `X-App-Build`, `X-App-Version`, `X-App-Id`, `X-SDK-Version`.

Validation traps the engine and hosts must avoid:

1. **`frameMetadata` backend values are a closed enum**
   (`flutterRepaintBoundary` | `nativeCpuExperimental`). Native SDKs send
   `nativeCpuExperimental` for both fields. They do not invent a native
   backend name (logged as an open cross-repo item).
2. `stream` ∈ `semantic`, `evidence`, `diagnostic`, `legacy_projection`.
3. v2 interactions:
   - only the seven gestures, each with its fact allow-list and range
     checks;
   - no `stateAnchor`;
   - new fields go in `targetAnchor` only.
4. `external_event` and `network_call` have strict payload allow-lists and
   size limits. Native SDKs do not emit them in this milestone.
5. `session_start` must have the fields in section 7.

Other wire rules:

- Unknown top-level event fields are dropped silently, so anything that must
  persist goes in `payload` or `targetAnchor`.
- New `capture_diagnostic` components (C6 gap records) are accepted.

## 10. Sample apps and device-test handoff

- The collector base URL and key come from build config or launch arguments.
  - Android: Gradle properties `tugboat.collectorUrl` and
    `tugboat.collectorKey`, defaulting to `http://10.0.2.2:3000`.
  - iOS: launch arguments `-TugboatCollectorURL` and `-TugboatCollectorKey`,
    defaulting to `http://127.0.0.1:3000`.
  - The default key on both is `pmk_blend-app-dev-secret`.
- Debug builds allow cleartext to those hosts only: an Android network
  security config, and iOS `NSAllowsLocalNetworking`.
- Script for each sample: launch → tap a button → scroll the list → swipe →
  open the second screen → type in the text field → rotate to landscape and
  back → background → foreground → stop.
- Expected collector rows:
  - `pmkit.sessions`: `session_start` and `session_end`.
  - `pmkit.raw_events`:
    - `route_change` for each screen;
    - tap, scroll, and swipe interactions whose `targetAnchor.toolkit` is
      `view` / `compose` / `swiftui`;
    - `focus_changed`;
    - lifecycle events.
  - Masked frames in `pmkit.frame_captures` and S3.
  - No 400s.
- The SwiftUI accessibility probe ran on iOS 26.5 (section 6.3). The
  device test on the simulator checks that SwiftUI frames mask text and
  images per layer instead of the whole frame.

## 11. Order of work after approval

Platform plumbing that does not depend on engine state starts early, in
free cloud-agent slots, while the engine phases run:

- `capture-runtime` window capture (0.2.0);
- the `TugboatSessionEngine` SwiftPM target, with an iOS build handoff;
- the Kotlin host's JNI bridge, handle table, and HTTP executor against the
  stateless protocol.

After 3d:

1. Android: `tugboat-android` host and Views adapter, then
   `tugboat-compose`, then the sample.
2. Apple, in parallel: host, SwiftUI adapter, and sample. Hand off for an
   iOS build at each step.
3. Each sample goes to the orchestrator for device testing once it builds.
