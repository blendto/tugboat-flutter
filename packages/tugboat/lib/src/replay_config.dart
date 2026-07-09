import 'capture_profile.dart';
import 'collector_config.dart';
import 'screenshot_mask_level.dart';
import 'viewport_semantic_mode.dart';

export 'viewport_semantic_mode.dart' show TugboatViewportSemanticMode;

/// Resolved viewport-semantics capabilities from [TugboatCaptureProfile] +
/// [TugboatViewportSemanticMode]. Single source of truth for the controller.
class TugboatViewportSemanticPolicy {
  const TugboatViewportSemanticPolicy({
    required this.engineEnabled,
    required this.emitEvents,
    required this.debugLogs,
    required this.holdPersistentSemanticsHandle,
  });

  static const off = TugboatViewportSemanticPolicy(
    engineEnabled: false,
    emitEvents: false,
    debugLogs: false,
    holdPersistentSemanticsHandle: false,
  );

  /// Whether maps are built (for tap resolution and/or emission).
  final bool engineEnabled;

  /// Whether `viewport_semantic_map` / `scroll_semantic_snapshot` events emit.
  final bool emitEvents;

  /// Whether diagnostic prints are enabled.
  final bool debugLogs;

  /// Hold Flutter [SemanticsHandle] for the whole session (exploration only).
  final bool holdPersistentSemanticsHandle;
}

/// Derives [TugboatViewportSemanticPolicy] from profile + mode.
///
/// Matrix:
/// - dormant: always off
/// - exploration + off: off
/// - exploration + tapResolutionOnly: engine, no emit
/// - exploration + full / fullWithDebugLogs: engine + emit (+ debug for latter)
/// - productionLean + off: off
/// - productionLean + tapResolutionOnly: engine, no emit, transient semantics
/// - productionLean + full / fullWithDebugLogs: engine + emit, transient semantics
TugboatViewportSemanticPolicy resolveViewportSemanticPolicy({
  required TugboatCaptureProfile profile,
  required TugboatViewportSemanticMode mode,
}) {
  if (mode == TugboatViewportSemanticMode.off) {
    return TugboatViewportSemanticPolicy.off;
  }
  if (profile == TugboatCaptureProfile.dormant) {
    return TugboatViewportSemanticPolicy.off;
  }

  final emitEvents =
      mode == TugboatViewportSemanticMode.full ||
      mode == TugboatViewportSemanticMode.fullWithDebugLogs;
  final debugLogs = mode == TugboatViewportSemanticMode.fullWithDebugLogs;
  final exploration = profile == TugboatCaptureProfile.exploration;
  final production = profile == TugboatCaptureProfile.productionLean;
  if (!exploration && !production) {
    return TugboatViewportSemanticPolicy.off;
  }

  return TugboatViewportSemanticPolicy(
    engineEnabled: true,
    emitEvents: emitEvents,
    debugLogs: debugLogs,
    holdPersistentSemanticsHandle: exploration,
  );
}

/// Capture session configuration.
class TugboatReplayConfig {
  const TugboatReplayConfig({
    this.profile = TugboatCaptureProfile.dormant,
    this.settleDelay = const Duration(seconds: 1),
    this.maxFrames = 500,
    this.maxEvents = 5000,
    this.scrollCaptureInterval = const Duration(seconds: 2),
    this.captureScrollSamples = false,
    this.capturePixelRatio = 0.75,
    this.enableGlobalPointerCapture = true,
    this.explorationCollectorUrl,
    this.explorationRunId,
    this.appInfo,
    this.collector,
    this.screenshotMaskLevel,

    /// Optional Type→name overrides for canonical paths (e.g. obfuscated builds).
    this.widgetNames = const {},
    this.viewportSemanticMode = TugboatViewportSemanticMode.tapResolutionOnly,
    this.viewportSemanticMapMaxNodes = 120,
    this.viewportSemanticMapMaxBytes = 48000,
  });

  final TugboatCaptureProfile profile;
  final Duration settleDelay;
  final int maxFrames;
  final int maxEvents;
  final Duration scrollCaptureInterval;
  final bool captureScrollSamples;
  final double capturePixelRatio;
  final bool enableGlobalPointerCapture;
  final String? explorationCollectorUrl;
  final String? explorationRunId;
  final TugboatCollectorAppInfo? appInfo;
  final TugboatCollectorConfig? collector;
  final TugboatScreenshotMaskLevel? screenshotMaskLevel;
  final Map<Type, String> widgetNames;
  final TugboatViewportSemanticMode viewportSemanticMode;
  final int viewportSemanticMapMaxNodes;
  final int viewportSemanticMapMaxBytes;

  TugboatScreenshotMaskLevel get effectiveScreenshotMaskLevel =>
      screenshotMaskLevel ??
      switch (profile) {
        TugboatCaptureProfile.productionLean =>
          TugboatScreenshotMaskLevel.allTextAndMedia,
        TugboatCaptureProfile.dormant || TugboatCaptureProfile.exploration =>
          TugboatScreenshotMaskLevel.explicitOnly,
      };

  /// Policy for building / emitting viewport semantic maps.
  TugboatViewportSemanticPolicy get viewportSemanticPolicy =>
      resolveViewportSemanticPolicy(
        profile: profile,
        mode: viewportSemanticMode,
      );

  TugboatReplayConfig copyWith({
    TugboatCaptureProfile? profile,
    Duration? settleDelay,
    int? maxFrames,
    int? maxEvents,
    Duration? scrollCaptureInterval,
    bool? captureScrollSamples,
    double? capturePixelRatio,
    bool? enableGlobalPointerCapture,
    String? explorationCollectorUrl,
    String? explorationRunId,
    TugboatCollectorAppInfo? appInfo,
    TugboatCollectorConfig? collector,
    TugboatScreenshotMaskLevel? screenshotMaskLevel,
    Map<Type, String>? widgetNames,
    TugboatViewportSemanticMode? viewportSemanticMode,
    int? viewportSemanticMapMaxNodes,
    int? viewportSemanticMapMaxBytes,
  }) {
    return TugboatReplayConfig(
      profile: profile ?? this.profile,
      settleDelay: settleDelay ?? this.settleDelay,
      maxFrames: maxFrames ?? this.maxFrames,
      maxEvents: maxEvents ?? this.maxEvents,
      scrollCaptureInterval:
          scrollCaptureInterval ?? this.scrollCaptureInterval,
      captureScrollSamples: captureScrollSamples ?? this.captureScrollSamples,
      capturePixelRatio: capturePixelRatio ?? this.capturePixelRatio,
      enableGlobalPointerCapture:
          enableGlobalPointerCapture ?? this.enableGlobalPointerCapture,
      explorationCollectorUrl:
          explorationCollectorUrl ?? this.explorationCollectorUrl,
      explorationRunId: explorationRunId ?? this.explorationRunId,
      appInfo: appInfo ?? this.appInfo,
      collector: collector ?? this.collector,
      screenshotMaskLevel: screenshotMaskLevel ?? this.screenshotMaskLevel,
      widgetNames: widgetNames ?? this.widgetNames,
      viewportSemanticMode: viewportSemanticMode ?? this.viewportSemanticMode,
      viewportSemanticMapMaxNodes:
          viewportSemanticMapMaxNodes ?? this.viewportSemanticMapMaxNodes,
      viewportSemanticMapMaxBytes:
          viewportSemanticMapMaxBytes ?? this.viewportSemanticMapMaxBytes,
    );
  }
}
