# Tugboat (Swift host)

The version is `TugboatVersion.current` in `TugboatVersion.swift`; the newest
entry here must match it.

## 0.1.0

Unpublished. The native SwiftUI SDK: public facade, engine wiring, capture,
the SwiftUI adapter, and a sample app (`platforms/apple/Samples/TugboatSwiftUISample`).

- Event shape on iOS, as Flutter and the Android SDK: starting while the app is
  active reports `resumed` once, so a launch records `app_foregrounded` (a start
  before the app is active gets it from `didBecomeActive`; like every `resumed`
  it requests a forced `lifecycle` capture, which a queued `initial` capture
  absorbs: the sample's launch still uploads an `initial` and a `route` frame); an HTTP error
  response that carried no bytes records an empty text `errorResponseBody` through
  the instrumented session and `Tugboat.data(for:)` (an empty JSON body gives
  none; the Alamofire monitor sees no data for it and records none), as `tugboat-okhttp` and Dio; a named view's
  anchor carries `actions: ["tap"]` and `enabled` (the view takes touches and is
  not marked not-enabled).

- Seams for the React Native SDK (no change for apps that do not use them;
  `@_spi(TugboatAdapters)`, not public API): `TugboatAdapters.setScreen(name:instanceId:)`
  names the current screen without `.tugboatScreen` (a push, or a pop to an
  instance id already on the stack, plus the route key);
  `setViewNameProvider` gives plain UIKit views a name (a `testID`): a named
  view is a tap target and a `Named#<ordinal>` path segment, and its name is
  the anchor's tag and alias; `setViewRoleClassifier` says which view classes
  draw their own text or images, which the screenshot then masks whole;
  `markSensitive(_:)` masks a view and its subtree like `.tugboatSensitive()`
  without changing identity; `setHostNamesScreens(true)` makes the first screen
  named in a session its initial route (`session_start` with `captureFrame`, as
  Flutter, a frame of its own) instead of a push. Off by default.

- SwiftUI masks on iOS 27 (BLE-702): the layer allowlist and the SwiftUI
  platform-view hosts are verified for iOS 27 (same class names as iOS 26;
  probed on the iOS 27.2 simulator, 2026-11-28; the iOS 27.0.1 device run is
  pending). Before, every window with a SwiftUI hosting view (for example a
  React Native native-stack header) was masked whole on iOS 27
  (`unverifiedLayerAllowlist`). An iOS major without an entry still masks such
  a window whole.

- Fingerprint schema 7 and alias confidence (contract change: identity,
  BLE-670): anchors carry `schemaVersion` 7, read from the engine
  (`tb_session_engine_fingerprint_schema_version()`), as Flutter 0.11.0+. The
  hash is unchanged; schema 7's Flutter canonical-tree rules do not apply to a
  SwiftUI path. A tag no longer raises confidence: the path is `medium` in a
  list cell and `low` otherwise (a tag made it `high`), as Flutter 0.12.x. A
  target anchor is never `high`. The collector `session_start` `appInfo`
  carries `installationId` and frame uploads carry `frameMetadata.triggeredAt`
  (Flutter 0.11.5 and 0.12.3).

- Session and event ids, installation id (contract change: identity, BLE-618):
  session ids are `session-<UUIDv4>` and event ids `event-<UUIDv4>` (were
  `session-<epoch microseconds>` and `event-<counter>`), as Flutter 0.12.3;
  the host sends the engine 32 fresh random bytes (`session.start.idSeed`)
  per session. `TugboatConfig.App.installationId` is now optional: when blank
  the SDK mints a random UUID on first launch (seeded with
  `identifierForVendor`), keeps it in `tugboat/installation_id` under the
  Application Support directory, and sends it as `appInfo.installationId`,
  as Flutter 0.11.5. The file is read or written on the engine queue, before
  `session.start`, never on the main thread. A non-blank host id wins.
  `TUGBOAT_LAUNCH` / `TUGBOAT_HEALTH` print the new `session-<UUIDv4>` id.
- Delivery under stalled uploads (contract change: sink behaviour; matches
  Flutter 0.11.1 and 0.11.2, engine rules in `core/session-engine`):
  frames wait under 400 frames and 8 MiB and evict unreferenced frames
  first; a pass uploads frames between event batches and drains only the
  events queued when it began; a hung or failing events endpoint holds fresh
  events in retry batches unsent; a rejected lifecycle post other than
  `session_start` is dropped; `collector_request` and `collector_flush`
  diagnostics and the final frame drop count are recorded; lifecycle `atMs`
  stays on the monotonic clock. The engine reports the sink's real `pending`,
  `accepted` and `dropped` (`engine.health`), SDK-local, never sent to the
  collector.
- Background flush (contract change: delivery): with `durableOutbox` on,
  entering the background runs `transport.flush` under a `UIApplication`
  background task that ends once the flush's outbox writes land, or at
  expiration. Nothing is begun in an app extension.
- Privacy manifest: `PrivacyInfo.xcprivacy` declares system boot time
  (`35F9.1`) and file timestamp (`C617.1`) API use, no tracking, and the
  collected data types (see README, "Privacy manifest").
- The outbox forgets a key's attempt number once its last request is
  answered, so its in-memory tracking no longer grows with every key sent.

- Frame backend name (contract change: `frameMetadata` values):
  `requestedBackend` and `resolvedBackend` are `iosViewHierarchy`, no
  longer `nativeCpuExperimental`. Needs a collector that accepts the native
  backend names (pmkit-collector#38); an older one rejects every frame
  upload with 400.
- Public API: `Tugboat.start(TugboatConfig)`, `activate(activationRequestId:)`,
  `deactivate()`, `setUserId`, `setTraits`, `stop`; `lifecycleState`,
  `isActivated`, `activationRequestId`; `TugboatConfig` (`Collector`, `App`,
  `enabled`, `MaskLevel`, `captureFocusChanges`, `captureDiagnostics`,
  `trackHostingControllers`, `swiftUIAccessibilityIdentity`,
  `explorationRunId`); `TugboatLifecycleState`;
  the `.tugboatTag(_:accessibility:)`, `.tugboatSensitive()`,
  `.tugboatScreen(_:presentation:)` and `.tugboatNavigator(_:)` view
  modifiers. Idempotent start; nothing throws or traps into the app.
- Activation matches Flutter's `TugboatReplay` (contract change, D1):
  `TugboatConfig.enabled` defaults to `false`, so `start` stores the
  configuration and stays dormant (no engine, observers, method exchange,
  threads, or network) until `activate(activationRequestId:)`; `enabled: true`
  starts a session at `start` with no activation id. `activate` puts the id
  on `session.start` (blank is omitted; Flutter sends `""`), is a no-op for
  the same id, and for a new id ends the session and starts another with a
  new `sessionEpoch` (`active → starting`, never `stopping`); one made before
  `start` is applied by `start`. `deactivate()` fences coded events and
  network calls on the calling thread, ends the session (`session_end`), and
  keeps an `enabled: true` configuration down until the next `activate`.
  `stop()` also forgets the activation request and that override; it is not
  Flutter's `disabled`. With launch inputs, `TUGBOAT_LAUNCH` is logged at
  `start` whatever the lifecycle and `TUGBOAT_HEALTH` ten seconds later, each
  with the running session's `captureSessionId` (none while no session runs);
  HEALTH reports the lifecycle state name and `activationRequestId` and is
  cancelled only by `stop()`. User id, traits, and event hooks are kept
  across dormant periods. The hosting-controller method exchange is
  installed at the first session start, never while dormant, adopts the
  hosting controllers already on screen for the `session_start` seed, and
  stays installed (inert) after `deactivate` or `stop`. While no session
  records, `.tugboatScreen` callbacks keep only the current navigator stacks
  (no unbounded queue).
- `locale.set` on `NSLocale.currentLocaleDidChangeNotification` (same object
  as `session.start.locale`, deduped, observed only while a session runs);
  `TugboatConfig.captureDiagnostics` (engine capability
  `captureDiagnostics`, default off); `TugboatConfig.explorationRunId` on
  `session.start` when non-blank (Flutter sends a blank one verbatim).
- `.tugboatSensitive()`: the view's frame is masked in every mask mode,
  including the verified layer-allowlist path where plain colour fills stay
  visible. The mask walk masks the marker's host by kind
  (`ViewKind.sensitiveMarker`); identity skips it, so taps, paths, and
  fingerprints are unchanged.
- Coded events and network calls, the Flutter evidence API:
  `Tugboat.eventHook(source:parameterPolicy:)` → `TugboatEventHook.record(_:parameters:)`
  (`external_event`), with `TugboatParameterPolicy` `.allowAll` (default),
  `.namesOnly`, `.allowList`, `.transform` and the `.drop` sentinel; and
  `Tugboat.beginNetworkCall(method:route:)` → `TugboatNetworkCall`
  `complete(statusCode:attemptCount:errorResponseBody:)` /
  `fail(_:statusCode:attemptCount:errorResponseBody:)` with
  `TugboatNetworkFailure` `.networkError` / `.cancelled` (`network_call`).
  Callable from any thread; the time is taken on the calling thread. A
  token counts only its first `complete` or `fail`; a nil or empty route,
  or a call while not started, stopped or disabled, records nothing. The
  session engine applies the policy, limits and error-body rule
  (`evidence.externalEvent`, `evidence.networkCall`); the SDK runs a
  `transform`, sorts keys, and encodes values. The sample records one
  event and one call.
- Automatic network calls, opt-in and without `URLProtocol` or swizzling:
  `Tugboat.instrumentedSession(configuration:delegate:delegateQueue:routeResolver:)`
  returns a `URLSession` whose delegate forwards every callback the app's
  delegate implements, unchanged, and records one `network_call` per task.
  Timing comes from the task's metrics; `URLError.cancelled` is
  `cancelled`, other errors are `network_error`. For status 400 or more,
  delegate-based data tasks keep at most 65,537 bytes of the body they
  already deliver, sent as JSON text (complete, and `application/json`,
  `text/json` or `+json`) or as text cut
  within 4100 bytes (evidence-messages.md section 4.5). Completion-handler,
  `async`, and download tasks record no body. `Tugboat.data(for:session:delegate:route:)`
  records an `async` call with its error body on any session, including
  `URLSession.shared`. `TugboatRouteResolver` is
  `(URLRequest) throws -> String?`; its result is trimmed as Dart trims, and
  nil, empty, or a throw records nothing. `URLSession.shared` and other
  sessions are not observed. Query strings, headers, request bodies, and
  error text are never read. The manual API is unchanged. Internally,
  `EvidenceEncoder` sends a byte-read JSON body as `{"jsonText": …}`, and
  `@_spi(TugboatAdapters)` adds what the separate `TugboatAlamofire`
  package needs.
- Nested navigators and presentation kinds, set by the app (nothing is
  read from UIKit yet): `.tugboatScreen(_:presentation:)` takes
  `TugboatScreenPresentation` `.automatic` (default, `page` for now),
  `.page`, `.sheet`, `.dialog` or `.popup` as the route's `overlayKind`;
  `.tugboatScreen("X")` still compiles and its facts are unchanged. A
  sheet's screen without its own stack is a route on the presenting
  navigator, so the engine records `presentedOver*`, and its dismissal is
  the existing `pop`; a sheet with its own stack puts its root screen
  inside its `.tugboatNavigator`.
  `.tugboatNavigator(name)` puts the screens inside it on navigator
  `swiftui-screens/<name>`, with `parentNavigatorId` the enclosing
  navigator on transitions and `session_start`; the root navigator stays
  `swiftui-screens` with no parent. A nested navigator is forgotten when
  its host screen leaves, and a stacked sheet's navigator when the sheet is
  dismissed from any depth. Tab switches send nothing (the hidden tab
  keeps its stack; route keys follow the shown tab). The first navigation
  after a tab return or a stacked sheet's dismissal is not attributed to
  its tap (no cause, no afterFrame). A navigator forgotten and used again
  in a session gets an engine id not yet issued in that session
  (`<name>`, `<name>#2`, …; navigators live at `start()` keep theirs), so
  a reopened stacked sheet starts a fresh engine stack. Sibling navigators are treated as
  mutually exclusive, like tabs: not for any `NavigationSplitView` column
  or panes shown together (a collapsed split's back sends nothing and the
  detail stack grows; detail-only opt-in reports each back as a root
  `push`), and every tab needs its own navigator with a screen (otherwise
  a hidden tab is torn down and its next back is a `push`). `session_start` seeds every navigator with a
  non-empty stack, the visible chain last, and route keys follow the
  visible chain's top. Contract change for apps that opt in: a sheet's
  route identity moves from `page` to `sheet`. Hosting-controller routes
  stay `page`.
- `.tugboatTag(_:accessibility:)`: `accessibility: true` (default false)
  also sets the tag as the content's `accessibilityIdentifier`, for UI tests
  and exploration runs; the marker stays hidden from accessibility and
  identity is unchanged. `.tugboatTag("x")` still compiles. Measured by the
  sample's XCUITests (`TugboatSwiftUISampleUITests`, CI job `sample-ui`).
- `TugboatConfig.swiftUIAccessibilityIdentity` (ADR 0010): opt-in identity
  for untagged SwiftUI taps from the in-process accessibility tree, `.off`
  by default, `.sampled(rate:)` drawn once per process launch, or `.on`.
  Only on iOS 18 (elsewhere as `.off`). Taps that would be
  `no_actionable_candidate`, or resolve to a list cell or scroll view, get
  an `AXIdentified#<k>` or `AX<Role>#<k>` path segment; the identifier's
  value, labels and values are never sent. The tree is built once per
  process on the main queue's next turn after the first such tap, and its
  measured scroll, CPU and memory cost lasts for the process (see the
  README). Tagged and UIKit taps are unchanged.
- Engine wiring: `engine.configure` with every `session_start` field the
  collector requires (start is refused and logged when one is missing),
  `limits`, the SwiftUI `gesture`, `capture.answerTimeoutMs` 5000,
  `collector.enabled`, `focusChanges`, `captureDiagnostics`; `session.start`;
  application notifications to `app.lifecycle`; `identity.set` /
  `traits.set`; adapter facts (navigation included) as per-frame batches.
- `stop()`: `session.end`, then `engine.dispose` and handle destruction once
  the `session_end` post settled (bounded at 25 s on a background thread;
  immediate when none will be posted). Nothing is kept alive when the post
  never settles.
- Capture: `capture.request` drawn by `TugboatCaptureRuntime` 0.2.0
  (`viewHierarchy`, the key window). Masks, structure signature, boundary,
  `surface`, and pixel size come from one reading in the same main-thread
  turn as each draw; every request answered once by id, in any order
  (C16); every runtime status mapped explicitly; `frameMetadata` backends
  `iosViewHierarchy`; `frame.maskCoverage` on every captured frame;
  `surface` on window size changes (key-value observation).

- SwiftUI adapter (internal): `input.pointer` (window points, unique contact
  ids, tap evidence at the down position), `scroll`, `navigation`, and
  `focus` facts, batched once per frame; SwiftUI identity (`.tugboatTag`
  frames, UIKit roles, list index paths, `.tugboatScreen` route keys,
  `toolkit: "swiftui"`); mask rectangles for `allTextAndMedia` from UIKit
  views and a per-iOS-major SwiftUI layer allowlist (iOS 26), fail-closed
  elsewhere (unverified majors, animations, opaque renderers, app
  representables), with a per-frame `MaskCoverage` summary.

- `EngineBridge`: calls the session engine's C ABI directly through the
  `TugboatSessionEngine` SwiftPM target and copies each engine-owned
  response into `Data`.
- Engine host: one handle driven from one serial `tugboat.engine` queue.
  Facts are posted with their own `at`. A non-`ok` status drops the message
  and releases its frame handles. Three `internal_error`s in a row shut the
  host down. Shutdown first submits `engine.dispose` (the engine reports
  undelivered work), honouring its `frame.release` but starting no new IO
  or timers.
- Effect executors:
  - `timer.schedule` / `timer.cancel` (`DispatchSourceTimer` on the uptime
    clock, saturating deadlines);
  - `http.send` (ephemeral `URLSession`, the Flutter collector headers and
    multipart layout, `timeoutMs` as a total deadline, no redirects, a
    response body of at most 64 KiB cut at a UTF-8 boundary, and statuses
    outside 100–599 reported as `error`);
  - `frame.release` (frame handle table).
- Durable outbox, opt-in (`TugboatConfig.durableOutbox`, default `false`;
  `outboxMaxBytes`, `outboxMaxEntries`, `outboxMaxAgeMs`,
  `outboxMaxAttempts`): requests the collector has not accepted are kept in
  `Application Support/Tugboat/outbox/v1/` (excluded from backup,
  `completeUntilFirstUserAuthentication`) under keys derived from their
  bodies, written alongside the send, deleted on a 202 or a non-retried
  status (a late answer for an earlier attempt never deletes), and
  replayed one at a time, oldest first, with backoff and `Retry-After`,
  only while a later session runs; `outboxMaxAttempts` counts replays, not
  engine retries. Every `start` with the outbox on (dormant included) runs
  a disk-only sweep for the age and size bounds. Unreadable files are
  skipped, never deleted. Keyed requests carry
  `Tugboat-Delivery-Key`. Entries hold no API key (a salted HMAC of base
  URL, app id and key; a mismatch deletes unsent). New
  `Tugboat.clearPendingData()`; a `start` with `durableOutbox` false also
  wipes, a dormant start keeps; sessions started before a wipe write
  nothing more. With the outbox on, `paused` also posts
  `transport.flush`. Contract change: delivery (sink behaviour).
- `HTTPExecutor` forwards a trimmed `Retry-After` on `transport.result` (at most
  128 bytes); a longer value is dropped so the engine never rejects an
  otherwise valid answer.
- Device Farm exploration tooling: when `TUGBOAT_EMIT_SCENE_INVENTORY` /
  `TUGBOAT_ACCEPT_ACTION_CONTEXT` (environment or `--tugboat-*` launch args)
  request capture, log `TUGBOAT_LAUNCH` and `TUGBOAT_HEALTH` once per process
  via `os_log` (subsystem `com.gettugboat.sdk`, category `launch`). iOS device
  logs are not consumed by exploration tooling today; parity is for operators
  and future scraping. Collector URL override not applied in v1.
