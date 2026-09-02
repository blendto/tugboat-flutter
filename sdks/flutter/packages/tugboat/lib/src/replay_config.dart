import 'collector_config.dart';
import 'interaction_transaction.dart' show tugboatDefaultReconciliationWindow;
import 'screenshot_capture_backend.dart';
import 'screenshot_mask_level.dart';
import 'sinks/capture_sink.dart' show TugboatCaptureSinkFactory;
import 'viewport_semantic_mode.dart';

export 'viewport_semantic_mode.dart' show TugboatViewportSemanticMode;

/// Resolved viewport-semantics capabilities for the controller.
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
  required TugboatViewportSemanticMode mode,
  bool emitEvents = false,
}) {
  if (mode == TugboatViewportSemanticMode.off) {
    return TugboatViewportSemanticPolicy.off;
  }
  final verboseMode =
      mode == TugboatViewportSemanticMode.full ||
      mode == TugboatViewportSemanticMode.fullWithDebugLogs;
  final shouldEmitEvents = emitEvents && verboseMode;
  final debugLogs =
      emitEvents && mode == TugboatViewportSemanticMode.fullWithDebugLogs;

  return TugboatViewportSemanticPolicy(
    engineEnabled: true,
    emitEvents: shouldEmitEvents,
    debugLogs: debugLogs,
    holdPersistentSemanticsHandle: emitEvents,
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
    this.enabled = false,
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
    this.degradedCaptureScale = 0.80,
    this.enableGlobalPointerCapture = true,
    this.emitSceneInventory = false,
    this.emitViewportSemanticMap = false,
    this.emitCaptureDiagnostics = false,
    this.acceptActionContext = false,
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
    this.screenshotCaptureBackend =
        TugboatScreenshotCaptureBackend.flutterRepaintBoundary,
  }) : assert(capturePixelRatio > 0),
       assert(captureMaxWidth == null || captureMaxWidth > 0),
       assert(captureMaxHeight == null || captureMaxHeight > 0),
       assert(degradedCaptureScale > 0 && degradedCaptureScale <= 1);

  /// Whether the normal privacy-safe capture lifecycle starts with the app.
  ///
  /// [TugboatReplay.activate] can start a disabled configuration at runtime.
  final bool enabled;
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
  /// Most applications should keep this false and retain scroll
  /// metrics instead; a single deferred scroll-end frame is cheaper and more
  /// coherent than repeated full-screen readbacks during scrolling.
  final bool captureScrollScreenshots;
  final double capturePixelRatio;
  final int? captureMaxWidth;
  final int? captureMaxHeight;

  /// Additional scale applied while the rolling screenshot budget is degraded.
  final double degradedCaptureScale;
  final bool enableGlobalPointerCapture;

  /// Allows bounded `scene_inventory` events for this app launch.
  final bool emitSceneInventory;

  /// Allows bounded viewport semantic-map events for this app launch.
  final bool emitViewportSemanticMap;

  /// Allows bounded capture diagnostic events for this app launch.
  final bool emitCaptureDiagnostics;

  /// Allows the host to attach external action context to captured events.
  final bool acceptActionContext;

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

  /// Pixel backend. [TugboatScreenshotCaptureBackend.flutterRepaintBoundary]
  /// is the supported default. Native CPU capture is experimental opt-in.
  final TugboatScreenshotCaptureBackend screenshotCaptureBackend;

  TugboatScreenshotMaskLevel get effectiveScreenshotMaskLevel =>
      screenshotMaskLevel ?? TugboatScreenshotMaskLevel.allTextAndMedia;

  bool get sceneInventoryEmissionEnabled => emitSceneInventory;

  bool get semanticMapEmissionEnabled => viewportSemanticPolicy.emitEvents;

  bool get actionContextEnabled => acceptActionContext;

  TugboatViewportSemanticPolicy get viewportSemanticPolicy =>
      resolveViewportSemanticPolicy(
        mode: viewportSemanticMode,
        emitEvents: emitViewportSemanticMap,
      );

  TugboatReplayConfig copyWith({
    bool? enabled,
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
    bool? emitSceneInventory,
    bool? emitViewportSemanticMap,
    bool? emitCaptureDiagnostics,
    bool? acceptActionContext,
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
    TugboatScreenshotCaptureBackend? screenshotCaptureBackend,
  }) {
    return TugboatReplayConfig(
      enabled: _or(enabled, this.enabled),
      settleDelay: _or(settleDelay, this.settleDelay),
      scrollEndCaptureDelay: _or(
        scrollEndCaptureDelay,
        this.scrollEndCaptureDelay,
      ),
      interactionClaimWindow: _or(
        interactionClaimWindow,
        this.interactionClaimWindow,
      ),
      maxFrames: _or(maxFrames, this.maxFrames),
      maxEvents: _or(maxEvents, this.maxEvents),
      scrollCaptureInterval: _or(
        scrollCaptureInterval,
        this.scrollCaptureInterval,
      ),
      captureScrollSamples: _or(
        captureScrollSamples,
        this.captureScrollSamples,
      ),
      captureScrollScreenshots: _or(
        captureScrollScreenshots,
        this.captureScrollScreenshots,
      ),
      capturePixelRatio: _or(capturePixelRatio, this.capturePixelRatio),
      captureMaxWidth: clearCaptureMaxWidth
          ? null
          : _or(captureMaxWidth, this.captureMaxWidth),
      captureMaxHeight: clearCaptureMaxHeight
          ? null
          : _or(captureMaxHeight, this.captureMaxHeight),
      degradedCaptureScale: _or(
        degradedCaptureScale,
        this.degradedCaptureScale,
      ),
      enableGlobalPointerCapture: _or(
        enableGlobalPointerCapture,
        this.enableGlobalPointerCapture,
      ),
      emitSceneInventory: _or(emitSceneInventory, this.emitSceneInventory),
      emitViewportSemanticMap: _or(
        emitViewportSemanticMap,
        this.emitViewportSemanticMap,
      ),
      emitCaptureDiagnostics: _or(
        emitCaptureDiagnostics,
        this.emitCaptureDiagnostics,
      ),
      acceptActionContext: _or(acceptActionContext, this.acceptActionContext),
      explorationCollectorUrl: _or(
        explorationCollectorUrl,
        this.explorationCollectorUrl,
      ),
      explorationRunId: _or(explorationRunId, this.explorationRunId),
      userId: _or(userId, this.userId),
      appInfo: _or(appInfo, this.appInfo),
      collector: _or(collector, this.collector),
      screenshotMaskLevel: _or(screenshotMaskLevel, this.screenshotMaskLevel),
      widgetNames: _or(widgetNames, this.widgetNames),
      viewportSemanticMode: _or(
        viewportSemanticMode,
        this.viewportSemanticMode,
      ),
      viewportSemanticMapMaxNodes: _or(
        viewportSemanticMapMaxNodes,
        this.viewportSemanticMapMaxNodes,
      ),
      viewportSemanticMapMaxBytes: _or(
        viewportSemanticMapMaxBytes,
        this.viewportSemanticMapMaxBytes,
      ),
      sinkFactories: _or(sinkFactories, this.sinkFactories),
      screenshotBudget: _or(screenshotBudget, this.screenshotBudget),
      screenshotCaptureBackend: _or(
        screenshotCaptureBackend,
        this.screenshotCaptureBackend,
      ),
    );
  }
}

T _or<T>(T? override, T current) => override ?? current;
