# Collector Integration

The PMKit Flutter SDK can stream capture output to two collectors:

- **Local exploration collector** (`pmkit_cli`) over WebSocket
- **Standalone HTTP collector** (`pmkit-collector`) over REST

Both sinks are optional and can be enabled together.

## Local exploration (WebSocket)

Use this during autonomous CLI exploration runs:

```dart
PmkitReplay.wrapApp(
  config: const PmkitReplayConfig(
    explorationCollectorUrl: 'ws://127.0.0.1:7832/sdk',
    explorationRunId: 'optional-run-id',
  ),
  child: child,
);
```

The CLI starts the collector and sets up `adb reverse tcp:7832 tcp:7832` so the app can reach the host at `127.0.0.1:7832`.

## Production ingestion (HTTP)

Use this for the standalone `pmkit-collector` service:

```dart
PmkitReplay.wrapApp(
  config: PmkitReplayConfig(
    collector: PmkitCollectorConfig(
      baseUrl: 'https://collector.example.com',
      apiKey: 'pmk_your_token',
      appInfo: PmkitCollectorAppInfo(
        name: 'My App',
        version: '1.0.0',
        buildNumber: '1',
        installationId: installationId,
      ),
      deviceInfo: PmkitCollectorDeviceInfo(
        id: deviceId,
        platform: 'ios',
        screenSize: PmkitCollectorScreenSize(width: 390, height: 844),
        screenDensity: 3,
        screenDpi: 460,
        screenPixelDensity: 3,
      ),
      ipInfo: PmkitCollectorIpInfo(ip: '203.0.113.10'),
      locale: PmkitCollectorLocaleInfo(
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
PmkitReplayConfig(
  explorationCollectorUrl: 'ws://127.0.0.1:7832/sdk',
  collector: productionCollectorConfig,
)
```

Capture remains authoritative in the in-memory `PmkitSession`. Sink failures are swallowed so the host app is never blocked by collector availability.
