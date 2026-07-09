import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'collector_config.dart';

/// Builds [TugboatCollectorConfig] from the current host app and device.
abstract final class TugboatCollectorHost {
  TugboatCollectorHost._();

  static Future<TugboatCollectorAppInfo> loadAppInfo() async {
    final device = await _resolveDeviceMetadata();
    final packageInfo = await PackageInfo.fromPlatform();
    return TugboatCollectorAppInfo(
      name: packageInfo.appName,
      version: packageInfo.version,
      buildNumber: packageInfo.buildNumber,
      installationId: device.id,
    );
  }

  static Future<TugboatCollectorConfig> fromPlatform({
    required String apiKey,
    String? baseUrl,
    bool productionProfile = true,
    String? userId,
  }) async {
    final device = await _resolveDeviceMetadata();
    final appInfo = await loadAppInfo();
    final view = PlatformDispatcher.instance.views.first;
    final pixelRatio = view.devicePixelRatio;
    final logicalSize = view.physicalSize / pixelRatio;
    final locale = PlatformDispatcher.instance.locale;
    final effectiveBaseUrl = baseUrl?.isNotEmpty == true
        ? baseUrl!
        : _defaultCollectorBaseUrl(productionProfile: productionProfile);

    return TugboatCollectorConfig(
      baseUrl: effectiveBaseUrl,
      apiKey: apiKey,
      userId: userId,
      appInfo: appInfo,
      deviceInfo: TugboatCollectorDeviceInfo(
        id: device.id,
        platform: device.platform,
        manufacturer: device.manufacturer,
        model: device.model,
        osVersion: device.osVersion,
        screenSize: TugboatCollectorScreenSize(
          width: logicalSize.width,
          height: logicalSize.height,
        ),
        screenDensity: pixelRatio,
        screenDpi: (pixelRatio * 160).round(),
        screenPixelDensity: pixelRatio,
      ),
      ipInfo: TugboatCollectorIpInfo(
        ip: Platform.isAndroid ? '10.0.2.2' : '127.0.0.1',
      ),
      locale: TugboatCollectorLocaleInfo(
        language: locale.languageCode,
        country: locale.countryCode,
        timezone: DateTime.now().timeZoneName,
      ),
    );
  }

  static String defaultCollectorBaseUrl({required bool productionProfile}) =>
      _defaultCollectorBaseUrl(productionProfile: productionProfile);

  static bool isLocalCollectorBaseUrl(String baseUrl) {
    final host = Uri.tryParse(baseUrl)?.host;
    return host == '127.0.0.1' || host == 'localhost' || host == '10.0.2.2';
  }

  static String _defaultCollectorBaseUrl({required bool productionProfile}) {
    if (productionProfile) {
      return TugboatCollectorDefaults.productionBaseUrl;
    }
    if (Platform.isAndroid) {
      return 'http://10.0.2.2:3000';
    }
    return 'http://127.0.0.1:3000';
  }

  static Future<
    ({
      String id,
      String platform,
      String? manufacturer,
      String? model,
      String? osVersion,
    })
  >
  _resolveDeviceMetadata() async {
    final deviceInfo = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final android = await deviceInfo.androidInfo;
      return (
        id: android.id,
        platform: 'android',
        manufacturer: android.manufacturer,
        model: android.model,
        osVersion: android.version.release,
      );
    }

    if (Platform.isIOS) {
      final ios = await deviceInfo.iosInfo;
      return (
        id: ios.identifierForVendor ?? 'ios-unknown',
        platform: 'ios',
        manufacturer: null,
        model: ios.model,
        osVersion: ios.systemVersion,
      );
    }

    return (
      id: 'unknown-device',
      platform: Platform.operatingSystem,
      manufacturer: null,
      model: null,
      osVersion: null,
    );
  }
}
