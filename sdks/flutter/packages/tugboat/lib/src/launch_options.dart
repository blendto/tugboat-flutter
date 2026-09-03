import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'replay_config.dart';

/// Device Farm launch inputs for Tugboat capture.
///
/// The SDK reads these at runtime from the host platform so host apps need
/// no native code of their own:
///
/// * Android: `Intent` extras `tugboat_emit_scene_inventory`,
///   `tugboat_accept_action_context`, `tugboat_collector_base_url`
///   (e.g. `adb shell am start ... -e tugboat_emit_scene_inventory 1`).
/// * iOS: process environment `TUGBOAT_EMIT_SCENE_INVENTORY`,
///   `TUGBOAT_ACCEPT_ACTION_CONTEXT`, `TUGBOAT_COLLECTOR_BASE_URL`
///   (set by the XCUITest/Device Farm runner).
///
/// Values `1`, `true`, and `yes` (case-insensitive) enable a capability.
/// Everything else — including absent — means off. The collector URL is
/// accepted only for local `http` hosts; see
/// [TugboatLaunchParsers.parseLocalCollectorUrl]. Release builds always use
/// the configured production collector; the override never replaces it.
class TugboatLaunchOptions {
  const TugboatLaunchOptions({
    this.emitSceneInventory = false,
    this.acceptActionContext = false,
    this.collectorBaseUrl,
  });

  static const MethodChannel channel = MethodChannel('tugboat/launch');

  static const String keyEmitSceneInventory = 'emitSceneInventory';
  static const String keyAcceptActionContext = 'acceptActionContext';
  static const String keyCollectorBaseUrl = 'collectorBaseUrl';

  final bool emitSceneInventory;
  final bool acceptActionContext;

  /// Raw (unvalidated) collector URL from the launch environment, if any.
  ///
  /// Validate with [TugboatLaunchParsers.parseLocalCollectorUrl] before use.
  final String? collectorBaseUrl;

  bool get captureRequested => emitSceneInventory || acceptActionContext;

  /// Reads launch inputs from the host platform. Never throws: a missing
  /// plugin, platform error, or unexpected payload yields defaults (off).
  ///
  /// Pass [channel] in tests to avoid touching the real binary messenger.
  static Future<TugboatLaunchOptions> fromPlatform({
    MethodChannel? channel,
  }) async {
    try {
      final values = await (channel ?? TugboatLaunchOptions.channel)
          .invokeMapMethod<String, Object?>('getLaunchOptions');
      return TugboatLaunchOptions.fromMap(values ?? const {});
    } on MissingPluginException {
      return const TugboatLaunchOptions();
    } on PlatformException {
      return const TugboatLaunchOptions();
    }
  }

  factory TugboatLaunchOptions.fromMap(Map<String, Object?> values) {
    final rawBaseUrl = values[keyCollectorBaseUrl] as String?;
    return TugboatLaunchOptions(
      emitSceneInventory: TugboatLaunchParsers.parseBool(
        values[keyEmitSceneInventory],
      ),
      acceptActionContext: TugboatLaunchParsers.parseBool(
        values[keyAcceptActionContext],
      ),
      collectorBaseUrl: rawBaseUrl?.trim().isEmpty == true
          ? null
          : rawBaseUrl?.trim(),
    );
  }

  Map<String, Object?> toJson() => {
    'captureRequested': captureRequested,
    'emitSceneInventory': emitSceneInventory,
    'acceptActionContext': acceptActionContext,
  };
}

/// Pure parsers for launch inputs. Single source of truth so Android,
/// iOS, and Dart never drift (natives pass raw strings through).
abstract final class TugboatLaunchParsers {
  TugboatLaunchParsers._();

  static const localHosts = {'127.0.0.1', 'localhost', '10.0.2.2'};

  static bool parseBool(Object? value) {
    if (value is bool) return value;
    final normalized = value?.toString().trim().toLowerCase();
    return normalized == '1' || normalized == 'true' || normalized == 'yes';
  }

  /// Returns [value] only when it is a local `http` collector endpoint.
  ///
  /// Rejects `https`, user-info, queries, fragments, and non-root paths so a
  /// farmed launch can never redirect evidence to an arbitrary host.
  static String? parseLocalCollectorUrl(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      return null;
    }
    return localHosts.contains(uri.host.toLowerCase()) ? normalized : null;
  }
}

/// Resolves the effective collector base URL for one app launch.
///
/// Precedence: validated runtime (Device Farm) URL > validated build-time
/// (`--dart-define`) URL > [localFallbackBaseUrl] (e.g. `.env → local`
/// mapping, already validated or null) > [productionBaseUrl].
/// Release builds always return [productionBaseUrl].
String resolveTugboatCollectorBaseUrl({
  required bool isRelease,
  required String productionBaseUrl,
  String? runtimeBaseUrl,
  String? buildBaseUrl,
  String? localFallbackBaseUrl,
}) {
  if (isRelease) return productionBaseUrl;
  return TugboatLaunchParsers.parseLocalCollectorUrl(runtimeBaseUrl) ??
      TugboatLaunchParsers.parseLocalCollectorUrl(buildBaseUrl) ??
      localFallbackBaseUrl ??
      productionBaseUrl;
}

/// Device Farm merge for [TugboatReplayConfig]. Additive only: enabling a
/// launch capability never changes masking, limits, transport, or lifecycle
/// behavior beyond what the matching config field already does.
extension TugboatDeviceFarmConfig on TugboatReplayConfig {
  /// Returns `this` merged with [launchOptions] (read from the platform when
  /// omitted).
  ///
  /// * `enabled` becomes true when any launch capability is requested.
  /// * `emitSceneInventory` / `acceptActionContext` are OR-ed in.
  /// * `collector.baseUrl` is replaced only by a validated local URL in
  ///   non-release builds; release builds keep the configured endpoint.
  /// * Emits one `TUGBOAT_LAUNCH` debug line when launch capture is
  ///   requested so Device Farm log scraping can confirm the merge without
  ///   leaking tokens or URLs. Pass `logLaunch: false` to silence it.
  Future<TugboatReplayConfig> withDeviceFarmOverrides({
    TugboatLaunchOptions? launchOptions,
    bool? isRelease,
    String? buildCollectorBaseUrl,
    String? defaultLocalBaseUrl,
    bool logLaunch = true,
  }) async {
    final launch = launchOptions ?? await TugboatLaunchOptions.fromPlatform();
    final release = isRelease ?? kReleaseMode;
    var config = this;
    if (launch.captureRequested) {
      config = config.copyWith(
        enabled: true,
        emitSceneInventory: emitSceneInventory || launch.emitSceneInventory,
        acceptActionContext: acceptActionContext || launch.acceptActionContext,
      );
    }
    final currentCollector = config.collector;
    if (currentCollector != null) {
      final baseUrl = resolveTugboatCollectorBaseUrl(
        isRelease: release,
        productionBaseUrl: currentCollector.baseUrl,
        runtimeBaseUrl: launch.collectorBaseUrl,
        buildBaseUrl: buildCollectorBaseUrl,
        localFallbackBaseUrl: defaultLocalBaseUrl,
      );
      if (baseUrl != currentCollector.baseUrl) {
        config = config.copyWith(
          collector: currentCollector.withBaseUrl(baseUrl),
        );
      }
    }
    if (logLaunch && launch.captureRequested) {
      // No launch token, API key, or URL is included here.
      debugPrint('TUGBOAT_LAUNCH ${launch.toJson()}');
    }
    return config;
  }
}
