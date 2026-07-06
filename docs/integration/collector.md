# Collector Integration

**Recording data quality (2026-06-29):** When the exploration WebSocket connects and no HTTP
collector is configured, the SDK suppresses *new* Flutter frame capture for performance. Frames
that are captured (including before connect) are streamed over the WebSocket and persisted by
`tugboat-cli` under `frames/`. ADB step screenshots remain the primary gesture-level evidence.

**Earlier note (2026-06-24):** ✅ When the exploration WebSocket connects and no HTTP collector
is configured, the SDK suppresses Flutter frame capture so events stream faster
during `tugboat-cli` recordings. ADB screenshots remain the visual evidence per step. Tracked in
`tugboat-cli/docs/recording-data-quality-plan.md` (Phase 1 + SDK cross-repo item).

The Tugboat Flutter SDK can stream capture output to two collectors:

- **Local exploration collector** (`tugboat-cli`) over WebSocket
- **Standalone HTTP collector** (`tugboat-collector`) over REST

Both sinks are optional and can be enabled together.

## Local exploration (WebSocket)

Use this during autonomous CLI exploration runs:

```dart
TugboatReplay.wrapApp(
  config: const TugboatReplayConfig(
    explorationCollectorUrl: 'ws://127.0.0.1:7832/sdk',
    explorationRunId: 'optional-run-id',
    appInfo: TugboatCollectorAppInfo(
      name: 'My App',
      version: '1.0.0',
      buildNumber: '42',
      installationId: 'device-installation-id',
    ),
  ),
  child: child,
);
```

When `appInfo` is omitted, the SDK falls back to `collector.appInfo` if a HTTP collector is also configured.

The CLI stores the session payload in `session.json`, including `appInfo` when provided.

The CLI starts the collector and sets up `adb reverse tcp:7832 tcp:7832` so the app can reach the host at `127.0.0.1:7832`.

When the exploration WebSocket connects and no HTTP collector is configured, the SDK **stops
scheduling new Flutter screenshots** (performance) and emits interaction events without waiting
on screenshot capture. The CLI still records ADB `before.jpg` / `after.jpg` per step. Any frames
that *are* captured are streamed over the socket and persisted under `frames/` by `tugboat-cli`.
Fingerprints and SDK events continue to stream over the socket.

## Production ingestion (HTTP)

Use this for the standalone `tugboat-collector` service:

```dart
TugboatReplay.wrapApp(
  config: TugboatReplayConfig(
    collector: TugboatCollectorConfig(
      baseUrl: 'https://collector.example.com',
      apiKey: 'pmk_your_token',
      appInfo: TugboatCollectorAppInfo(
        name: 'My App',
        version: '1.0.0',
        buildNumber: '1',
        installationId: installationId,
      ),
      deviceInfo: TugboatCollectorDeviceInfo(
        id: deviceId,
        platform: 'ios',
        screenSize: TugboatCollectorScreenSize(width: 390, height: 844),
        screenDensity: 3,
        screenDpi: 460,
        screenPixelDensity: 3,
      ),
      ipInfo: TugboatCollectorIpInfo(ip: '203.0.113.10'),
      locale: TugboatCollectorLocaleInfo(
        language: 'en',
        country: 'US',
        timezone: 'America/New_York',
      ),
    ),
  ),
  child: child,
);
```

### HTTP behavior

- `POST /v1/sessions` on session start and session end
- `POST /v1/events/batch` for interaction events
- `POST /v1/frames` for screenshot uploads
- Events are batched with a default size of `10`
- Partial batches flush on a timer and when the controller disposes

### Scroll and swipe events

The SDK emits scroll and swipe events as first-class interaction evidence:

- `scroll_start` and `scroll_end` carry `targetAnchor` for the resolved `Scrollable` when
  available. `scroll_end.relatedEventId` points back to the matching `scroll_start`.
- Scroll event `data` includes `axis`, `depth`, `offset`, `startOffset`, `endOffset`,
  `offsetNorm`, edge flags, `overscrollCount`, and `sectionLabel` when the scrollable is inside
  a `TugboatSubView`.
- Pointer drags beyond touch slop emit `swipe` on pointer up. A swipe with
  `data.scrolled:false` and `result:noVisibleChange` represents a dead swipe / failed scroll
  intent; a swipe with `data.scrolled:true` includes `scrollStartEventId` linking it to the
  scroll sequence.

Context graph enrichment consumes these events through
`POST /v1/enrichment/map-event`: if a scroll/swipe event has a `targetAnchor.fingerprint`, the
mapped event can attach screen/control context and preserve fields such as `isDeadSwipe`,
`scrolled`, direction, axis, section label, edge, and overscroll count.

### Security note

Mobile API keys are client-visible. Do not hardcode production secrets in the app binary without accepting that risk. Prefer environment-specific keys with the narrowest scope possible.

## Using both collectors

```dart
TugboatReplayConfig(
  explorationCollectorUrl: 'ws://127.0.0.1:7832/sdk',
  collector: productionCollectorConfig,
)
```

Capture remains authoritative in the in-memory `TugboatSession`. Sink failures are swallowed so the host app is never blocked by collector availability.
