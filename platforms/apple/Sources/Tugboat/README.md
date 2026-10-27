# Tugboat (SwiftUI SDK)

The native SwiftUI SDK on the session engine
([ADR 0009](../../../../docs/decisions/0009-shared-session-engine.md)).
SwiftPM product and module `Tugboat` in the root `Package.swift`, iOS 15+,
depending on the internal `TugboatSessionEngine` target and (on iOS) the
`TugboatCaptureRuntime` pixel runtime. Versioned on its own (ADR 0008): the
version is `TugboatVersion.current` in `TugboatVersion.swift`, sent as
`X-Sdk-Version` (see [CHANGELOG](CHANGELOG.md)). Unpublished: no podspec yet
(it will be `TugboatSDK`, module `Tugboat`). It mirrors the Android SDK in
`platforms/android/tugboat-android`. The sample app is
[`Samples/TugboatSwiftUISample`](../../Samples/TugboatSwiftUISample/README.md).

## Public API (native SDK note section 3)

```swift
Tugboat.start(TugboatConfig(
  collector: .init(baseURL: url, apiKey: key),
  app: .init(name: name, version: version, buildNumber: build, appId: bundleId, installationId: installId),
  enabled: true,                        // record from launch; the default (false) stays dormant
  captureFocusChanges: true))           // optional; also captureDiagnostics, trackHostingControllers,
                                        // swiftUIAccessibilityIdentity (off), explorationRunId
Tugboat.activate(activationRequestId: requestId) // start capture at runtime (sent on session.start)
Tugboat.deactivate()                    // back to dormant until the next activate
Tugboat.lifecycleState                  // .dormant / .starting / .active / .stopping
Tugboat.setUserId("user-1")             // nil clears; kept across dormant periods and stop/start
Tugboat.setTraits(["plan": "pro"])      // JSON values; kept across dormant periods and stop/start
Tugboat.stop()
someView.tugboatTag("checkout")         // developer alias for a target
someView.tugboatTag("checkout", accessibility: true) // also its accessibilityIdentifier
someView.tugboatSensitive()             // always mask its frame; identity unchanged
someView.tugboatScreen("Checkout")      // route identity for a screen
sheetRoot.tugboatScreen("Filters", presentation: .sheet) // .page (default .automatic), .sheet, .dialog, .popup
stack.tugboatNavigator("cart")          // nested navigator swiftui-screens/cart (per tab, or a sheet's own stack)

let events = Tugboat.eventHook(source: "analytics", parameterPolicy: .allowList(["method"]))
events.record("USER_LOGIN", parameters: ["method": "email"])
let call = Tugboat.beginNetworkCall(method: "GET", route: "/orders/123")
call.complete(statusCode: 200)          // complete(statusCode:attemptCount:errorResponseBody:)
call.fail(.networkError)                // or .cancelled; fail(_:statusCode:attemptCount:errorResponseBody:)

let session = Tugboat.instrumentedSession(configuration: .default, delegate: appDelegate) { request in
  router.route(for: request)            // "/orders/123"; nil records nothing
}
let (data, response) = try await Tugboat.data(for: request, route: "/orders/123") // any session
```

