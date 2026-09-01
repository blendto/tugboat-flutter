# Collector integration

This page documents the transport behavior implemented by the Flutter SDK.
Server-side storage, enrichment, and Atlas behavior are outside this repository
and must be verified against the service that receives these requests.

The SDK can enable either or both built-in destinations:

- a local exploration WebSocket;
- a standalone HTTP collector.

Evidence remains authoritative in the controller's bounded, in-memory session.
Transport failures are isolated from the host app.

## Required app integration

Install the wrapper and navigator observer. Capture is dormant by default, so
select an active profile for startup capture:

```dart
MaterialApp(
  navigatorObservers: [TugboatReplay.navigatorObserver],
  builder: (context, child) => TugboatReplay.wrapApp(
    child: child!,
    config: config,
  ),
);
```

Without the observer, pointer and scroll evidence still works but route-change
events and route-backed anchors are incomplete. Without the wrapper no capture
controller or transport is installed.

Screenshot JPEG frames are schema-v10 `frame` records regardless of
`TugboatScreenshotCaptureBackend`. Switching to `nativeCpuExperimental` does
not change collector URLs, event names, or the frame transport schema. Keep
the default `flutterRepaintBoundary` backend for production collector cohorts.

## Local exploration WebSocket

Use the exploration destination for an interactive local run:

```dart
const config = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  explorationCollectorUrl: 'ws://127.0.0.1:7832/sdk',
  explorationRunId: 'optional-run-id',
  appInfo: TugboatCollectorAppInfo(
    name: 'My App',
    version: '1.0.0',
    buildNumber: '42',
    installationId: 'device-installation-id',
    appId: 'com.example.my_app',
  ),
);
```

For an Android emulator the host-side runner must make the socket reachable,
for example with `adb reverse tcp:7832 tcp:7832` when using
`127.0.0.1:7832`. Connection setup is not performed by the Flutter package.

If `appInfo` is omitted, session metadata falls back to
`collector.appInfo` when the HTTP destination is also configured.

### WebSocket messages

The SDK sends:

- `type: session`: session metadata, platform, exploration run ID when set, and
  `fingerprintSchemaVersion`, plus the active app locale when available;
- `type: event`: serialized event payload plus available session/run/action
  correlation fields;
- `type: frame`: frame metadata (`captureMicros`, `byteLength`,
  `requestedBackend`, `resolvedBackend`, optional `fallbackReason`) followed by
  a binary JPEG message;
- `type: control_ack`: acknowledgement for supported exploration commands.

The optional `locale` object contains `language`, optional `country` and
`script`, and a BCP 47 `tag`. Every SDK event carries the current locale when
known. A `locale_changed` evidence event contains `previousLocale` when known
and the new `locale` in its payload.

Incoming JSON control messages are forwarded to the controller. The current
controller understands `set_action_window`, `clear_action_window`,
`pause_capture`, and `resume_capture`, and acknowledges recognized commands.
Malformed or unknown messages are ignored.

The transport reconnects after two seconds. Messages produced while
disconnected are queued in memory, with a maximum of 200 messages; the oldest
message is dropped when the bound is exceeded. The queue is not persisted.

### Exploration screenshot suppression

When the WebSocket connects and no HTTP collector is configured, the controller
suppresses non-interaction Flutter screenshot capture to reduce UI-thread work.
Each completed interaction still captures and encodes a fresh screenshot. A
route capture claimed by that interaction also bypasses this suppression.
Events, anchors, scene inventories, and enabled viewport semantic evidence
continue to stream. Frames captured before the socket connects can still be
sent.

The external exploration runner may record its own before/after screenshots,
but that behavior is not implemented or guaranteed by this Flutter package.

## HTTP collector

For the lowest-friction host metadata setup:

```dart
final collector = await TugboatCollectorHost.fromPlatform(
  apiKey: apiKey,
  baseUrl: TugboatCollectorDefaults.productionBaseUrl,
  productionProfile: true,
  userId: currentUserId,
);

final config = TugboatReplayConfig(
  profile: TugboatCaptureProfile.productionLean,
  collector: collector,
);
```

