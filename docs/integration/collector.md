# Collector integration

This page documents the transport behavior implemented by the Flutter SDK.
Server-side storage, enrichment, and Atlas behavior are outside this repository
and must be verified against the service that receives these requests.

The SDK's built-in destination is the standalone HTTP collector. Exploration
runs use the same collector: point `collector.baseUrl` at a local HTTP
collector.

Evidence remains authoritative in the controller's bounded, in-memory session.
Transport failures are isolated from the host app.

## Required app integration

Install the wrapper and navigator observer. Capture is disabled by default.
Set `enabled: true` for startup capture, or call `TugboatReplay.activate` later:

```dart
MaterialApp(
  navigatorObservers: [TugboatReplay.navigatorObserver],
  builder: (context, child) => TugboatReplay.wrapApp(
    child: child!,
    config: config,
  ),
);
```

The default configuration masks all text and media. Optional inventory,
semantic-map, diagnostic, and action-context evidence stays off until the host
enables each matching capability.

Without the observer, pointer and scroll evidence still works but route-change
events and route-backed anchors are incomplete. Without the wrapper no capture
controller or transport is installed.

Screenshot JPEG frames are schema-v10 `frame` records regardless of
`TugboatScreenshotCaptureBackend`. Switching to `nativeCpuExperimental` does
not change collector URLs, event names, or the frame transport schema. Keep
the default `flutterRepaintBoundary` backend for production collector cohorts.

## Local exploration runs

An interactive local run uses the HTTP collector with a local `baseUrl`. Turn
on the exploration evidence you need:

```dart
final config = TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: true,
  emitViewportSemanticMap: true,
  acceptActionContext: true,
  explorationRunId: 'optional-run-id',
  collector: localCollectorConfig,
);
```

The same switches are available at launch through the Android Intent extras
and iOS launch inputs listed in the package README. For an Android emulator the
host-side runner must make the local collector reachable (`10.0.2.2` from the
emulator, or `adb reverse`). Connection setup is not performed by the Flutter
package.

The optional `locale` object on session metadata contains `language`, optional
`country` and `script`, and a BCP 47 `tag`. Every SDK event carries the current
locale when known. A `locale_changed` evidence event contains `previousLocale`
when known and the new `locale` in its payload.

Action windows and capture pause are in-process controller calls
(`setActionContext`, `clearActionContext`, `setCapturePaused`). The SDK does
not receive control messages over the network.

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
  enabled: true,
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

- `atMs` — milliseconds since session start, plus absolute UTC `triggeredAt`;
- `userId` — current runtime user on every session lifecycle event, including
  `session_end`. After start, `null` is an explicit identity-clear on
  `user_changed` / `session_identify` and the current (possibly anonymous)
  identity on `traits_updated` and `session_end`;
- `traits` — full traits snapshot when the host has set a bag (`session_start`,
  `session_identify`, `traits_updated`, `user_changed`, `session_end`); the
  collector stores the bag as-is (no server-side partial merge);