See [Coded events and network calls](#coded-events-and-network-calls) for
the evidence API and
[Automatic network capture](#automatic-network-capture-urlsession-and-alamofire)
for the URLSession helpers and `TugboatAlamofire`.

- `.tugboatTag(_:accessibility:)` with `accessibility: true` also sets the tag
  as the view's `accessibilityIdentifier`, so XCUITest, Maestro, Appium and
  exploration runs find the control by the same id
  (`app.buttons["checkout"]`). It is off by default because apps often set
  their own identifiers for UI tests. Label, traits and VoiceOver focus are
  unchanged, the invisible tag marker stays hidden from accessibility, and
  the identifier is not part of Tugboat identity (target fingerprint,
  canonical path, tag alias and structure signature are the same either
  way). Enable it on a single control: on a container, SwiftUI gives every
  element inside the container's identifier. With two identifiers on one
  view the outermost wins: the app's `.accessibilityIdentifier` applied
  after `.tugboatTag` wins, one applied before it is replaced by the tag, so
  leave the option off on controls that already have one. Measured by the
  sample's `TugboatSwiftUISampleUITests`. There is no UIKit tag API, so
  there is no UIKit equivalent.
- `.tugboatScreen(_:presentation:)` reports the screen's presentation as
  the route's `overlayKind`: `.page`, `.sheet`, `.dialog` or `.popup`.
  `.automatic`, the default, is `.page` in this release. Opting a sheet in
  changes its route identity from `page` to `sheet`.
  - A sheet without its own stack:
    `.sheet { Filters().tugboatScreen("Filters", presentation: .sheet) }`.
    The content takes its navigator from the presenter's environment, so
    the sheet is a route on the presenting navigator, recorded as presented
    over the screen below, and swiping it away is a `pop`.
  - A sheet with its own stack puts its root screen inside its navigator:
    `.sheet { NavigationStack { FiltersRoot().tugboatScreen("Filters", presentation: .sheet) }.tugboatNavigator("filters") }`.
    Pushes and pops inside the sheet then stay on one navigator, with
    their cause and transition time. The sheet root is the first route on
    `swiftui-screens/filters` (its host page is the presenter's page). The
    tap that opens the sheet has no cause, so it has no after-frame, and
    dismissing the sheet, from its root or any depth, sends no fact: its
    navigator is forgotten, route keys return to the presenter at once,
    the engine's visible route at the next navigation. Each reopen is a
    new navigator for the engine (`swiftui-screens/filters#2`, `#3`, … in
    the session), so it starts a fresh stack: its root has the
    presenter's page as host page and nothing presented under it.
- `.tugboatNavigator(_:)` makes a stack its own navigator, such as a
  `NavigationStack` per tab or inside a sheet: the screens inside it are
  routes on `swiftui-screens/<name>`, nested in the enclosing navigator and
  hosted by the `.tugboatScreen` around it, if any (forgotten when that
  screen leaves). A tab switch sends nothing, as Flutter's nested tab
  navigators: the hidden tab keeps its stack, route keys follow the shown
  tab, and the engine's visible route moves at the next navigation.
  The first navigation after a tab return or a stacked sheet's dismissal
  is not attributed to its tap (no cause, no afterFrame).
  Without it every screen is on the root navigator `swiftui-screens`, as
  before. Give every tab its own `.tugboatNavigator` with a
  `.tugboatScreen` inside it. Known limits until UIKit detection lands:
  - Sibling `.tugboatNavigator`s (same enclosing navigator) are treated as
    mutually exclusive, like tabs. Do not put `.tugboatNavigator` on any
    `NavigationSplitView` column, or on panes shown together:
    - with both columns opted in, a collapsed split view's back sends
      nothing, and the detail stack (the SDK's and the engine's) grows by
      one entry per selection;
    - with only the detail column opted in, each back is reported as a
      first-route `push` of the list screen on the root navigator, uncaused
      (the engine's root stack gains a duplicate per back), where without
      the modifier it is a `pop`.
  - A tab with no sibling navigator on screen when you switch away (the
    other tab is a screen on the root, or has no `.tugboatScreen`) is torn
    down: on return its top is a first-route `push`, and the next back in
    it is a `push` of the screen below, the wrong kind.
  - A hidden tab of a tab container that goes away without its host screen
    leaving (a `TabView` inside a sheet, dismissed) is kept: it is seeded on
    restart, and its first screen on the next visit is a `push` that
    departs the old one. Route keys are not affected.
  - Navigation before `Tugboat.start()` or while stopped is applied as one
    batch at start: nested navigators may be torn down, and route keys may
    lag until the next navigation.
  - Names must differ among the navigators that exist together, covered
    screens included: a screen that can be pushed on top of itself shares
    one named navigator between both instances, so give each instance its
    own name (for example with the item's id).

- `swiftUIAccessibilityIdentity` (`.off` by default, `.sampled(rate:)`,
  `.on`) lets untagged SwiftUI taps take identity from the in-process
  accessibility tree. It is costly and cannot be undone for the process;
  read [Accessibility-tree identity](#accessibility-tree-identity-opt-in-adr-0010)
  before turning it on. `.tugboatTag` is the recommended path.

- Call `start` from `application(_:didFinishLaunchingWithOptions:)` (SwiftUI
  apps use `@UIApplicationDelegateAdaptor`). Every method may be called from
  any thread; work runs on the main thread in call order.
- `start` stores the configuration and is idempotent until `stop`. It refuses
  the configuration, and logs the field paths, when a field the collector
  requires on `session_start` is blank or invalid (`app.version`,
  `app.buildNumber`, device screen metrics, locale, …) or the collector URL is
  not http(s). With `enabled: false` (the default) nothing else happens until
  `activate`; see [Lifecycle and activation](#lifecycle-and-activation).
- Nothing throws or traps into the app; failures are logged under subsystem
  `com.gettugboat.sdk`.
- `stop` ends the session, then disposes the engine once the `session_end`
  post settled (202 or a status the engine does not retry), or after 25 s,
  on a background `tugboat-stop` thread; at once when no `session_end` will
  be posted (the host stopped, or `willTerminate` already ended the
  session). The main thread never waits. `deactivate` and a new activation id
  end the session the same way.

## Lifecycle and activation

Native activation follows Flutter's `TugboatReplay` (`enabled`, `activate`,
`deactivate`), with the same states (`TugboatLifecycleState`: `dormant`,
`starting`, `active`, `stopping`).

- `TugboatConfig.enabled` defaults to `false`. A dormant SDK installs
  nothing: no engine, notification observers, KVO, gesture recognizers,
  `UIViewController` method exchange, threads, or network; nothing is
  recorded and the app is unchanged. With `enabled: true` a session starts at
  `start`, with no `activationRequestId`.
- `Tugboat.activate(activationRequestId:)` starts a session whose
  `session.start` carries the id (a blank id still activates and is left off
  the wire; Flutter sends `""`). The same id while starting or active does
  nothing. A different id while active goes `active → starting` at once: the
  current session ends (`session_end`) and a new one starts with the new id
  and a new `sessionEpoch`, never passing through `stopping`. An `activate`
  before `start` is remembered and applied by `start`, even with `enabled:
  false`.
- `Tugboat.deactivate()` stops coded events and network calls before it
  returns, on the calling thread, then ends the session on the main thread.
  The state is `stopping` until `session.end` is posted, then `dormant`. An
  `enabled: true` configuration stays down until the next `activate`.
- `Tugboat.stop()` ends the session and forgets the configuration, the
  activation request and the `deactivate` override; an `activate` after it
  waits for the next `start`. `stop()` is not Flutter's
  `TugboatReplay.disabled`: there is no native switch that makes `activate`
  ignored.
- `lifecycleState`, `isActivated` (an `activate` id is set and the state is
  not `dormant`) and `activationRequestId` are readable from any thread and
  change before `activate`, `deactivate` or `stop` returns.
- State-keeping APIs are never gated: `setUserId`, `setTraits`, event hooks
  and network-call helpers can be used while dormant. The user id and traits
  are sent to every new session; hooks and calls record only while a session
  runs.
- `locale.set` is posted when `NSLocale.currentLocaleDidChangeNotification`
  reports a different locale (same object as `session.start.locale`); the
  observer exists only while a session runs. Locale is evidence, never
  identity.
- The hosting-controller method exchange (`trackHostingControllers`) is
  installed at the first session start, never while dormant. After
  `deactivate` or `stop` it stays installed and inert: the exchanged
  `viewDidAppear` / `viewDidDisappear` call the originals and record nothing.
  It is never exchanged back, because another SDK may have exchanged the same
  methods since and undoing ours would break its chain.

## Device Farm / exploration correlation

Process environment `TUGBOAT_EMIT_SCENE_INVENTORY` /
`TUGBOAT_ACCEPT_ACTION_CONTEXT` (and optional `TUGBOAT_AUTOMATION_RUN_ID`)
or the same spellings as launch arguments (`--tugboat-emit-scene-inventory`,
and so on) mirror the Flutter plugin. Environment wins when both are set.
When either scene-inventory or action-context is enabled (`1` / `true` /
`yes`, case-insensitive), the SDK logs `TUGBOAT_LAUNCH` once per process and
`TUGBOAT_HEALTH` ten seconds later through `os_log` (subsystem
`com.gettugboat.sdk`, category `launch`). Payloads match the Android lines;
`captureSessionId` comes from the first `session.start` clock reading.
`TUGBOAT_LAUNCH` is logged at the first session start, so a dormant launch
logs it when `activate` starts the session. `TUGBOAT_HEALTH` follows ten
seconds later with `lifecycle` set to the `TugboatLifecycleState` name at that
moment, `activationRequestId` when one is set, and `captureSessionId` unless
dormant. A `deactivate` or a new activation id does not cancel it; a
`Tugboat.stop()` before the ten-second mark does. Lines never include collector URL or API material.
`TUGBOAT_COLLECTOR_BASE_URL` is not applied in v1 (collector override is out
of scope here). A later `stop` and `start` does not emit new lines. Device
Farm exploration tooling does not read iOS device logs today; hosted iOS runs
correlate via collector metadata instead.

## Coded events and network calls

The same evidence as the Flutter `TugboatReplay.eventHook` and
`beginNetworkCall`: `external_event` and `network_call` events on
`stream: evidence`, with the same payloads, so the collector and Context
Graph treat them the same. They never inherit an action context or UI
anchors.

```swift
let events = Tugboat.eventHook(source: "analytics", parameterPolicy: .allowList(["method"]))
events.record("USER_LOGIN", parameters: ["method": "email"])

let call = Tugboat.beginNetworkCall(method: "GET", route: "/orders/123")
call.complete(statusCode: 422, errorResponseBody: ["error": "invalid_order"])
```

- `TugboatParameterPolicy`: `.allowAll` (the default: JSON-safe values
  within hard limits, which can include user content), `.namesOnly` (keys
  only), `.allowList(Set<String>)`, or `.transform { key, value in … }`,
  which returns the value to keep (`nil` is kept as null) or
  `TugboatParameterPolicy.drop`. A transform that throws drops that value.
  It runs once per key, in `String <` order, for the first 64 keys that
  are 1 to 128 UTF-16 units long, and never for other keys. Parameter keys
  are always reported.
- A hook holds no session: make it once, before or after `start`; each
  `record` goes to the session running at that moment.
- A network call is one logical request. `route` is a path the app
  chooses (for example from its router, dynamic ids allowed), never a full
  URL. Query strings, headers, request bodies and transport error text are
  never recorded. `complete` or `fail` takes an optional `statusCode`,
  `attemptCount` and `errorResponseBody`; the body is kept, bounded, only
  for a status of 400 or more (below that it is never read): a `String` as
  text, a dictionary or array of JSON values (`NSDictionary` and `NSArray`
  too) as JSON. `Data` gives no body. The duration runs from `beginNetworkCall` to
  `complete` or `fail` on the monotonic host clock.
- Only the first `complete` or `fail` of a token counts. A nil or empty
  route, or a call while no session runs (dormant, not started, deactivated,
  or stopped), gives a token that records nothing; so does finishing a call after its
  session ended.
- Every method may be called from any thread. The time is taken, a
  `transform` runs, and the values are read on the calling thread, before
  the call returns; the message then goes to the main thread in call
  order. Evidence recorded before a `start` made from a background thread
  has run on the main thread is dropped.
- The session engine applies the policy, the hard limits (Flutter's
  `TugboatParameterLimits` and `TugboatNetworkLimits`), label bounding,
  method and route validation, the error-body rule and `durationMs`, so
  every platform shares one implementation
  ([evidence messages](../../../../core/session-engine/docs/evidence-messages.md)).
  Name, source, method and route are sent raw. The SDK only runs a
  `transform` and converts Swift values to the engine's value encoding
  (`Evidence/EvidenceEncoder`, `ValueKind`): an `NSNumber` by its
  CoreFoundation type (a `CFBoolean` is a boolean, a floating number such
  as an analytics `1.0` stays a double), Swift numbers by their exact type
  (`UInt64` beyond `Int64` is unsupported), `Set` as an iterable, cycles
  through `NSArray` / `NSDictionary` as references, and anything else
  (`Date`, `Data`, `Decimal`, `Character`) as unsupported. Swift
  dictionaries have no order, so valid keys are sorted by `String <` at
  every level, with invalid keys (not strings, empty, or over 128 units)
  after them. When a limit cuts a map, a Swift event can therefore differ
  from a Kotlin or Dart one with the same keys. The SDK reads and sends
  only what Dart reads: the first 64 parameters, 256 collection items
  across the whole parameters tree, values to depth 4, and in error bodies
  128 items per collection, strings cut at 4097 UTF-16 units, at most 4097
  values, and writing stops once its strings and keys pass 4096 units.

## Automatic network capture (URLSession and Alamofire)

Opt-in helpers that record `network_call` evidence with the same payload
as the manual API and `tugboat_dio`. No `URLProtocol`, no swizzling, and no
second session: requests and responses are identical with and without
them. The route always comes from the app, through a route resolver or a
`route:` argument, and is trimmed as Dart's `String.trim` trims; nil, empty,
or a throwing resolver records nothing. Query strings, headers (except
`Content-Type`, to classify an error body), request bodies, and error text
are never read.

```swift
// A delegate-based session: status, timing, outcome, and error bodies.
let session = Tugboat.instrumentedSession(
  configuration: .default, delegate: apiDelegate, delegateQueue: nil
) { request in request.url.flatMap(router.route(for:)) }
session.dataTask(with: request).resume()

// async/await on any session, URLSession.shared included.
let (data, response) = try await Tugboat.data(for: request, session: .shared, route: "/orders/123")
```

- **`Tugboat.instrumentedSession(configuration:delegate:delegateQueue:routeResolver:)`**
  returns `URLSession(configuration:delegate:delegateQueue:)` with your
  configuration and queue unchanged. Its delegate is a proxy
  (`Network/DelegateForwarder`): URLSession sees exactly the optional
  methods your delegate implements, and each is passed to it unchanged
  (auth challenges, redirects, response dispositions, data, downloads,
  streams, background events). The proxy also observes `didReceive data`,
  `didFinishCollecting metrics`, and `didCompleteWithError`, forwarding
  each with the same arguments. `session.delegate` is the proxy, so keep
  your own reference to your delegate.
- One event per task: redirects and URLSession's own authentication
  retries stay inside it. A retry your code makes is a new task and a new
  event, with no `attemptCount`.
- Timing comes from the task's own metrics, from the first transaction's
  `fetchStartDate` (the task's start if it never fetched) to the end of
  `taskInterval`, placed before the host clock reading at which the call
  is recorded. The event time is the host clock.
- Outcome: `URLError.cancelled` is `cancelled`; any other error is
  `network_error`, with the status code if a response had arrived; a
  response is `response` with its status code.
- Error body, only for a status of 400 or more, and only for
  delegate-based data tasks: the proxy keeps at most 65,537 bytes of what
  `didReceive data` delivers and passes the same `Data` on. It never reads
  a stream again. A body of 64 KiB or less with a JSON `Content-Type`
  (`application/json`, `text/json`, or `+json`, any case, parameters
  ignored) is sent
  whole as JSON text, and the engine decodes and bounds it as Dart does.
  Anything else is sent as text, decoded as UTF-8 with U+FFFD replacement
  and cut to whole characters within 4100 bytes
  ([evidence messages](../../../../core/session-engine/docs/evidence-messages.md)
  section 4.5). A JSON body over 64 KiB is therefore `text`, where Dio
  would record a JSON `serialized_prefix`. An empty body gives none.
- Tasks with a completion handler, `async` `data(for:)` called directly,
  and download tasks still record status, timing, and outcome, but no error
  body: URLSession hands their bytes to the caller, never to the session
  delegate. Use `Tugboat.data(for:session:delegate:route:)` to get the body
  for `async` calls. A task-specific delegate (`task.delegate`) that
  implements `didReceive data` or `didCompleteWithError` takes those
  callbacks from the session delegate, so such tasks are recorded from
  metrics only, or not at all.
- The resolver runs once per task, on the delegate queue, with the task's
  `originalRequest`, and only while Tugboat takes evidence (otherwise
  nothing is buffered).
- Not covered: `URLSession.shared` and any session you make yourself,
  unless you call through `Tugboat.data`. Stream and WebSocket tasks are
  not recorded. A background session is observed the same way and never
  altered. Its tasks may finish after a relaunch, before or across a
  Tugboat session; a call that began before the running session started is
  dropped.
- **`Tugboat.data(for:session:delegate:route:)`** wraps
  `session.data(for:delegate:)` and returns or throws exactly what it
  does. The call is timed on the host clock from the helper's start to its
  return, and the error body is read from the returned `Data` by the same
  rule. Your `delegate`, if any, receives exactly the callbacks it would
  receive directly. On an instrumented session the call is recorded once,
  by the helper. Cancelling the Swift task records `cancelled`.
- **`TugboatAlamofire`** (`platforms/apple/TugboatAlamofire`, its own
  SwiftPM package, Alamofire 5.9.0 or later): an Alamofire `EventMonitor`.
  Pass `TugboatAlamofireMonitor(routeResolver:)` in `Session(eventMonitors:)`
  to record one event per logical request, with `attemptCount`. See its
  [README](../../TugboatAlamofire/README.md). It uses the SDK's
  `@_spi(TugboatAdapters)` surface (`Evidence/TugboatAdapters.swift`),
  which is not for app code.

## Accessibility-tree identity (opt-in, ADR 0010)

[ADR 0010](../../../../docs/decisions/0010-swiftui-accessibility-identity.md).
A tap on an untagged SwiftUI `Button` drawn in a hosting view has no UIKit
view, so without a tag it is `no_actionable_candidate`, and a button in a
`List` row resolves to the row. SwiftUI's accessibility tree knows these
controls, but iOS builds it in-process only for an assistive client. With
`TugboatConfig(…, swiftUIAccessibilityIdentity: .on)` (or
`.sampled(rate: 0.05)`) the adapter builds and reads it for those taps.

```swift
TugboatConfig(collector: collector, app: app, swiftUIAccessibilityIdentity: .sampled(rate: 0.05))
```

Prefer `.tugboatTag("checkout")` (optionally `accessibility: true`) on the
controls that matter: it is free, `high` confidence, and survives layout
changes. Turn this on only to learn about untagged screens, and sample it.

**Pros**

- Identity and control type for untagged SwiftUI controls, with no code
  changes: `AXButton#1` with `role: button` instead of
  `no_actionable_candidate`, or `…/Cell#0/AXButton#0` instead of the row.
- App-set `accessibilityIdentifier`s become reachable: an identified element
  is told apart as `AXIdentified#<k>` now, and the identifier becomes an
  alias once a filter for data-derived ids (`row_\(item.id)`) exists.

**Cons** (iPhone 12, iOS 18.6.2, Release build)

- A one-time main-thread stall of about 85–300 ms when the tree is built.
  It runs on the main queue's next turn after the first qualifying tap of a
  process, never between touch down and up; that tap is reported as with the
  option off.
- The cost starts at the first tree read and cannot be turned off for the
  rest of the process: LazyVStack scroll main-thread time +104%, state
  updates +55%, process CPU +31%, memory +5 MB; scrolling in
  TugboatSwiftUISample +27%.
- The app's `@Environment(\.accessibilityEnabled)` becomes true for the
  rest of the process, so UI that adapts to assistive users adapts for
  everyone in it.
- It relies on an undocumented UIKit side effect of the public
  `accessibilityActivate()`, which Apple can change in any release.
- `accessibilityHitTest(_:)` stays nil, so a tap is matched to the smallest
  element whose frame contains it. An element's frame can be smaller than
  the control's tappable area (on the iOS 26.5 simulator a plain `Button`'s
  element is its label's frame), so a tap on the padding keeps today's
  result.
- Pendo documents a lazy-stack hang on iOS 26 with the tree built (Apple
  FB21851974).

**Rules**

- `.off` (the default) never builds or reads the tree, even when VoiceOver
  is running.
- Only iOS 18 is verified (the only OS measured). On any other major the
  option behaves as `.off` and logs once. iOS 17 and 26 are added after a
  device re-measure.
- `.sampled(rate:)` (clamped to 0...1) is drawn once per process launch; a
  process that is not sampled in never reads the tree, in any session.
- The tree is built once per process, lazily, on the first qualifying tap,
  and not at all when VoiceOver or Switch Control already runs (it then
  exists and is read directly).
- Only taps that resolve to `no_actionable_candidate`, or to a list cell or
  scroll view, ask. Tagged taps, text inputs, UIKit controls and
  representables keep exactly today's anchors.
- The descent enters only containers whose frame contains the point, reads
  at most 256 elements (over that, today's result), and reads only
  `accessibilityIdentifier` (whether it is set), `accessibilityTraits` and
  frames. Labels and values are never read or sent; the identifier's value
  is never sent and is not used as a tag or alias.
- Anchors: path segment `AXIdentified#<k>` (no `role`) or `AX<Role>#<k>`
  (`switch`, `button`, `link`, `textField`, `adjustable`, `image`,
  `header`; else `AXElement` with no `role`), `widgetType: SwiftUIView`, no
  `actions` or `enabled`, `low` confidence (`medium` in a list cell). The
  extra segment changes the structural fingerprint of those taps in
  sampled-in processes: treat turning it on as an identity-source change.

## SDK wiring (`Public/`, `Sdk/`, `Capture/`)

| Piece | Where | Role |
| --- | --- | --- |
| Facade | `Public/Tugboat`, `TugboatConfig`, `TugboatLifecycleState` | Thin: main-thread hop, idempotency, user id and traits kept across sessions. |
| Activation | `Sdk/Activation` | `ActivationState` (Flutter's `TugboatLifecycleNotifier`: state, activation id, `deactivate` override, request epoch; changed on the calling thread under a lock) and `ActivationDriver` (Flutter's activation gate, main thread: starts a session when one is wanted and none runs for the current request, ends it through the runtime's `stop` otherwise). The `deactivate` evidence fence runs under the same lock as the driver's channel open, so a session started for an older request never takes evidence. |
| Evidence | `Evidence/` | `TugboatEventHook`, `TugboatNetworkCall` and `TugboatParameterPolicy`; `EvidenceChannel` admits them into the open session (opened by `start`, closed by `stop`), stamps the time on the calling thread, and hops to the main thread; `EvidenceMessages` builds `evidence.externalEvent` / `evidence.networkCall`; `HostParameters` runs a `transform`; `EvidenceEncoder` and `ValueKind` write the values in the engine's value encoding. |
| Network | `Network/`, `Evidence/HTTPErrorBody`, `Evidence/TugboatAdapters`, `Public/Tugboat+URLSession` | `Tugboat.instrumentedSession` and `Tugboat.data(for:...)`; `DelegateForwarder` (the Objective-C forwarding proxy), `InstrumentedSessionDelegate`, `NetworkTaskRecorder` (one event per task, timing from metrics, per-task state on the task); `HTTPErrorBody` (the byte-reading error-body rule, `JSONTextBody`); `TugboatAdapters` (SPI for `TugboatAlamofire`, and an evidence tap for its tests). |
| Composition root | `Sdk/TugboatRuntime`, `RuntimeParts` | Builds and owns one engine host, the SwiftUI adapter, the capture coordinator, the surface observer, and the lifecycle bridge. Closures reach the host weakly. |
| Configuration | `Sdk/HostMetadata`, `DeviceSnapshot`, `EngineConfiguration`, `SessionMessages` | `engine.configure`: `host` with every `session_start` field the collector requires (device id `identifierForVendor`, `platform: ios`, screen size in points, `scale` as both densities, dpi `scale × 160`, `ipInfo.ip` placeholder `127.0.0.1` as Flutter on iOS, configured locale with timezone), the Dart `limits`, `gesture` = `GestureConfig.uiKitDefault`, `capture.answerTimeoutMs` 5000, `collector.enabled`, `focusChanges` and `captureDiagnostics` (no `systemInput`: iOS has no system input facts yet). `session.start` with the key window's viewport, the active locale, and `activationRequestId` / `explorationRunId` when non-blank. |
| Lifecycle | `Sdk/AppLifecycleBridge` | Application notifications to `app.lifecycle`: active `resumed`, resign `inactive`, background `paused`, will-enter-foreground `inactive`, terminate `detached`. |
| Locale | `Sdk/LocaleBridge` | `NSLocale.currentLocaleDidChangeNotification` to `locale.set` (the `session.start.locale` object), skipping a locale equal to the last one sent; added at session start, removed at session end. |
| Stop | `Sdk/StopSequence`, `SessionEndWatcher` | `session.end` → wait for the `session_end` post (one `tugboat-stop` thread, latch with a 25 s deadline, as on Android; skipped when none will be posted) → `engine.dispose` → destroy. The watcher's callback holds only the latch and is dropped after the wait or on `close`, so a post that never settles keeps nothing alive. The watcher repeats the engine's retry rule; a test pins it to `transport.cpp` and the `delivery-status-classification` fixture. |
| Captures | `Capture/CaptureCoordinator`, `RuntimeOutcomes`, `FrameMasks`, `WindowCapturer` | `capture.request` → main thread → the key window (waits up to 3 s for one; nothing about its size is read here) → `TugboatCaptureRuntime` (`viewHierarchy`, the whole `UIWindow`, so sheets and alerts are in the frame). The mask supplier runs inside the runtime's main-thread draw turn, after layout and immediately before each draw. That one reading of the window gives the masks (`WindowMasks`), the structure signature, the boundary (posted as `surface` when it changed, before the result), and the pixel size (`pixelsPerPoint` = 0.75 × the engine `scale`, Flutter's `capturePixelRatio`). Each draw is recorded under its snapshot id, so the result reports the coverage and boundary of the draw the frame came from. JPEG bytes go to `FrameHandleTable`. Every request is answered exactly once by id, in any order (C16); every runtime status maps explicitly. |
| Structure | `Capture/StructureSignature`, `StructureProbe` | FNV-1a over the drawn size, the mask rectangles, visible control state (`UIControl` selected / highlighted / enabled, `UISwitch` on, the accessibility `selected` trait), and the current `.tugboatScreen` name; never text. |
| Wire | `Capture/CaptureAnswer`, `CaptureResultJSON` | `capture.result` with `requestedBackend` / `resolvedBackend` `nativeCpuExperimental`, the drawn boundary, timings, and `frame.maskCoverage {mode, reasons}` on every captured frame (the adapter's `MaskCoverage`, each reason under its own name). |
| Surface | `Capture/SurfaceReporter`, `SurfaceObserver`, `CaptureGeometry` | `surface {boundaryRect, generation}` in window points. Between captures: key-value observation of the key window's `frame` and `bounds` (split view, Stage Manager, rotation) plus key-window, activation and orientation checks; at every capture: the drawn size. |

## Engine host (`Engine/`, `Host/`, `HTTP/`)

| Piece | Where | Role |
| --- | --- | --- |
| Bridge | `Engine/EngineBridge` | Owns one `tb_session_engine` handle and calls the C ABI directly (no Objective-C++). `submit` copies the engine-owned response into `Data` before returning. Statuses are the imported `tb_session_status` constants. |
| Host | `Host/EngineHost` | Owns the bridge and one serial `DispatchQueue` (`tugboat.engine`). See the threading notes below. |
| Messages | `Host/EngineMessage`, `HostMessages` | Envelopes built by concatenation around the caller's `input` JSON, which is never parsed or re-encoded. |
| Clock | `Host/HostClock` | `monoUs` from `ProcessInfo.systemUptime` (the clock of `UIEvent.timestamp`), `wallUs` from `Date()`. |
| Effects | `Host/Effect`, `EffectParser`, `EffectDispatcher`, `CaptureRequestEffect` | Each response is decoded once (`JSONSerialization`) into typed effects, run in order. `capture.request` goes to the `CaptureRequestSink` (the capture coordinator). Types the host does not execute are logged once per type. |
| Timers | `Host/TimerExecutor` | One `DispatchSourceTimer` per id on the engine queue, armed for the time left until `atMonoUs` (saturating, so any `atMonoUs` is safe). Rescheduling replaces. A fire is stamped no earlier than its `atMonoUs`, or the engine would ignore it as stale. |
| Frames | `Host/FrameHandleTable` | Thread-safe store of JPEG bytes behind never-reused opaque handles. |
| HTTP | `HTTP/HTTPExecutor`, `HTTPSessionDelegate`, `CollectorResponse`, `MultipartBody` | Ephemeral `URLSession` with its delegate queue on `tugboat.io`. Same collector headers and multipart bytes as the Android host and the Flutter `CollectorHttpSink`. `jsonBody` is sent byte for byte. `timeoutMs` is a total deadline (watchdog), redirects are reported and not followed. Every answer is one the engine accepts: the body is cut to at most 64 KiB at a UTF-8 boundary, and a status outside 100–599 becomes `error`. |

## SwiftUI adapter (`SwiftUI/`)

Internal (`SwiftUIAdapter`), main thread only. It produces the facts of
stateful-engine.md sections 8.1 and 9.1 and batches them once per frame
(`CADisplayLink`) into `EngineHost.postBatch`, each with its own time. Rules
are in native SDK note sections 2.1, 5 and 6.3, and in
[capture-and-fingerprint.md](../../../../docs/design/capture-and-fingerprint.md)
(SwiftUI canonicalization).

| Piece | Where | Role |
| --- | --- | --- |
| Facts | `Facts/` | `FactBatcher` (frame hooks, one `batch` per frame), `DisplayLinkFrames`, `FactClock` (`UITouch.timestamp` is `systemUptime`, the host clock), a small ordered JSON writer. |
| Pointer | `Input/WindowPointerRecognizer`, `PointerFactBuilder` | A recognizer on each window that becomes key: never cancels or delays touches, never prevents or is prevented, recognizes simultaneously, no swizzling. `input.pointer` in window points, a unique `pointerId` per contact, tap evidence on `up` under `touchSlop` resolved at the down position. |
| Identity | `Identity/` | `ViewTree` / `ViewKind` classify every view once per walk. `.tugboatTag` markers (`TagMarkerView`, matched within the hit window and hosting root) first, then UIKit hit-testing (text inputs, list cells with index paths, scroll views, representable hosts), then, opt-in, the accessibility tree (`AccessibilityIdentity/`: `AccessibilityIdentitySource` gate and activation, `AccessibilityTreeReader` descent, ADR 0010); route key from `.tugboatScreen`, else the hashed hosting-controller type; `toolkit: "swiftui"`. `IdentityHash` matches every `conformance/fingerprint/identity_parts` vector. |
| Scroll | `Scroll/` | KVO on `contentOffset` of the window's scroll views; `start` (with the anchor), one `update` per frame, one `overscroll` per scroll, `end` when no finger or momentum drives it and it has been still for 100 ms. |
| Navigation | `Navigation/`, `Modifiers/TugboatScreen`, `Modifiers/TugboatNavigator` | `.tugboatScreen` appear and disappear on the navigator its environment names: `swiftui-screens`, or `swiftui-screens/<name>` inside `.tugboatNavigator(name)` (`NavigatorScope`), whose facts carry `parentNavigatorId` (the enclosing navigator) on transitions and seeds. `presentation:` sets `route.overlayKind` (`.automatic` is `page`; nothing is read from UIKit yet); a sheet's screen without its own navigator is a route on the presenting navigator, so the engine records it as presented over the screen below, and its dismissal is a `pop`. `NavigatorTree` decides what a callback means from per-entry on-screen state (on from `onAppear` to `onDisappear`), assuming a real pop delivers the revealed screen's `onAppear` in the same frame: only appearances are activity; on a nested navigator a top screen disappearing is a `pop` only when the revealed screen is on screen, nothing when the navigator is covered (a covered host route, or a sibling navigator with a screen on screen: a tab switch), and otherwise a teardown (a stacked sheet dismissed from any depth: no fact, the navigator is forgotten). A sibling covers a navigator only when its on-screen top appeared more recently. A navigator forgotten and used again gets an engine id not yet issued in the session (`<key>`, `<key>#2`, …; navigators live at `start()` keep theirs), so the engine starts a fresh stack. The root navigator's pops are unchanged. A nested navigator is forgotten, with no fact, when the screen hosting it leaves its parent's stack or its own stack empties. The route key is the visible chain's top (`ScreenTracker.visibleTop`, computed at the end of each settle): through the child, hosted by the top screen or with no host, that has a screen on screen, the most recently appeared where several do. Optional hosting-controller appearance (one-time method exchange, opt-out) on `swiftui-hosting`, always `page`, until a screen is seen. On each adapter `start()` (including after `stop()`), queued callbacks are settled without recording, then one `navigation` `session_start` per navigator with a non-empty stack is seeded from the retained stacks (`routes` bottom to top; navigators hosted by covered screens first, in stack order, the visible chain last); live facts follow only after recording resumes. Screen and hosting stacks survive stop/start. |
| Focus | `Input/FocusObserver` | `text_input` / `none` from `UITextField` / `UITextView` editing notifications. |
| Masks | `Mask/` | `masks(for:)`: one view walk plus each view's layers (`LayerWalk`). UIKit text and images; boxes for web views, opaque renderers, app representables and unverified SwiftUI platform views (a SwiftUI host is walked only when the type it wraps is declared in `SwiftUI` and verified for the iOS major: `List`, `TextField`, `NavigationStack`, `NavigationView`, `TabView` on iOS 26); a box over 90% of the window makes the frame `wholeFrame`; allowlisted SwiftUI text, image and shape layers per iOS major (`LayerAllowlist`, `KnownPlatformViews`; iOS 26 verified). Unclassified layers are masked. The whole frame is masked on an unverified major with SwiftUI, during any animation, and over the walk's limits. `MaskResult.coverage` summarizes each frame: `precise` or `wholeFrame`, with closed reasons for the host to report. |

Known gaps: no system input facts (none in this milestone); application
lifecycle only (not per scene); no background task keeps delivery running
after the app is suspended (pending events go out on the next foreground).

`EngineHost` threading and failure rules:

- `post(type:inputJSON:at:frameHandles:)` and `postBatch(_:)` can be called
  from any thread. Callers pass the time the fact happened.
  `postUntimed(type:inputJSON:)` is for `engine.configure`, queries, and
  stateless messages.
- Submits, responses, and effects run serialized on the engine queue, in post
  order. Transport results and timer fires come back as messages on it.
- A non-`ok` status is logged. The message is dropped and its frame handles
  are released.
- Shutting down (`close`, or three `internal_error`s in a row) first submits
  `engine.dispose` so the engine can report undelivered work; from its
  response `frame.release` runs but no `http.send`, `timer.schedule`, or
  `capture.request` starts.
  Then timers are cancelled, IO closed, the handle destroyed, and frames
  freed. Posts after that (or after `close`)
  release their frame handles.
- Nothing force-unwraps external data, and no engine or collector value can
  reach a trapping operation: integer conversions and deadlines saturate.

## Build and test

Requires Xcode. From the repository root on a Mac:

```sh
swift build --target Tugboat
xcodebuild test -scheme TugboatCaptureRuntime-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:TugboatTests
```

`TugboatTests` runs the collector contract test (`Sdk/CollectorContractTests`:
the real engine through the host with the SDK's own `engine.configure`,
`session.start` and `capture.result`, pinning the `session_start` body and
`frameMetadata` backends `nativeCpuExperimental`), the capture coordinator
with overlapping requests answered out of order, the bridge against the real
engine (the `fingerprint.labelHash` conformance fixture), the host with a
fake engine and transport, real timers, the multipart golden bytes shared with the Android
host (`conformance/host/multipart-request.golden`), and the HTTP executor against a `URLProtocol` stub.
`TugboatTests/Evidence` tests the evidence API: token idempotency under
concurrent completes, no-op paths, the transform contract, the value
encoding (types, key order, depth, cycles, elision), and the recorded
`external_event` / `network_call` data from the real engine.
`TugboatTests/Network` runs instrumented sessions over a test-only
`URLProtocol` stub: 200, a 404 JSON body, a 500 text body, a JSON body over
64 KiB, timeout, cancel, redirect, an auth challenge forwarded to the app's
delegate (its disposition returned unchanged), completion-handler tasks, the
`async` helper, and resolver and admission no-ops. It checks that no query,
header, or request body reaches the message, and that the app's delegate
gets the same callbacks and bytes as without instrumentation.
`EvidenceConformanceTests` also runs every `jsonText` and text-body fixture
through the byte path (`HTTPErrorBody`) against the real engine.
`TugboatTests/SwiftUI` tests the adapter on hosted SwiftUI views in a test
window, including the layer-allowlist regression guard, which fails when a
screen with text and an image shows no allowlisted layer class on a verified
iOS major.

`TugboatTests/SwiftUI/Accessibility*Tests` check the ADR 0010 descent,
anchors and policy against scripted accessibility trees, and that tagged and
UIKit taps are byte-identical with the option on. The separate
`TugboatAccessibilityActivationTests` bundle activates a real hosting view
with no assistive client attached (the built tree lasts for the process, so
it never runs inside `TugboatTests`).

The `accessibility` option of `.tugboatTag` is checked in the real
accessibility tree by the SwiftUI sample's XCUITests
(`tool/ci/test-apple-sample-ui.sh`: XcodeGen, then `xcodebuild test` of
`TugboatSwiftUISampleUITests` on a simulator).
