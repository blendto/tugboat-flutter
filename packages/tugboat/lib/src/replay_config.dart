import 'capture_profile.dart';
import 'collector_config.dart';
import 'interaction_transaction.dart' show tugboatDefaultReconciliationWindow;
import 'screenshot_mask_level.dart';
import 'sinks/capture_sink.dart' show TugboatCaptureSinkFactory;
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

  final bool engineEnabled;
  final bool emitEvents;
  final bool debugLogs;
  final bool holdPersistentSemanticsHandle;
}

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

  final exploration = profile == TugboatCaptureProfile.exploration;
  final production = profile == TugboatCaptureProfile.productionLean;
  if (!exploration && !production) {
    return TugboatViewportSemanticPolicy.off;
  }

  final verboseMode =
      mode == TugboatViewportSemanticMode.full ||
      mode == TugboatViewportSemanticMode.fullWithDebugLogs;
  final emitEvents = exploration && verboseMode;
  final debugLogs =
      exploration && mode == TugboatViewportSemanticMode.fullWithDebugLogs;

  return TugboatViewportSemanticPolicy(
    engineEnabled: true,
    emitEvents: emitEvents,
    debugLogs: debugLogs,
    holdPersistentSemanticsHandle: exploration,
  );
}

class TugboatScreenshotBudgetConfig {
  const TugboatScreenshotBudgetConfig({
    this.window = const Duration(seconds: 5),
    // 60ms / 5s: engage eligible-capture skipping sooner under load now that
    // post-capture state-signature short circuit no longer filters work.
    this.budgetMicros = 60 * 1000,
    this.skipEligibleWhenDegraded = true,
  });

  final Duration window;
  final int budgetMicros;
  final bool skipEligibleWhenDegraded;

  static const defaults = TugboatScreenshotBudgetConfig();
}

/// Capture session configuration.
class TugboatReplayConfig {
  const TugboatReplayConfig({
    this.profile = TugboatCaptureProfile.dormant,
    this.settleDelay = const Duration(seconds: 1),
    this.scrollEndCaptureDelay = Duration.zero,
    this.interactionClaimWindow = tugboatDefaultReconciliationWindow,
    this.maxFrames = 500,
    this.maxEvents = 5000,
    this.scrollCaptureInterval = const Duration(seconds: 2),
    this.captureScrollSamples = false,
    this.captureScrollScreenshots = false,
    this.capturePixelRatio = 0.75,
    this.captureMaxWidth,
    this.captureMaxHeight,
    this.degradedCaptureScale = 0.67,
    this.enableGlobalPointerCapture = true,
    this.explorationCollectorUrl,
    this.explorationRunId,
    this.userId,
    this.appInfo,
    this.collector,
    this.screenshotMaskLevel,
    this.widgetNames = const {},
    this.viewportSemanticMode = TugboatViewportSemanticMode.tapResolutionOnly,
    this.viewportSemanticMapMaxNodes = 120,
    this.viewportSemanticMapMaxBytes = 48000,
    this.sinkFactories = const [],
    this.screenshotBudget = TugboatScreenshotBudgetConfig.defaults,
  }) : assert(capturePixelRatio > 0 && capturePixelRatio <= 1),
       assert(captureMaxWidth == null || captureMaxWidth > 0),
       assert(captureMaxHeight == null || captureMaxHeight > 0),
       assert(degradedCaptureScale > 0 && degradedCaptureScale <= 1);

  final TugboatCaptureProfile profile;
  final Duration settleDelay;

  /// Delay before the optional visual observation taken after a scroll ends.
  /// This runs outside the controller queue so route and pointer work remain
  /// responsive while the scroll settles.
  final Duration scrollEndCaptureDelay;

  /// Released-tap window for delayed route/modal attribution.
  ///
  /// Default is [tugboatDefaultReconciliationWindow] (1,250 ms). Set to
  /// [Duration.zero] for microtask-only same-turn claims.
  final Duration interactionClaimWindow;

  final int maxFrames;
  final int maxEvents;
  final Duration scrollCaptureInterval;
  final bool captureScrollSamples;

  /// Whether to request visual checkpoints while a scroll is in progress.
  /// Production profiles should normally keep this false and retain scroll
  /// metrics instead; a single deferred scroll-end frame is cheaper and more
  /// coherent than repeated full-screen readbacks during scrolling.
  final bool captureScrollScreenshots;
  final double capturePixelRatio;
  final int? captureMaxWidth;
  final int? captureMaxHeight;

