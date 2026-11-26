# Tugboat for Flutter

See what your app showed before and after a user interaction. Tugboat captures
masked screenshots, gestures, scrolling, and navigation alongside structural
anchors for the Flutter widgets involved. Use the same SDK to capture app
sessions or collect evidence during automated exploration.

Tugboat supports Android and iOS. It requires Flutter 3.35.0 or newer,
Dart 3.9.2 or newer, and iOS 15 or newer for iOS builds.

## Quick start

**Already using session replay?** Run one recorder per session. When
switching to Tugboat, remove the previous replay integration or disable its
replay feature before enabling Tugboat. If you keep both during a rollout,
use one feature flag to select the recorder for each session. Two active
recorders can duplicate capture work, increasing CPU and memory use and
making scrolling or animations less smooth.

From your app directory, install the [tugboat package](https://pub.dev/packages/tugboat):

```sh
flutter pub add tugboat
```

Import `package:tugboat/tugboat.dart` and add two hooks to your existing
`MaterialApp` or `CupertinoApp`:

```dart
import 'package:flutter/material.dart';
import 'package:tugboat/tugboat.dart';

// Add these settings to the app you already use.
MaterialApp(
  navigatorObservers: [TugboatReplay.navigatorObserver],
  builder: (context, child) => TugboatReplay.wrapApp(
    child: child!,
    config: const TugboatReplayConfig(enabled: true),
  ),
  home: const HomeScreen(),
);
```

Keep your existing observers and builder behavior. The wrapper installs the
capture boundary and input listeners. The observer supplies navigation events
and route context for anchors. For a Router-based app, attach the observer to
the router's Navigator. Add a separate observer from
`TugboatReplay.createNavigatorObserver()` to each nested Navigator you want to
track.

Run the app on Android or iOS, tap a control, open a second screen, and wait
for the transition to settle. In the debugger, check
`TugboatReplay.controller?.session` for `interaction` and `route_change`
events and masked frames. See `TugboatReplay.health` for
sanitized capture outcomes, screenshot budget, and sink counts. This setup
keeps a bounded session in memory. Add a collector to send evidence off the
device.

## Send sessions to a collector

After `WidgetsFlutterBinding.ensureInitialized()` and before `runApp`, load
the app and device metadata and build the config. Pass `config` to the
`wrapApp` call above.

```dart
final collector = await TugboatCollectorHost.fromPlatform(
  apiKey: collectorToken,
);

final config = TugboatReplayConfig(
  enabled: true,
  collector: collector,
);
```

Supply your app's client-visible collector token through your existing
configuration. `fromPlatform` uses the Tugboat production collector by
default. For local exploration, pass `productionProfile: false` or supply an
explicit `baseUrl` reachable from the device. Delivery is best effort with
bounded in-memory queues. Pending data is lost when the process exits.
[Collector setup and wire behavior](https://github.com/blendto/tugboat-flutter/blob/main/docs/integration/collector.md)

For an end-to-end check, confirm the collector accepts `session_start`, then
look for event and frame uploads. In a debug build, use
`--dart-define=TUGBOAT_HTTP_PROOF=true` for redacted HTTP proof logs. The SDK's
`captureSessionId` identifies the emitted session. The collector can assign a
separate `collectorSessionId` when it accepts `session_start`.

## Control when capture runs

Capture is off by default. Set `enabled: true` for startup capture, or leave
it off and activate the mounted wrapper from your host's own consent or
feature-flag flow. The activation request ID correlates the host's request
with the SDK lifecycle.

```dart
TugboatReplay.activate(activationRequestId: captureRequestId);
// When capture should end:
TugboatReplay.deactivate();
```

The mounted wrapper handles these transitions without rebuilding
`MaterialApp`. Setting `TugboatReplay.disabled = true` is a process-wide kill
switch that tears down active capture. A session starts once the capture
boundary has a non-zero viewport. Pausing or hiding the app schedules a sink
flush, and detaching the app ends the session.

To associate a user with collector sessions, call
`TugboatReplay.setUserId(currentUserId)` and send a full traits snapshot with
`TugboatReplay.setTraits({'plan': 'pro'})`. Values set before activation can
be included at session start. [Collector identity and lifecycle](https://github.com/blendto/tugboat-flutter/blob/main/docs/integration/collector.md)

## Protect captured data

The default screenshot policy, `allTextAndMedia`, masks text and media
before JPEG encoding. Use `TugboatSensitive` around a widget that must always
be hidden.

```dart
TugboatSensitive(
  child: Text(accountNumber),
)
```

Verify masking and coverage in the target app, especially for custom-painted
widgets, textures, platform views, and overlays. The supported default is
Flutter `RepaintBoundary` capture. Native CPU capture is experimental and
requires app-specific coverage and privacy validation.
[Privacy pipeline](https://github.com/blendto/tugboat-flutter/blob/main/docs/privacy/pipeline.md) ·
[Experimental native CPU capture](https://github.com/blendto/tugboat-flutter/blob/main/docs/integration/native-cpu-experimental.md)

Target identity uses structural paths. Developer-authored route names, tag
IDs, subview labels, and widget names can appear in evidence, so use stable
values without personal data. The SDK also records the active app locale
as evidence. It observes `Localizations` when installed in the app builder.
If you mount it above `Localizations`, use `TugboatReplay.setLocale` to
report the app locale. [Capture and fingerprint contract](https://github.com/blendto/tugboat-flutter/blob/main/docs/design/capture-and-fingerprint.md)

## Make targets and routes easier to identify

### Start with Flutter semantics

Use Flutter’s built-in controls where they fit. An `IconButton` with a
localized `tooltip`, for example, already exposes a named button to screen
readers. With capture enabled, Tugboat’s default `tapResolutionOnly` mode
automatically uses available semantic roles, actions, and on-screen bounds
to help identify what was tapped. This works locally; emitting viewport
semantic maps is a separate opt-in.

For a custom control, use Flutter’s `Semantics` widget to describe what the
user can do. This cart control exposes one button named by `cartLabel`
(the localized “Open cart” string). Screen-reader activation and a physical
tap both call `openCart`.

```dart
Semantics(
  label: cartLabel,
  button: true,
  enabled: true,
  onTap: openCart,
  excludeSemantics: true,
  child: InkWell(
    onTap: openCart,
    child: const SizedBox.square(
      dimension: 48,
      child: Icon(Icons.shopping_cart_outlined),
    ),
  ),
)
```

For a row with an on/off setting, `SwitchListTile` makes the label and switch
one accessible control. The same callback handles a tap on the row and a
screen-reader action. Pass `null` to `onChanged` when the setting is disabled.

```dart
SwitchListTile(
  title: Text(deliveryUpdatesLabel),
  value: deliveryUpdatesEnabled,
  onChanged: canEdit ? setDeliveryUpdates : null,
)
```

If automation still needs a specific target alias, wrap the accessible
control in `TugboatTag('cart-open', child: cartButton)`. The tag adds an
explicit ID to the captured target. Keep the spoken label meaningful and
localized; viewport semantic maps omit raw labels, values, and hints.

### Name pages pushed with Navigator

You can keep using `Navigator.push` and pass data directly to the page.
Give the route a stable name in `MaterialPageRoute.settings`. An observer on
this Navigator can then record `/orders/detail` for every order, while
`orderId` stays out of the route name.

```dart
Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    settings: const RouteSettings(name: '/orders/detail'),
    builder: (_) => OrderDetailsPage(orderId: orderId),
  ),
);
```

### Name dialogs and bottom sheets at the call site

Pass `routeSettings` to the function that presents the overlay. These names
let a reader or agent distinguish the cancellation prompt from the
payment picker in `route_change` events, even when the UI is translated.

```dart
Future<bool?> confirmCancellation(BuildContext context) {
  return showDialog<bool>(
    context: context,
    routeSettings: const RouteSettings(name: '/orders/confirm-cancel'),
    builder: (_) => const CancelOrderDialog(),
  );
}

Future<String?> choosePaymentMethod(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    routeSettings: const RouteSettings(name: '/checkout/payment-method'),
    builder: (_) => const PaymentMethodSheet(),
  );
}
```

Observe the Navigator that presents the overlay. This matters in tabbed
apps: `showDialog` uses the root Navigator by default, while
`showModalBottomSheet` uses the nearest one. Give each observed nested
Navigator its own `TugboatReplay.createNavigatorObserver()`.

For a tab or wizard step that changes inside a single route, wrap its content
in `TugboatSubView(label: 'checkout-payment', child: paymentForm)` to identify
the section. To verify the wiring, open the sheet and inspect the session's
`route_change` event for `route: /checkout/payment-method` and
`routeNamed: true`.

Session JSON uses schema version `10` and structural fingerprints use
version `7`. Scope fingerprints by app build and schema version. A later
frame shows what was visible after an interaction. Use explicit event
attribution when linking it to a route change, especially for rapid modal
chains and automatic redirects. [Event and fingerprint details](https://github.com/blendto/tugboat-flutter/blob/main/docs/design/capture-and-fingerprint.md)

## Enable optional evidence

Enable capabilities individually in `TugboatReplayConfig`.

| To capture | Configure |
| --- | --- |
| Actionable controls and images for exploration | `emitSceneInventory: true` |
| A bounded viewport semantic map | `emitViewportSemanticMap: true`, `viewportSemanticMode: TugboatViewportSemanticMode.full` |
| External action context | `acceptActionContext: true` |
| Capture diagnostics as session events | `emitCaptureDiagnostics: true`. Health counters are available by default. |
| Text-field focus, system input, or tap press duration | `captureFocusChanges`, `captureSystemInput`, or `capturePressDuration` |
| Scroll samples or in-motion screenshots | `captureScrollSamples` or `captureScrollScreenshots` |

### Device Farm launch options

After initializing Flutter bindings, call
`await baseConfig.withDeviceFarmOverrides()` before wrapping your app. The
helper reads the following launch inputs via `TugboatLaunchOptions.fromPlatform()`.
Either evidence flag starts capture for the launch.

| Android Intent extra | iOS environment | iOS launch argument |
| --- | --- | --- |
| `tugboat_emit_scene_inventory` | `TUGBOAT_EMIT_SCENE_INVENTORY` | `--tugboat-emit-scene-inventory[=value]` |
| `tugboat_accept_action_context` | `TUGBOAT_ACCEPT_ACTION_CONTEXT` | `--tugboat-accept-action-context[=value]` |
| `tugboat_collector_base_url` | `TUGBOAT_COLLECTOR_BASE_URL` | `--tugboat-collector-base-url=<url>` |
| `tugboat_automation_run_id` | `TUGBOAT_AUTOMATION_RUN_ID` | `--tugboat-automation-run-id=<id>` |

On iOS, a bare evidence flag means true and the environment takes precedence.
Collector URL overrides apply to an existing collector config in non-release
builds and accept local HTTP endpoints. Use a non-secret run ID for log
correlation.

### App events and network observations

Add host events through `eventHook` and observe selected network calls
through `beginNetworkCall` or the matching version of the
[tugboat_dio adapter](https://pub.dev/packages/tugboat_dio).

```dart
final events = TugboatReplay.eventHook(
  source: 'analytics',
  parameterPolicy: TugboatParameterPolicy.allowList({'method'}),
);
events.record('LOGIN', parameters: {'method': 'email'});

final call = TugboatReplay.beginNetworkCall(
  method: 'POST',
  route: '/projects',
);
call.complete(statusCode: 422, errorResponseBody: {'code': 'invalid_project'});
```

App event parameters default to `allowAll` for bounded JSON-safe values. Use
`namesOnly` for keys only, or an allow-list or transform to select values.
Network routes must be bounded absolute paths. Prefer host-owned route
templates because dynamic path segments can expose user or tenant IDs.
Network observations can retain up to 4 KiB of JSON or text error-body
evidence for HTTP status `>= 400`. Omit `errorResponseBody` to capture only
network metadata. The Dio adapter provides URL-based controls for body
retention. Both APIs append to the active session's evidence stream. Calls
with no active session are safe no-ops, and an in-flight token cannot append
to a later session.

### Record requests from an existing Dio client

If your app uses Dio, run `flutter pub add tugboat_dio`. Install the
interceptor on the client that makes your requests, after auth, retry, and
cache interceptors. This example records calls to `/orders` and keeps
metadata only. Leave those requests out of manual `beginNetworkCall`
instrumentation so each call produces one observation.

```dart
import 'package:dio/dio.dart';
import 'package:tugboat_dio/tugboat_dio.dart';

void configureNetworkEvidence(Dio dio) {
  TugboatDioInterceptor.install(
    dio,
    routeResolver: (request) => request.path == '/orders' ? '/orders' : null,
    errorBodyUrls: const [],
  );
}
```

During an active session, call `dio.get('/orders')` and look for a
`network_call` event with route `/orders`. Omitting `errorBodyUrls` allows
bounded JSON or text error bodies by default. See the
[Dio adapter guide](https://pub.dev/packages/tugboat_dio) for URL filters,
retries, and cache behavior.

## Reference

- [Dart API](https://pub.dev/documentation/tugboat/latest/tugboat/) for
  configuration defaults, session models, health, markers, and sink factories.
- [Example app](https://github.com/blendto/tugboat-flutter/tree/main/sdks/flutter/packages/tugboat/example)
  for a Flutter app with the wrapper and observer installed.
- [Capture and fingerprint architecture](https://github.com/blendto/tugboat-flutter/blob/main/docs/design/capture-and-fingerprint.md)
  for gesture classification, route attribution, semantic modes, and frame reuse.
- [Changelog](https://pub.dev/packages/tugboat/changelog) and
  [release notes and compatibility](https://github.com/blendto/tugboat-flutter/tree/main/docs/releases)
  for version-specific changes.
