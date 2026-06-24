# Collector Integration

**Recording data quality (2026-06-24):** ✅ When the exploration WebSocket connects and no
HTTP collector is configured, the SDK suppresses Flutter frame capture so events stream faster
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

When the exploration WebSocket connects and no HTTP collector is configured, the SDK **stops taking Flutter screenshots** and emits interaction events without waiting on screenshot capture. The CLI still records ADB `before.jpg` / `after.jpg` per step. Fingerprints and SDK events continue to stream over the socket. ✅ **Implemented** in `controller.dart` / `exploration_transport.dart` (2026-06-24).

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
