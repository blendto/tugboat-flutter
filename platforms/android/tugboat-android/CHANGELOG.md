# tugboat-android

## 0.1.0

Unpublished. The native Android SDK for Views apps: public facade, engine
wiring, window capture, and the Android Views adapter.

- Public API (`com.tugboat.android`): `Tugboat.start(application,
  TugboatConfig)`, `setUserId`, `setTraits`, `stop`, `trackNavigation(navController)`
  (Jetpack Navigation, `compileOnly`), `View.tugboatTag`; `TugboatConfig`,
  `CollectorConfig`, `AppInfo`, `MaskLevel`. Idempotent start; nothing
  throws into the app. `TugboatConfig.enabled` (default `true`): when
  `false`, `start` installs nothing and every API is a no-op.
- Config: `captureDiagnostics` (engine capability), optional
  `activationRequestId` / `explorationRunId` on `session.start` when set.
- Locale: `locale.set` on primary locale change (`onConfigurationChanged`),
  deduped, unregistered on `stop`.
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
  without arguments).
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
