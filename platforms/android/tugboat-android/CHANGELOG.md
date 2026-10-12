# tugboat-android

## 0.1.0

Unpublished. The native Android SDK for Views apps: public facade, engine
wiring, window capture, and the Android Views adapter.

- Public API (`com.tugboat.android`): `Tugboat.start(application,
  TugboatConfig)`, `setUserId`, `setTraits`, `stop`, `trackNavigation(navController)`
  (Jetpack Navigation, `compileOnly`), `View.tugboatTag`; `TugboatConfig`,
  `CollectorConfig`, `AppInfo`, `MaskLevel`. Idempotent start; nothing
  throws into the app.
- Engine wiring: `engine.configure` with every `session_start` field the
  collector requires (start is refused and logged when one is blank),
  `limits`, the adapter's `gesture`, `capture.answerTimeoutMs` 5000,
  `collector.enabled`, `focusChanges` / `systemInput` capabilities;
  `session.start`; `ProcessLifecycleOwner` to `app.lifecycle`
  (`androidx.lifecycle:lifecycle-process`, the one new runtime dependency);
  `identity.set` / `traits.set`; adapter facts as per-frame batches with
  `navigation` facts on (engine phase 3d).
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
  signature; coverage and a `secureWindow` failure are sent once the engine
  accepts them.
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