- `traitsId` — pass-through of a prior collector-issued id when no new bag is
  sent (for example `session_end` or `session_start` after only an id is
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

An `interaction` record carries `route`, `targetFingerprint`, `gesture`,
`payload` and `targetAnchor`, plus `targetResolutionFailureReason` when no
target resolved. Exploration taps (scene inventory emission on) also carry
`fingerprintConfidence`, `fingerprintSource` (how the fingerprint was
resolved), `routeKey` (the route key it was hashed under) and `surface`
(`kind`, optional `widgetClass`). These four are exploration-only: production
taps never carry them.

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

The opt-in `focus_changed` and `system_input` evidence events
(`TugboatReplayConfig.captureFocusChanges` / `captureSystemInput`) use the
generic envelope with `stream: evidence`. Their `payload` is the closed
vocabulary described in
[Capture and fingerprint](../design/capture-and-fingerprint.md#focus-and-system-input).
The observed frame, when present, is the envelope's `afterFrame`. Deploy
collector acceptance for these event types before enabling either capability
in production: a non-retryable rejection drops the whole batch.

For schema-v2 interactions, `afterFrame` is a temporal visual observation. It
does not assert that the interaction caused that frame, route, or UI state.

Frame uploads are sorted by numeric frame suffix and sent as multipart files
named `<frameNo>.jpg`, with `sessionId` and comma-separated `frameNos` fields.
Backend identity (`requestedBackend` / `resolvedBackend`) lives on the in-memory
`TugboatFrame`, not on this multipart upload.
Malformed frame IDs and frames belonging to a stale SDK session are dropped.
Queued frames are uploaded as-is: events reference exact `beforeFrame` /
`afterFrame` IDs, and the multipart protocol has no hash alias, so intermediate
scroll or duplicate-content captures cannot be dropped without breaking those
refs. Backpressure may still drop pending frames when `maxPendingFrames` or
`maxPendingFrameBytes` is exceeded. Eviction drops the oldest frame that no
recorded event references (`beforeFrame` / `afterFrame`) first, keeps the
newest frame, and drops a referenced frame only when nothing else is left.
Both bounds cover frames waiting for upload: a flush takes one batch of up to
20 frames from the queue at a time, so at most that batch is held beyond them.

### Batching, retry, and backpressure

`TugboatCollectorConfig` defaults are:

| Field | Default |
| --- | --- |
| `eventBatchSize` | `10` |
| `eventFlushInterval` | `3 seconds` |
| `maxPendingBatches` | `20` |
| `maxPendingEvents` | `60` |
| `maxPendingFrames` | `400` |
| `maxPendingFrameBytes` | `8 MiB` |

A full batch triggers a flush; the periodic timer sends partial batches.
Lifecycle backgrounding also asks the sink hub to flush, and session end drains
frames and events before posting the final lifecycle message. Flushes run one
at a time; a flush requested while one runs queues a single follow-up pass, so
work recorded mid-flush (such as the session's last frame) is never left
behind. A pass sends pending lifecycle posts, then frames, then the events
queued when it reached them, uploading newly captured frames between event
batches. When an event post fails or times out, the pass stops posting events
and moves the rest of them to the retry queue unsent. When the oldest retry
batch gets no response at all (timeout or transport error), fresh events are
also moved there unsent, so a hung endpoint costs one event timeout per pass.
When it answers with an error status, one fresh batch is still tried, so a
batch the collector keeps rejecting cannot hold every later event. Every collector request times
out after 15 seconds and is then retried.

Bounded `capture_diagnostic` events describe delivery problems without image
contents, payloads, or credentials: `collector_frame_upload` (frame upload
failures, evictions, recovery), `collector_request` (the first failed
`/v1/sessions` or `/v1/events/batch` post per outage, with `statusCode` or
`error: timeout | transport`, and its recovery), and `collector_flush` (the
first pass per outage slower than 10 seconds, with `durationMs`, the slowest
`step`, and `stepDurationMs`; the outage ends with a fast pass once every
request path and frame uploads have recovered).

The sink treats HTTP `202` as accepted. It retries transport failures, `408`,
`429`, and `5xx`; other response codes are dropped. Retry batches, unsent
events, and frames are bounded in memory. When a bound is exceeded the oldest
items are discarded (frames by the eviction order above) and a debug message is
printed. Frame evictions emit a `collector_frame_upload` diagnostic with
`result: dropped` when the running count reaches a power of two, and once more
with the final count before `session_end`. Each carries `droppedFrameCount`
and `droppedReferencedFrameCount`.

Collector delivery is best-effort. Bounded in-memory queues retry
temporary failures while the process remains alive. The SDK does not persist
events or frames across process restarts.

Fresh events can continue to flush even while an older retry head remains
blocked. Session epochs prevent an in-flight response from a prior session from
stamping or clearing a newer session's evidence.

## Custom destinations

Custom destinations can be registered through `sinkFactories` on
`TugboatReplayConfig`; the SDK owns one sink instance per capture session. The
sink hub fans each session, event, and frame to every sink and isolates
failures per sink.

## Operational limits

- Collector HTTP delivery stays process-local.
- `activationRequestId` and `captureSessionId` are distinct and both emitted.
- Platform-view / video-texture capture adapters are deferred.
- Disposal requests asynchronous finalization; a force-killed process can lose
  queued or in-flight work.

See [Capture and fingerprint architecture](../design/capture-and-fingerprint.md)
for identity, screenshot, privacy, and lifecycle details.
