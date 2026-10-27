# tugboat-android

## 0.1.0

Unpublished. The native Android SDK for Views apps: public facade, engine
wiring, window capture, and the Android Views adapter.

- Overlay windows: frames captured while a dialog, sheet, or focusable menu
  of the activity is showing keep activity masks, add `overlayWindow` to
  `maskCoverage.reasons`, and add an overlay token to the structure
  signature, so they are never coalesced with overlay-free frames. Detected
  by focus loss while resumed and, on API 29+, owned `WindowInspector` roots.
- Public API (`com.tugboat.android`): `Tugboat.start(application,
  TugboatConfig)`, `setUserId`, `setTraits`, `stop`, `trackNavigation(navController)`
  (Jetpack Navigation, `compileOnly`), `View.tugboatTag`; `TugboatConfig`,
  `CollectorConfig`, `AppInfo`, `MaskLevel`, `emitSceneInventory` (default
  false). Idempotent start; nothing throws into the app.
- Activation lifecycle matches Flutter (contract change):
  `TugboatConfig.enabled` defaults to `false` and means dormant until
  `Tugboat.activate(activationRequestId)` (no engine, window callbacks,
  threads, or network; only process-scoped activity lifecycle callbacks);
  `true` starts a session at `start` with no activation request id.
  `activate` with a new id ends the session and starts one carrying the id
  (new session id and `sessionEpoch`); the same id is a no-op; an `activate`
  before `start` applies at `start`. `Tugboat.deactivate()` fences evidence
  on the calling thread, ends the session, and keeps an `enabled = true`
  config dormant until the next `activate`. `stop()` (not Flutter's
  `disabled`) also clears any activation request. Read-only
  `Tugboat.lifecycleState` (`TugboatLifecycleState`), `isActivated`, and
  `activationRequestId`. A session that starts while an activity is resumed
  attaches to it at once (taps, captures, launch lines, navigation seed);
  `trackNavigation` after a dormant `start` keeps the controller's stack.
  `TUGBOAT_HEALTH` reports the state's Flutter name and
  `activationRequestId`. The user id, traits, and event hooks feed every
  session.
- Config: `captureDiagnostics` (engine capability), optional
  `explorationRunId` on `session.start` when set. `activationRequestId` is
  no longer a config field: it comes from `activate`.
- Locale: `locale.set` on primary locale change (`onConfigurationChanged`),
  deduped, unregistered on `stop`.
- Native scene inventory: when `emitSceneInventory` is true, the Views
  adapter sends `scene.inventory` after each captured frame (the
  post-navigation route capture covers route changes) for the route of the
  visible content (the deepest shown, resumed fragment, such as a
  `NavHostFragment`'s destination or the current `ViewPager2` page, else the
  activity; a fragment paused at `STARTED` while its host is resumed is
  skipped; activity-level chrome outside it, such as a `Toolbar` or
  `BottomNavigationView`, is not inventoried); the engine
  records deduped `scene_inventory` (`nativeSceneInventory` capability). A
  frame of a window without Compose hosts whose structure signature matches
  the route's last emitted inventory is not walked (a view that only becomes
  clickable is then missed); windows with Compose hosts are walked on every
  captured frame. `FLAG_SECURE` windows have none. The walk collects at most
  500 elements and sends the candidates found as `totalElements`.
- Coded events and manual network calls: `Tugboat.eventHook(source,
  parameterPolicy).record(name, parameters)` (`external_event`) and
  `Tugboat.beginNetworkCall(method, route)` with `complete(statusCode,
  attemptCount, errorResponseBody)` / `fail(NetworkFailure, …)`
  (`network_call`), with `ParameterPolicy` `allowAll` (default), `namesOnly`,
  `allowList`, `transform` + `DROP`. Callable from any thread, timed on the
  calling thread, one finish per call, no-ops while not started. Kotlin runs
  the transform and encodes the values; the engine (`evidence.externalEvent`,
  `evidence.networkCall`) applies the policy, the limits, and the error-body
  rule, as Flutter does.
- HTTP-adapter seam (`com.tugboat.android.adapter`, opt-in
  `@TugboatAdapterApi`, not app API) for `tugboat-okhttp`:
  `HttpErrorBody.jsonText` / `text` as an `errorResponseBody` (the encoder
  sends `{"jsonText": …}` whole, or `{"value": …}` as a text body),
  `TugboatAdapters.isAcceptingEvidence`, and `tapEvidenceForTesting`. The
  `jsonText` conformance fixtures now run through this path (JVM and device).
- Docs: `View.tugboatTag` has no accessibility option. UI test tools read
  the resource-id from `android:id`, which the resolver already uses as the
  alias fallback; no `AccessibilityDelegate` is installed (it would replace
  the app's).
- Engine wiring: `engine.configure` with every `session_start` field the
  collector requires (start is refused and logged when one is blank),
  `limits`, the adapter's `gesture`, `capture.answerTimeoutMs` 5000,
  `collector.enabled`, `focusChanges` / `systemInput` / `captureDiagnostics`
  capabilities;
  `session.start`; `ProcessLifecycleOwner` to `app.lifecycle`
  (`androidx.lifecycle:lifecycle-process`, the one new runtime dependency);
  `identity.set` / `traits.set`; adapter facts as per-frame batches with
  `navigation` facts on (engine phase 3d).
- `trackNavigation` destinations are `navigation` facts on a navigator
  nested under the activity's (`route_change` per destination, route names
  without arguments). Once the SDK has started, the NavController listener
  updates process-scoped stacks even while the SDK is stopped; the next
  `start()` seeds the current destination. Destinations reported before the
  first `start()` are not seeded: that stack is discarded when observation
  installs, and the next destination change is a `push`.
