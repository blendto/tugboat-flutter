import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/collector_config.dart';
import 'package:tugboat/src/collector_mapper.dart';

void main() {
  test('device info toJson omits unset runtime snapshot fields', () {
    const info = TugboatCollectorDeviceInfo(
      id: 'device-1',
      platform: 'android',
      screenSize: TugboatCollectorScreenSize(width: 412, height: 915),
      screenDensity: 2.625,
      screenDpi: 420,
      screenPixelDensity: 2.625,
      manufacturer: 'Google',
      model: 'Pixel 9',
      osVersion: '15',
    );

    expect(info.toJson(), {
      'id': 'device-1',
      'platform': 'android',
      'manufacturer': 'Google',
      'model': 'Pixel 9',
      'osVersion': '15',
      'screenSize': {'width': 412, 'height': 915},
      'screenDensity': 2.625,
      'screenDpi': 420,
      'screenPixelDensity': 2.625,
    });
  });

  test('device info toJson includes runtime snapshot fields when set', () {
    const info = TugboatCollectorDeviceInfo(
      id: 'device-1',
      platform: 'android',
      screenSize: TugboatCollectorScreenSize(width: 412, height: 915),
      screenDensity: 2.625,
      screenDpi: 420,
      screenPixelDensity: 2.625,
      batteryPercent: 72,
      storageFreeMb: 48_512,
      ramMb: 8192,
      networkType: TugboatCollectorNetworkType.wifi,
    );

    expect(info.toJson()['batteryPercent'], 72);
    expect(info.toJson()['storageFreeMb'], 48_512);
    expect(info.toJson()['ramMb'], 8192);
    expect(info.toJson()['networkType'], 'wifi');
  });

  test('session_start maps runtime snapshot fields on device bag', () {
    final config = TugboatCollectorConfig(
      baseUrl: 'https://collector.example.test',
      apiKey: 'pmk_test',
      appInfo: const TugboatCollectorAppInfo(
        name: 'Example App',
        version: '1.0.0',
        buildNumber: '1',
        installationId: 'inst_1',
        appId: 'com.example.app',
      ),
      deviceInfo: const TugboatCollectorDeviceInfo(
        id: 'device_client',
        platform: 'android',
        screenSize: TugboatCollectorScreenSize(width: 390, height: 844),
        screenDensity: 3,
        screenDpi: 460,
        screenPixelDensity: 3,
        batteryPercent: 55,
        storageFreeMb: 12_800,
        ramMb: 6144,
        networkType: TugboatCollectorNetworkType.cellular,
      ),
      ipInfo: const TugboatCollectorIpInfo(ip: '127.0.0.1'),
      locale: const TugboatCollectorLocaleInfo(language: 'en'),
    );

    final mapped = mapTugboatSessionLifecycleToCollectorSession(
      eventType: TugboatCollectorSessionEventType.sessionStart.wireValue,
      sessionId: 'sess_123',
      triggeredAt: DateTime.utc(2026, 6, 19),
      config: config,
    );

    final device = mapped['device']! as Map<String, Object?>;
    expect(device['batteryPercent'], 55);
    expect(device['storageFreeMb'], 12_800);
    expect(device['ramMb'], 6144);
    expect(device['networkType'], 'cellular');
  });
}
