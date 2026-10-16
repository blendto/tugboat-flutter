# Tugboat (Swift host)

The version is `TugboatVersion.current` in `TugboatVersion.swift`; the newest
entry here must match it.

## 0.1.0

Unpublished. The native SwiftUI SDK: public facade, engine wiring, capture,
the SwiftUI adapter, and a sample app (`platforms/apple/Samples/TugboatSwiftUISample`).

- Public API: `Tugboat.start(TugboatConfig)`, `setUserId`, `setTraits`,
  `stop`; `TugboatConfig` (`Collector`, `App`, `MaskLevel`,
  `captureFocusChanges`, `trackHostingControllers`,
  `swiftUIAccessibilityIdentity`);
  the `.tugboatTag(_:accessibility:)` and `.tugboatScreen(_:)` view
  modifiers. Idempotent start; nothing throws or traps into the app.
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
  already deliver, sent as JSON text (complete and JSON) or as text cut
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
  `collector.enabled`, `focusChanges`; `session.start`;
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
  `nativeCpuExperimental`; `frame.maskCoverage` on every captured frame;
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