`fromPlatform` uses `package_info_plus`, `device_info_plus`, `battery_plus`,
`disk_space_plus`, and `connectivity_plus` to populate app, device, viewport,
platform locale, and time-zone fields. The active Flutter app locale overrides
the platform locale in `session_start` when the capture root can observe it.
On `session_start`, the `device` bag may also
include optional runtime facts when observable:

- `batteryPercent` — battery level at session start (0–100);
- `storageFreeMb` — free internal storage in megabytes;
- `ramMb` — physical RAM in megabytes on Android;
- `networkType` — `wifi`, `cellular`, `ethernet`, `vpn`, `none`, or `other`.

Each optional field is omitted independently when the platform cannot observe
it. This is connection type only; HTTP request evidence remains separate via
`TugboatReplay.beginNetworkCall`.

With no explicit `baseUrl`, `fromPlatform` uses:

- `https://collector.gettugboat.com` for a production profile;
- `http://10.0.2.2:3000` for a local Android collector;
- `http://127.0.0.1:3000` for other local platforms.

The derived IP field is only a reachability placeholder (`10.0.2.2` or
`127.0.0.1`); it is not public-IP discovery.

### Manual HTTP configuration

Build `TugboatCollectorConfig` directly when the host owns metadata:

```dart
final collector = TugboatCollectorConfig(
  baseUrl: 'https://collector.example.com',
  apiKey: 'client-visible-token',
  userId: currentUserId,
  appInfo: const TugboatCollectorAppInfo(
    name: 'My App',
    version: '1.0.0',
    buildNumber: '42',
    installationId: 'installation-id',
    appId: 'com.example.my_app',
  ),
  deviceInfo: const TugboatCollectorDeviceInfo(
    id: 'device-id',
    platform: 'ios',
    screenSize: TugboatCollectorScreenSize(width: 390, height: 844),
    screenDensity: 3,
    screenDpi: 480,
    screenPixelDensity: 3,
  ),
  ipInfo: const TugboatCollectorIpInfo(ip: '127.0.0.1'),
  locale: const TugboatCollectorLocaleInfo(
    language: 'en',
    country: 'US',
    timezone: 'America/New_York',
  ),
);
```

`appId` is the native package or bundle identifier. The serialized app metadata
currently includes the same value under both `appId` and legacy
`packageName` keys for consumer compatibility.

### HTTP request contract

The SDK calls:

| Request | Purpose |
| --- | --- |
| `POST /v1/sessions` | Session lifecycle and identity: `session_start`, `session_identify`, `session_end`, `traits_updated`, `user_changed` |
| `POST /v1/events/batch` | JSON event batches |
| `POST /v1/frames` | multipart JPEG frame upload |

Every request includes both `X-PMKit-API-Key` and `X-Tugboat-API-Key`, plus
platform, build number, version name, and app ID headers. Mobile API keys are
client-visible; use the narrowest possible scope and assume a determined user
can extract them from the app or process.

The start lifecycle request uses the SDK's local session ID. The sink waits for
an accepted start response and reads its `sessionId`; events, frames, and the
end lifecycle request then use that collector-issued ID. Events and frames are
not uploaded before this handshake completes.

Session payloads may include:

- `traits` — full traits snapshot when the host has set a bag (`session_start`,
  `session_identify`, `traits_updated`, `user_changed`); the collector stores
  the bag as-is (no server-side partial merge);
- `traitsId` — pass-through of a prior collector-issued id when no new bag is
  sent (for example `session_end`, or `session_start` after only an id is
  cached). Ignored by the collector when `traits` is present.

Accepted session responses (`202`) may return `traitsId`. The SDK caches that
value in process memory and stamps it onto subsequent event batches. Host apps
register traits with `TugboatReplay.setTraits` and change the runtime user with
`TugboatReplay.setUserId`. While `session_start` is still pending, both APIs
update in-memory identity only (folded into start at send time). After start,
changes within 3s coalesce into one lifecycle POST: `session_identify` when
both user and traits change, otherwise `user_changed` or `traits_updated`.
Debounced updates are flushed before `session_end`. The SDK does **not** call
`/v1/identify` or `/v1/events/identify`.

Event payloads contain:

