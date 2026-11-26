/// Masked screenshot capture and session evidence for Flutter apps.
///
/// ## Integrate capture
///
/// Import `package:tugboat/tugboat.dart`. Install [TugboatReplay.wrapApp] in
/// the app builder and [TugboatReplay.navigatorObserver] on the root Navigator.
/// Provide a separate [TugboatReplay.createNavigatorObserver] instance for
/// each nested Navigator whose transitions you want to record.
///
/// If the app already records session replay, disable that recorder before
/// enabling Tugboat. During a rollout, select one recorder per session to
/// avoid duplicate capture work and its impact on frame timing.
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:tugboat/tugboat.dart';
///
/// Widget buildApp(Widget home, TugboatCollectorConfig collector) {
///   return MaterialApp(
///     home: home,
///     navigatorObservers: [TugboatReplay.navigatorObserver],
///     builder: (_, child) => TugboatReplay.wrapApp(
///       child: child ?? const SizedBox.shrink(),
///       config: TugboatReplayConfig(enabled: true, collector: collector),
///     ),
///   );
/// }
/// ```
///
/// [TugboatReplayConfig.enabled] defaults to `false`. Use
/// [TugboatReplay.activate] and [TugboatReplay.deactivate] to control capture
/// at runtime. [TugboatCollectorHost.fromPlatform] builds a collector
/// configuration with app and device metadata.
///
/// ## Find the API for your task
///
/// - **Set screenshot privacy.** [TugboatReplayConfig.screenshotMaskLevel]
///   defaults to [TugboatScreenshotMaskLevel.allTextAndMedia]. Wrap widgets
///   that must always be masked in [TugboatSensitive].
/// - **Identify interaction targets.** Use Flutter controls or add `Semantics`
///   to custom controls. Tugboat uses available roles, actions, and bounds
///   for tap resolution. Use [TugboatTag] when automation needs an explicit
///   target alias and [TugboatSubView] for a named region. Fingerprint consumers
///   should scope comparisons to the same app build and fingerprint schema.
/// - **Observe app events or HTTP calls.** Use [TugboatReplay.eventHook] with a
///   [TugboatParameterPolicy] to control retained event parameters. Use
///   [TugboatReplay.beginNetworkCall] with an absolute route path, then call
///   [TugboatNetworkCall.complete] or [TugboatNetworkCall.fail].
/// - **Consume capture output.** See [TugboatSession], [TugboatEvent], and
///   [TugboatFrame] for captured data. Configure
///   [TugboatReplayConfig.sinkFactories] with [TugboatCaptureSinkFactory]
///   implementations to deliver live evidence to additional destinations.
/// - **Inspect capture health.** Read [TugboatReplay.health] for sanitized
///   lifecycle, sink, and screenshot budget diagnostics.
library;

export 'src/anchors.dart'
    show
        TugboatInventoryScroll,
        TugboatInventoryViewport,
        TugboatNormalizedBounds,
        TugboatSurface,
        TugboatSurfaceKind,
        TugboatTargetAnchor,
        TugboatViewportInsets,
        tugboatIconLabel,
        tugboatIconHash,
        tugboatLabelHash;
export 'src/capture_sink.dart'
    show
        TugboatCaptureSink,
        TugboatCaptureSinkFactory,
        TugboatCaptureSinkHub,
        TugboatSessionCaptureSink,
        TugboatSinkSessionContext,
        TugboatCaptureEnvelope,
        TugboatEnvelopeKind;
export 'src/collector_config.dart';
export 'src/collector_host.dart' show TugboatCollectorHost;
export 'src/controller.dart' show TugboatReplayController;
export 'src/health.dart'
    show
        TugboatSdkHealth,
        TugboatSinkHealth,
        TugboatScreenshotBudgetHealth,
        TugboatEvidenceHealth,
        TugboatSanitizedFailure;
export 'src/lifecycle.dart'
    show TugboatLifecycleState, TugboatLifecycleNotifier;
export 'src/interaction_transaction.dart'
    show tugboatDefaultReconciliationWindow;
export 'src/models.dart';
export 'src/external_event.dart'
    show
        TugboatEventHook,
        TugboatParameterPolicy,
        TugboatParameterCaptureMode,
        TugboatParameterLimits,
        TugboatParameterDrop;
export 'src/network_observer.dart'
    show
        TugboatNetworkCall,
        TugboatNetworkOutcome,
        TugboatNetworkFailure,
        TugboatNetworkLimits;
export 'src/coordinate_space.dart'
    show
        tugboatCaptureCoordinateVersion,
        TugboatCoordinateSourceSpace,
        TugboatCaptureCoordinate,
        buildCaptureCoordinate;
export 'src/replay_config.dart'
    show
        TugboatReplayConfig,
        TugboatViewportSemanticMode,
        TugboatViewportSemanticPolicy,
        TugboatScreenshotBudgetConfig,
        resolveViewportSemanticPolicy;
export 'src/launch_options.dart'
    show
        TugboatLaunchOptions,
        TugboatLaunchParsers,
        TugboatDeviceFarmConfig,
        resolveTugboatCollectorBaseUrl;
export 'src/screenshot_capture_backend.dart'
    show TugboatScreenshotCaptureBackend;
export 'src/tugboat.dart';
export 'src/screenshot_mask_level.dart' show TugboatScreenshotMaskLevel;