- Adapter `start()` emits `session_start` snapshots in tree order
  (background tasks first, visible chain last) so the engine's visible route
  matches the foreground screen. A navigator whose host route is in no stack
  is not seeded.
- Focus is reported once per frame where it settled: a Compose host taking
  View focus before its text field does is one `text_input`. Focus is
  app-wide: a window that becomes active (its activity resumed) reports
  its focus, so leaving a focused field for another activity is
  `focus_changed none|other`; only the active window reports.
- `stop()`: `session.end`, then `engine.dispose` and handle destruction once
  the `session_end` post settled (bounded at 25 s).
- Capture: `capture.request` answered with `capture-runtime` window capture
  (`capture-runtime` 0.3.0 is now a dependency). Masks, the motion check,
  the structure signature, and the boundary are taken on the main thread
  immediately before `PixelCopy.request` (`WindowMaskSupplier`), filled
  before encoding; `nativeCpuExperimental` for both backend fields; every
  overlapping request answered by id; the `initial` capture waits up to 3 s
  for a foreground window; `surface` facts from the foreground decor view.
  Masks fail closed (whole frame) while a legacy view animation or
  `LayoutTransition` runs. The mask walk reports its coverage
  (`precise` / `wholeHost` / `wholeFrame` and reasons) and hashes class, id,
  visibility, and checked / selected / activated state into the structure
  signature. Every captured frame carries `maskCoverage` (the engine records
  a `capture_masking` diagnostic), and a secure window is answered `failed
  secureWindow`. `MaskCoverageReason` uses only the engine's
  reason names (`noDecor`, `noWindowSize`, `walkExhausted` replace
  `treeUnreadable` / `regionUnreadable`; `webView`, `surfaceLayer` added).
- Collector contract test (instrumented, real engine): `session_start` body
  and `frameMetadata` backends.

- Views adapter (internal): `input.pointer` (dp, unique contact ids, tap
  evidence at the down position), `scroll`, `navigation`, `focus`, and
  `systemInput` facts, batched once per frame; Android Views identity
  (platform-class tokens, resource entry names, list items, route keys,
  `tugboatTag` alias, `toolkit: "view"`); mask rectangles for
  `allTextAndMedia` with fail-closed bounds (including Compose hosts).
  androidx `core`, `fragment`, and `recyclerview` are optional
  (`compileOnly`). `navigation` facts are held back until engine phase 3d.
- Toolkit-region seam (`com.tugboat.android.toolkit`, opt-in
  `@TugboatToolkitApi`): a module such as `tugboat-compose` registers a
  `ToolkitRegion` that resolves taps, the scrollables under a touch, masks
  (`Rects` / `WholeHost` / `WholeFrame`), and focus inside its host views.
  The Views adapter consults it before its own rules and before the
  fail-closed Compose host rule (now `AndroidComposeView` only); region
  hosts are kept views with their own path token; anchors carry the
  region's `toolkit`. `WindowMasks` reports `MaskCoverage {mode, reasons}`
  per capture.
- Route patterns lose their arguments in `DestinationTracker`
  (`checkout/{id}?step={s}` is `checkout`), one route key for Views,
  Compose, and navigation facts.
- `libtugboat_engine.so`: the session engine (`core/session-engine`) built
  with `c++_static`, plus a JNI bridge (`create`, `submit`, `destroy`) that
  copies each engine response into a Java `byte[]`. No exception crosses
  JNI.
- Engine host: one handle driven from one `tugboat-engine` thread. Facts are
  posted with their own `at`. A non-`ok` status drops the message and releases
  its frame handles. Repeated `internal_error` shuts the host down.
  Shutdown first submits `engine.dispose` (the engine reports undelivered
  work), honouring its `frame.release` but starting no new IO or timers.
- Effect executors:
  - `timer.schedule` / `timer.cancel` (uptime clock);
  - `http.send` (`HttpURLConnection`, Flutter collector headers and
    multipart layout, `timeoutMs` as a total deadline, a response body of
    at most 64 KiB cut at a UTF-8 boundary, and statuses outside 100–599
    reported as `error`, so the engine never rejects a `transport.result`);
  - `frame.release` (frame handle table).
- `HttpExecutor` forwards a trimmed `Retry-After` on `transport.result` (at most
  128 bytes); a longer value is dropped so the engine never rejects an
  otherwise valid answer.
- Device Farm exploration tooling: when `tugboat_emit_scene_inventory` or
  `tugboat_accept_action_context` is enabled on the first resumed activity
  whose intent carries the extras, log `TUGBOAT_LAUNCH` once per process and
  `TUGBOAT_HEALTH` ten seconds later (`Log.i`, tag `Tugboat`). Includes
  `captureSessionId` from the `session.start` wall clock when the host is still
  running at the health tick. Never logs collector URL or secrets. Intent extra
  `tugboat_collector_base_url` is ignored in v1 (known gap; see README).
