/// Host-provided app metadata required by the standalone HTTP collector.
class TugboatCollectorAppInfo {
  const TugboatCollectorAppInfo({
    required this.name,
    required this.version,
    required this.buildNumber,
    required this.installationId,
  });

  final String name;
  final String version;
  final String buildNumber;
  final String installationId;

  Map<String, Object?> toJson() => {
    'name': name,
    'version': version,
    'buildNumber': buildNumber,
    'installationId': installationId,
  };
}

class TugboatCollectorScreenSize {
  const TugboatCollectorScreenSize({
    required this.width,
    required this.height,
  });

  final double width;
  final double height;

  Map<String, Object?> toJson() => {
    'width': width,
    'height': height,
  };
}

/// Host-provided device metadata required by the standalone HTTP collector.
class TugboatCollectorDeviceInfo {
  const TugboatCollectorDeviceInfo({
    required this.id,
    required this.platform,
    required this.screenSize,
    required this.screenDensity,
    required this.screenDpi,
    required this.screenPixelDensity,
    this.manufacturer,
    this.model,
    this.osVersion,
  });

  final String id;
  final String platform;
  final TugboatCollectorScreenSize screenSize;
  final double screenDensity;
  final int screenDpi;
  final double screenPixelDensity;
  final String? manufacturer;
  final String? model;
  final String? osVersion;

  Map<String, Object?> toJson() => {
    'id': id,
    'platform': platform,
    if (manufacturer != null) 'manufacturer': manufacturer,
    if (model != null) 'model': model,
    if (osVersion != null) 'osVersion': osVersion,
    'screenSize': screenSize.toJson(),
    'screenDensity': screenDensity,
    'screenDpi': screenDpi,
    'screenPixelDensity': screenPixelDensity,
  };
}

class TugboatCollectorIpInfo {
  const TugboatCollectorIpInfo({
    required this.ip,
    this.city,
    this.region,
    this.country,
    this.timezone,
    this.isp,
    this.org,
  });

  final String ip;
  final String? city;
  final String? region;
  final String? country;
  final String? timezone;
  final String? isp;
  final String? org;

  Map<String, Object?> toJson() => {
    'ip': ip,
    if (city != null) 'city': city,
    if (region != null) 'region': region,
    if (country != null) 'country': country,
    if (timezone != null) 'timezone': timezone,
    if (isp != null) 'isp': isp,
    if (org != null) 'org': org,
  };
}

class TugboatCollectorLocaleInfo {
  const TugboatCollectorLocaleInfo({
    this.language,
    this.country,
    this.timezone,
  });

  final String? language;
  final String? country;
  final String? timezone;

  Map<String, Object?> toJson() => {
    if (language != null) 'language': language,
    if (country != null) 'country': country,
    if (timezone != null) 'timezone': timezone,
  };
}

/// Well-known defaults for the standalone HTTP collector (`tugboat-collector`).
abstract final class TugboatCollectorDefaults {
  /// Production collector base URL (no trailing slash).
  static const productionBaseUrl = 'https://collector.gettugboat.com';
}

/// Configuration for the standalone HTTP collector (`tugboat-collector`).
class TugboatCollectorConfig {
  const TugboatCollectorConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.appInfo,
    required this.deviceInfo,
    required this.ipInfo,
    required this.locale,
    this.userId,
    this.eventBatchSize = 10,
    this.eventFlushInterval = const Duration(seconds: 5),
    this.maxPendingBatches = 20,
  });

  final String baseUrl;
  final String apiKey;
  final String? userId;
  final TugboatCollectorAppInfo appInfo;
  final TugboatCollectorDeviceInfo deviceInfo;
  final TugboatCollectorIpInfo ipInfo;
  final TugboatCollectorLocaleInfo locale;
  final int eventBatchSize;
  final Duration eventFlushInterval;
  final int maxPendingBatches;
}
