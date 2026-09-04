import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/collector_config.dart';
import 'package:tugboat/src/launch_options.dart';
import 'package:tugboat/src/replay_config.dart';

TugboatCollectorConfig _collector({String baseUrl = 'https://prod.example'}) {
  return TugboatCollectorConfig(
    baseUrl: baseUrl,
    apiKey: 'key',
    appInfo: const TugboatCollectorAppInfo(
      name: 'app',
      version: '1',
      buildNumber: '1',
      installationId: 'id',
      appId: 'com.example',
    ),
    deviceInfo: const TugboatCollectorDeviceInfo(
      id: 'device',
      platform: 'android',
      screenSize: TugboatCollectorScreenSize(width: 100, height: 200),
      screenDensity: 2,
      screenDpi: 320,
      screenPixelDensity: 2,
    ),
    ipInfo: const TugboatCollectorIpInfo(ip: '127.0.0.1'),
    locale: const TugboatCollectorLocaleInfo(),
  );
}

void main() {
  test('parseBool accepts 1/true/yes and bools', () {
    expect(TugboatLaunchParsers.parseBool(true), isTrue);
    expect(TugboatLaunchParsers.parseBool('1'), isTrue);
    expect(TugboatLaunchParsers.parseBool(' True '), isTrue);
    expect(TugboatLaunchParsers.parseBool('YES'), isTrue);
    expect(TugboatLaunchParsers.parseBool(null), isFalse);
    expect(TugboatLaunchParsers.parseBool('0'), isFalse);
    expect(TugboatLaunchParsers.parseBool('exploration'), isFalse);
  });

  test('fromMap trims and keeps raw collector URL for validation', () {
    final options = TugboatLaunchOptions.fromMap({
      'emitSceneInventory': '1',
      'acceptActionContext': true,
      'collectorBaseUrl': ' http://10.0.2.2:8787 ',
    });
    expect(options.emitSceneInventory, isTrue);
    expect(options.acceptActionContext, isTrue);
    expect(options.captureRequested, isTrue);
    expect(options.collectorBaseUrl, 'http://10.0.2.2:8787');
  });

  test('fromMap defaults to off', () {
    const options = TugboatLaunchOptions();
    expect(options.captureRequested, isFalse);
    expect(TugboatLaunchOptions.fromMap(const {}).captureRequested, isFalse);
  });

  test('parseLocalCollectorUrl allows only local http hosts', () {
    expect(
      TugboatLaunchParsers.parseLocalCollectorUrl('http://127.0.0.1:3000'),
      'http://127.0.0.1:3000',
    );
    expect(
      TugboatLaunchParsers.parseLocalCollectorUrl('http://LOCALHOST:8787'),
      'http://LOCALHOST:8787',
    );
    expect(
      TugboatLaunchParsers.parseLocalCollectorUrl('https://127.0.0.1:3000'),
      isNull,
    );
    expect(
      TugboatLaunchParsers.parseLocalCollectorUrl(
        'https://collector.example.com',
      ),
      isNull,
    );
    expect(
      TugboatLaunchParsers.parseLocalCollectorUrl(
        'http://127.0.0.1:3000/sdk?x=1',
      ),
      isNull,
    );
    expect(
      TugboatLaunchParsers.parseLocalCollectorUrl('http://user@127.0.0.1:3000'),
      isNull,
    );
  });

  test('resolve prefers runtime over build over fallback', () {
    expect(
      resolveTugboatCollectorBaseUrl(
        isRelease: false,
        productionBaseUrl: 'https://prod.example',
        runtimeBaseUrl: 'http://localhost:8787',
        buildBaseUrl: 'http://127.0.0.1:3000',
        localFallbackBaseUrl: 'http://10.0.2.2:3000',
      ),
      'http://localhost:8787',
    );
    expect(
      resolveTugboatCollectorBaseUrl(
        isRelease: false,
        productionBaseUrl: 'https://prod.example',
        buildBaseUrl: 'http://127.0.0.1:3000',
      ),
      'http://127.0.0.1:3000',
    );
    expect(
      resolveTugboatCollectorBaseUrl(
        isRelease: false,
        productionBaseUrl: 'https://prod.example',
      ),
      'https://prod.example',
    );
  });

  test('resolve ignores non-local runtime URLs', () {
    expect(
      resolveTugboatCollectorBaseUrl(
        isRelease: false,
        productionBaseUrl: 'https://prod.example',
        runtimeBaseUrl: 'https://evil.example',
      ),
      'https://prod.example',
    );
  });

  test('resolve ignores overrides in release', () {
    expect(
      resolveTugboatCollectorBaseUrl(
        isRelease: true,
        productionBaseUrl: 'https://prod.example',
        runtimeBaseUrl: 'http://localhost:8787',
        buildBaseUrl: 'http://127.0.0.1:3000',
        localFallbackBaseUrl: 'http://10.0.2.2:3000',
      ),
      'https://prod.example',
    );
  });

  test(
    'withDeviceFarmOverrides ORs capabilities without touching mask',
    () async {
      const config = TugboatReplayConfig(enabled: false, collector: null);
      final merged =
          await TugboatReplayConfig(
            enabled: false,
            screenshotMaskLevel: config.screenshotMaskLevel,
          ).withDeviceFarmOverrides(
            launchOptions: const TugboatLaunchOptions(emitSceneInventory: true),
            isRelease: true,
            logLaunch: false,
          );
      expect(merged.enabled, isTrue);
      expect(merged.emitSceneInventory, isTrue);
      expect(merged.acceptActionContext, isFalse);
      expect(
        merged.effectiveScreenshotMaskLevel,
        config.effectiveScreenshotMaskLevel,
      );
    },
  );

  test('withDeviceFarmOverrides is a no-op without launch input', () async {
    final config = TugboatReplayConfig(collector: _collector());
    final merged = await config.withDeviceFarmOverrides(
      launchOptions: const TugboatLaunchOptions(),
      isRelease: false,
      logLaunch: false,
    );
    expect(merged.enabled, isFalse);
    expect(merged.collector?.baseUrl, 'https://prod.example');
  });

  test('withDeviceFarmOverrides rewrites collector in debug only', () async {
    final debug = await TugboatReplayConfig(collector: _collector())
        .withDeviceFarmOverrides(
          launchOptions: const TugboatLaunchOptions(
            collectorBaseUrl: 'http://localhost:8787',
          ),
          isRelease: false,
          logLaunch: false,
        );
    expect(debug.collector?.baseUrl, 'http://localhost:8787');

    final release = await TugboatReplayConfig(collector: _collector())
        .withDeviceFarmOverrides(
          launchOptions: const TugboatLaunchOptions(
            collectorBaseUrl: 'http://localhost:8787',
          ),
          isRelease: true,
          logLaunch: false,
        );
    expect(release.collector?.baseUrl, 'https://prod.example');
  });

  test('fromPlatform decodes the native launch payload', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('tugboat/launch');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getLaunchOptions');
          return <String, Object?>{
            'emitSceneInventory': '1',
            'acceptActionContext': true,
            'collectorBaseUrl': 'http://127.0.0.1:3000',
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final options = await TugboatLaunchOptions.fromPlatform();
    expect(options.emitSceneInventory, isTrue);
    expect(options.acceptActionContext, isTrue);
    expect(options.captureRequested, isTrue);
    expect(options.collectorBaseUrl, 'http://127.0.0.1:3000');
  });

  test('fromPlatform falls back to off without a native plugin', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const options = TugboatLaunchOptions();
    expect(options.captureRequested, isFalse);
    final fromEmpty = TugboatLaunchOptions.fromMap(const {});
    expect(fromEmpty.captureRequested, isFalse);
  });
}