- event ID, type, `atMs`, and absolute UTC `triggeredAt`;
- optional user/session/run/action IDs;
- optional `traitsId` (pass-through only; does not upsert the traits dictionary);
- optional before/after frame references, related-event ID, and result;
- serialized target anchors, when captured;
- event-specific data under `payload`, except for schema-v2 `interaction` and
  `route_change`, which are flat facts-only records at the top level
  (`interactionSchema` or `routeChangeSchema` == `2`). `interaction` carries
  gesture facts under nested `payload` (omitted for `cancelled`);
- build identity: app ID, platform, version name, build number, and fingerprint
  schema version.

The collector must accept all SDK schema-v2 gesture names: `tap`, `swipe`,
`scroll`, `pan`, `zoom_in`, `zoom_out`, and `cancelled`. The mapper preserves
these names. It does not rename zoom to swipe or scroll.
Pan and zoom can carry `pointerCount` in the nested `payload`. Zoom can also
carry `scale`, a positive contact-span ratio. This is not a measured canvas
or layer transform. A multi-contact swipe can carry `pointerCount` too.

Collector versions that accept only the older four gesture names reject a
mixed batch containing pan or zoom with HTTP `400`. The SDK drops that batch
without retrying, including other events in the batch. Frame uploads remain
separate, so visible frame changes do not prove event acceptance. Deploy
collector contract support before testing a production session with these
gestures. Check both zoom directions and the stored `pointerCount` and `scale`.

For schema-v2 interactions, `afterFrame` is a temporal visual observation. It
does not assert that the interaction caused that frame, route, or UI state.

Frame uploads are sorted by numeric frame suffix and sent as multipart files
named `<frameNo>.jpg`, with `sessionId` and comma-separated `frameNos` fields.
Backend identity (`requestedBackend` / `resolvedBackend`) lives on the in-memory
`TugboatFrame` and exploration WebSocket frame payload, not on this multipart
upload.
Malformed frame IDs and frames belonging to a stale SDK session are dropped.
Queued frames are uploaded as-is: events reference exact `beforeFrame` /
`afterFrame` IDs, and the multipart protocol has no hash alias, so intermediate
scroll or duplicate-content captures cannot be dropped without breaking those
refs. Backpressure may still drop the oldest pending frames when
`maxPendingFrames` is exceeded.

### Batching, retry, and backpressure

`TugboatCollectorConfig` defaults are:

| Field | Default |
| --- | --- |
| `eventBatchSize` | `10` |
| `eventFlushInterval` | `3 seconds` |
| `maxPendingBatches` | `20` |
| `maxPendingEvents` | `60` |
| `maxPendingFrames` | `20` |

A full batch triggers a flush; the periodic timer sends partial batches.
Lifecycle backgrounding also asks the sink hub to flush, and session end drains
events before posting the final lifecycle message.

The sink treats HTTP `202` as accepted. It retries transport failures, `408`,
`429`, and `5xx`; other response codes are dropped. Retry batches, unsent
events, and frames are bounded in memory. When a bound is exceeded the oldest
items are discarded and a debug message is printed.

Collector and WebSocket delivery are best-effort. Bounded in-memory queues retry
temporary failures while the process remains alive. The SDK does not persist
events or frames across process restarts.

Fresh events can continue to flush even while an older retry head remains
blocked. Session epochs prevent an in-flight response from a prior session from
stamping or clearing a newer session's evidence.

## Using both destinations

```dart
final config = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  explorationCollectorUrl: 'ws://127.0.0.1:7832/sdk',
  collector: productionCollectorConfig,
);
```

The sink hub fans each session, event, and frame to both destinations and
isolates failures per sink. With HTTP configured, connecting the WebSocket does
not enable exploration-only screenshot suppression because frames still need to
reach the HTTP destination.

Custom destinations can be registered through `sinkFactories` on
`TugboatReplayConfig`; the SDK owns one sink instance per capture session.

## Operational limits

- Collector HTTP and exploration WebSocket delivery stay process-local.
- `activationRequestId` and `captureSessionId` are distinct and both emitted.
- Platform-view / video-texture capture adapters are deferred.
- Disposal requests asynchronous finalization; a force-killed process can lose
  queued or in-flight work.

See [Capture and fingerprint architecture](../design/capture-and-fingerprint.md)
for identity, screenshot, privacy, and lifecycle details.