  /// Additional scale applied while the rolling screenshot budget is degraded.
  final double degradedCaptureScale;
  final bool enableGlobalPointerCapture;
  final String? explorationCollectorUrl;
  final String? explorationRunId;
  final String? userId;
  final TugboatCollectorAppInfo? appInfo;
  final TugboatCollectorConfig? collector;
  final TugboatScreenshotMaskLevel? screenshotMaskLevel;
  final Map<Type, String> widgetNames;
  final TugboatViewportSemanticMode viewportSemanticMode;
  final int viewportSemanticMapMaxNodes;
  final int viewportSemanticMapMaxBytes;
  final List<TugboatCaptureSinkFactory> sinkFactories;
  final TugboatScreenshotBudgetConfig screenshotBudget;

  TugboatScreenshotMaskLevel get effectiveScreenshotMaskLevel =>
      screenshotMaskLevel ??
      switch (profile) {
        TugboatCaptureProfile.productionLean =>
          TugboatScreenshotMaskLevel.allTextAndMedia,
        TugboatCaptureProfile.dormant || TugboatCaptureProfile.exploration =>
          TugboatScreenshotMaskLevel.explicitOnly,
      };

  TugboatViewportSemanticPolicy get viewportSemanticPolicy =>
      resolveViewportSemanticPolicy(
        profile: profile,
        mode: viewportSemanticMode,
      );

  TugboatReplayConfig copyWith({
    TugboatCaptureProfile? profile,
    Duration? settleDelay,
    Duration? scrollEndCaptureDelay,
    Duration? interactionClaimWindow,
    int? maxFrames,
    int? maxEvents,
    Duration? scrollCaptureInterval,
    bool? captureScrollSamples,
    bool? captureScrollScreenshots,
    double? capturePixelRatio,
    int? captureMaxWidth,
    int? captureMaxHeight,
    bool clearCaptureMaxWidth = false,
    bool clearCaptureMaxHeight = false,
    double? degradedCaptureScale,
    bool? enableGlobalPointerCapture,
    String? explorationCollectorUrl,
    String? explorationRunId,
    String? userId,
    TugboatCollectorAppInfo? appInfo,
    TugboatCollectorConfig? collector,
    TugboatScreenshotMaskLevel? screenshotMaskLevel,
    Map<Type, String>? widgetNames,
    TugboatViewportSemanticMode? viewportSemanticMode,
    int? viewportSemanticMapMaxNodes,
    int? viewportSemanticMapMaxBytes,
    List<TugboatCaptureSinkFactory>? sinkFactories,
    TugboatScreenshotBudgetConfig? screenshotBudget,
  }) {
    return TugboatReplayConfig(
      profile: profile ?? this.profile,
      settleDelay: settleDelay ?? this.settleDelay,
      scrollEndCaptureDelay:
          scrollEndCaptureDelay ?? this.scrollEndCaptureDelay,
      interactionClaimWindow:
          interactionClaimWindow ?? this.interactionClaimWindow,
      maxFrames: maxFrames ?? this.maxFrames,
      maxEvents: maxEvents ?? this.maxEvents,
      scrollCaptureInterval:
          scrollCaptureInterval ?? this.scrollCaptureInterval,
      captureScrollSamples: captureScrollSamples ?? this.captureScrollSamples,
      captureScrollScreenshots:
          captureScrollScreenshots ?? this.captureScrollScreenshots,
      capturePixelRatio: capturePixelRatio ?? this.capturePixelRatio,
      captureMaxWidth: clearCaptureMaxWidth
          ? null
          : captureMaxWidth ?? this.captureMaxWidth,
      captureMaxHeight: clearCaptureMaxHeight
          ? null
          : captureMaxHeight ?? this.captureMaxHeight,
      degradedCaptureScale: degradedCaptureScale ?? this.degradedCaptureScale,
      enableGlobalPointerCapture:
          enableGlobalPointerCapture ?? this.enableGlobalPointerCapture,
      explorationCollectorUrl:
          explorationCollectorUrl ?? this.explorationCollectorUrl,
      explorationRunId: explorationRunId ?? this.explorationRunId,
      userId: userId ?? this.userId,
      appInfo: appInfo ?? this.appInfo,
      collector: collector ?? this.collector,
      screenshotMaskLevel: screenshotMaskLevel ?? this.screenshotMaskLevel,
      widgetNames: widgetNames ?? this.widgetNames,
      viewportSemanticMode: viewportSemanticMode ?? this.viewportSemanticMode,
      viewportSemanticMapMaxNodes:
          viewportSemanticMapMaxNodes ?? this.viewportSemanticMapMaxNodes,
      viewportSemanticMapMaxBytes:
          viewportSemanticMapMaxBytes ?? this.viewportSemanticMapMaxBytes,
      sinkFactories: sinkFactories ?? this.sinkFactories,
      screenshotBudget: screenshotBudget ?? this.screenshotBudget,
    );
  }
}
