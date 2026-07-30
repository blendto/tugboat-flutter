import 'capture_profile.dart';
import 'collector_config.dart';
import 'interaction_transaction.dart' show tugboatDefaultReconciliationWindow;
import 'models.dart';
import 'outbox/outbox.dart';
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
    this.budgetMicros = 80 * 1000,
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
    this.interactionClaimWindow = tugboatDefaultReconciliationWindow,
    this.interactionPublishMode = TugboatInteractionPublishMode.dualWrite,
    this.maxFrames = 500,
    this.maxEvents = 5000,
    this.scrollCaptureInterval = const Duration(seconds: 2),
    this.captureScrollSamples = false,
    this.capturePixelRatio = 0.75,
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
    this.outbox = TugboatOutboxConfig.disabled,
    this.screenshotBudget = TugboatScreenshotBudgetConfig.defaults,
  });

  final TugboatCaptureProfile profile;
  final Duration settleDelay;

  /// Released-tap window for delayed route/modal attribution.
  ///
  /// Default is [tugboatDefaultReconciliationWindow] (1,250 ms). Set to
  /// [Duration.zero] for microtask-only same-turn claims.
  final Duration interactionClaimWindow;

  /// Canonical vs legacy gesture publication policy.
  final TugboatInteractionPublishMode interactionPublishMode;

  bool get emitCanonicalInteractions =>
      interactionPublishMode != TugboatInteractionPublishMode.legacyOnly;

  bool get emitLegacyInteractionProjection =>
      interactionPublishMode != TugboatInteractionPublishMode.canonicalOnly;

  TugboatEventStream get legacyGestureStream =>
      interactionPublishMode == TugboatInteractionPublishMode.dualWrite
      ? TugboatEventStream.legacyProjection
      : TugboatEventStream.semantic;

  final int maxFrames;
  final int maxEvents;
  final Duration scrollCaptureInterval;
  final bool captureScrollSamples;
  final double capturePixelRatio;
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
  final TugboatOutboxConfig outbox;
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
    Duration? interactionClaimWindow,
    TugboatInteractionPublishMode? interactionPublishMode,
    int? maxFrames,
    int? maxEvents,
    Duration? scrollCaptureInterval,
    bool? captureScrollSamples,
    double? capturePixelRatio,
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
    TugboatOutboxConfig? outbox,
    TugboatScreenshotBudgetConfig? screenshotBudget,
  }) {
    return TugboatReplayConfig(
      profile: profile ?? this.profile,
      settleDelay: settleDelay ?? this.settleDelay,
      interactionClaimWindow:
          interactionClaimWindow ?? this.interactionClaimWindow,
      interactionPublishMode:
          interactionPublishMode ?? this.interactionPublishMode,
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
      outbox: outbox ?? this.outbox,
      screenshotBudget: screenshotBudget ?? this.screenshotBudget,
    );
  }
}
