import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'collector_config.dart';
import 'device_runtime_snapshot.dart';
import 'installation_id.dart';

typedef _DeviceMetadata = ({
  String id,
  String platform,
  String? manufacturer,
  String? model,
  String? osVersion,
});

/// Builds [TugboatCollectorConfig] from the current host app and device.
abstract final class TugboatCollectorHost {
  TugboatCollectorHost._();

  static const _iosUnknownDeviceId = 'ios-unknown';

  static TugboatInstallationIdStore _installationIdStore =
      TugboatInstallationIdStore(directory: getApplicationSupportDirectory);

  /// Replaces the store that persists the SDK's installation id.
  @visibleForTesting
  static set debugInstallationIdStore(TugboatInstallationIdStore store) =>
      _installationIdStore = store;

  /// Restores the default installation id store after a test.
  @visibleForTesting
  static void debugResetInstallationIdStore() => _installationIdStore =
      TugboatInstallationIdStore(directory: getApplicationSupportDirectory);

  /// The SDK's own installation id: a random UUID minted on first launch and
  /// persisted until the app is reinstalled or its data is cleared. On iOS
  /// the first value is the device's `identifierForVendor`, so installs that
  /// already reported it as `device.id` keep it.
  static Future<String> installationId() async {
    final device = await _resolveDeviceMetadata();
    return _sdkInstallationId(device);
  }

  /// [installationId] is the host's own installation id. When non-empty it
  /// wins over the SDK's id ([TugboatCollectorHost.installationId]).
  static Future<TugboatCollectorAppInfo> loadAppInfo({
    String? installationId,
  }) async {
    final device = await _resolveDeviceMetadata();
    final packageInfo = await PackageInfo.fromPlatform();
    return TugboatCollectorAppInfo(
      name: packageInfo.appName,
      version: packageInfo.version,
      buildNumber: packageInfo.buildNumber,
      installationId: await resolveTugboatInstallationId(
        hostInstallationId: installationId,
        sdkInstallationId: () => _sdkInstallationId(device),
      ),
      appId: packageInfo.packageName,
    );
  }

  /// Builds a collector config from the host platform.
  ///
  /// [installationId] is the host's own installation id. When non-empty it
  /// is sent as `appInfo.installationId`; otherwise the SDK's persisted id
  /// ([TugboatCollectorHost.installationId]) is sent.
  static Future<TugboatCollectorConfig> fromPlatform({
    required String apiKey,
    String? baseUrl,
    bool productionProfile = true,
    String? userId,
    String? installationId,
  }) async {
    final device = await _resolveDeviceMetadata();
    final runtime = await TugboatDeviceRuntimeSnapshot.capture();
    final appInfo = await loadAppInfo(installationId: installationId);
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
        batteryPercent: runtime.batteryPercent,
        storageFreeMb: runtime.storageFreeMb,
        ramMb: runtime.ramMb,
        networkType: runtime.networkType,
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

  static Future<String> _sdkInstallationId(_DeviceMetadata device) {
    final iosVendorId =
        device.platform == 'ios' && device.id != _iosUnknownDeviceId
        ? device.id
        : null;
    return _installationIdStore.read(seed: iosVendorId);
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

  static Future<_DeviceMetadata> _resolveDeviceMetadata() async {
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
        id: ios.identifierForVendor ?? _iosUnknownDeviceId,
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
