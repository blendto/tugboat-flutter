import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'capture_profile.dart';
import 'controller.dart';
import 'health.dart';
import 'input_capture.dart';
import 'lifecycle.dart';

export 'capture_profile.dart' show TugboatCaptureProfile;
export 'lifecycle.dart' show TugboatLifecycleState;
export 'screenshot_mask_level.dart' show TugboatScreenshotMaskLevel;
export 'markers.dart'
    show TugboatInternal, TugboatSensitive, TugboatSubView, TugboatTag;

/// Host-app entry point for Tugboat session capture.
///
/// Install [navigatorObserver] on [MaterialApp]/[CupertinoApp] and wrap the
/// app builder with [wrapApp]. Capture stays dormant until [activate] when
/// using [TugboatCaptureProfile.dormant].
///
/// [wrapApp] always mounts a lightweight activation gate so [activate] and
/// [deactivate] take effect without requiring an unrelated host rebuild.
class TugboatReplay {
  TugboatReplay._();

  static TugboatReplayController? _controller;
  static final GlobalKey _boundaryKey = GlobalKey(
    debugLabel: 'tugboat-capture-boundary',
  );
  static final TugboatNavigatorObserver navigatorObserver =
      TugboatNavigatorObserver();
  static final TugboatLifecycleNotifier _lifecycle =
      TugboatLifecycleNotifier();

  static TugboatReplayController? get controller => _controller;
  static GlobalKey get boundaryKey => _boundaryKey;
  static TugboatLifecycleNotifier get lifecycle => _lifecycle;
  static TugboatLifecycleState get lifecycleState => _lifecycle.state;
  static bool get isActivated => _lifecycle.isActivated;
  static String? get activationRequestId => _lifecycle.activationRequestId;

  /// Deprecated alias for [activationRequestId].
  static String? get activeSessionId => _lifecycle.activationRequestId;
  static TugboatCaptureProfile? get activeProfile => _lifecycle.activeProfile;

  /// When `true`, the SDK is fully inert (no capture, no wrapping overhead).
  ///
  /// Setting this to `true` tears down any active session. Intended for remote
  /// config or feature-flag kill switches.
  static bool get disabled => _lifecycle.disabled;

  static set disabled(bool value) {
    _lifecycle.setDisabled(value);
    if (value) {
      _controller?.dispose();
      _controller = null;
    }
  }

  /// Whether capture machinery is allowed to run ([disabled] is `false`).
  static bool get isEnabled => !_lifecycle.disabled;

  /// Enables capture machinery for dormant builds at runtime.
  ///
  /// Prefer [activationRequestId]; [sessionId] is retained for compatibility.
  static void activate({
    String? activationRequestId,
    @Deprecated('Use activationRequestId') String? sessionId,
    TugboatCaptureProfile profile = TugboatCaptureProfile.productionLean,
  }) {
    final requestId = activationRequestId ?? sessionId;
    if (requestId == null) {
      throw ArgumentError(
        'activate requires activationRequestId (or legacy sessionId)',
      );
    }
    _lifecycle.activate(activationRequestId: requestId, profile: profile);
  }

  /// Returns the SDK to dormant mode without tearing down the host app.
  static void deactivate() {
    _lifecycle.deactivate();
  }

  /// Current sanitized health snapshot (empty when no controller).
  static TugboatSdkHealth get health {
    final c = _controller;
    if (c != null) return c.healthSnapshot();
    return TugboatSdkHealth(
      lifecycle: _lifecycle.state.name,
      profile: (_lifecycle.activeProfile ?? TugboatCaptureProfile.dormant).name,
      activationRequestId: _lifecycle.activationRequestId,
    );
  }

  /// Wraps [child] with a lightweight activation gate.
  ///
  /// While dormant or disabled, the gate installs no capture machinery and
  /// preserves the host child. While active, it mounts session capture.
  static Widget wrapApp({
    required Widget child,
    TugboatReplayConfig config = const TugboatReplayConfig(),
  }) {
    if (_lifecycle.disabled) {
      return child;
    }
    return _TugboatActivationGate(config: config, child: child);
  }

  /// Clears any durable outbox entries (consent / logout).
  static Future<void> clearDurableOutbox() async {
    await _controller?.clearDurableOutbox();
  }

  /// Resets lifecycle state between tests.
  @visibleForTesting
  static void resetForTest() {
    _controller?.dispose();
    _controller = null;
    _lifecycle.resetForTest();
  }
}

class TugboatNavigatorObserver extends NavigatorObserver {
  void _syncContext() {
    if (TugboatReplay.disabled) return;
    TugboatReplay.controller?.navigatorContext = navigator?.context;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (TugboatReplay.disabled) return;
    _syncContext();
    TugboatReplay.controller?.route('route_push', route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (TugboatReplay.disabled) return;
    _syncContext();
    TugboatReplay.controller?.route('route_pop', previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (TugboatReplay.disabled) return;
    _syncContext();
    TugboatReplay.controller?.route('route_replace', newRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (TugboatReplay.disabled) return;
    _syncContext();
    TugboatReplay.controller?.route('route_remove', previousRoute);
  }
}

/// Always-mounted gate that mounts capture only while the lifecycle requests it.
class _TugboatActivationGate extends StatefulWidget {
  const _TugboatActivationGate({required this.config, required this.child});

  final TugboatReplayConfig config;
  final Widget child;

  @override
  State<_TugboatActivationGate> createState() => _TugboatActivationGateState();
}

class _TugboatActivationGateState extends State<_TugboatActivationGate> {
  late final VoidCallback _listener;
  int? _mountedEpoch;
  bool _captureMounted = false;

  @override
  void initState() {
    super.initState();
    _listener = _onLifecycle;
    TugboatReplay._lifecycle.addListener(_listener);
    _syncCaptureFlag();
  }

  @override
  void didUpdateWidget(covariant _TugboatActivationGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.profile != widget.config.profile) {
      _syncCaptureFlag();
    }
  }

  @override
  void dispose() {
    TugboatReplay._lifecycle.removeListener(_listener);
    super.dispose();
  }

  void _onLifecycle() {
    if (!mounted) return;
    _syncCaptureFlag();
  }

  void _syncCaptureFlag() {
    final lifecycle = TugboatReplay._lifecycle;
    final should = lifecycle.shouldCapture(widget.config.profile);
    final epoch = lifecycle.requestEpoch;

    if (!should) {
      if (_captureMounted) {
        setState(() {
          _captureMounted = false;
          _mountedEpoch = epoch;
        });
        // Tear-down completion is observed via capture root dispose.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (!_captureMounted) {
            lifecycle.markDormant(epoch);
          }
        });
      } else if (lifecycle.state == TugboatLifecycleState.stopping) {
        lifecycle.markDormant(epoch);
      }
      return;
    }

    // Capture requested.
    if (!_captureMounted || _mountedEpoch != epoch) {
      setState(() {
        _captureMounted = true;
        _mountedEpoch = epoch;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_captureMounted || TugboatReplay.disabled) {
      return widget.child;
    }
    final lifecycle = TugboatReplay._lifecycle;
    final profile = lifecycle.effectiveProfile(widget.config.profile);
    return _TugboatReplayRoot(
      key: ValueKey('tugboat-capture-$profile-${_mountedEpoch ?? 0}'),
      config: widget.config.copyWith(profile: profile),
      activationRequestId: lifecycle.activationRequestId,
      sessionEpoch: _mountedEpoch ?? lifecycle.requestEpoch,
      child: widget.child,
    );
  }
}

class _TugboatReplayRoot extends StatefulWidget {
  const _TugboatReplayRoot({
    super.key,
    required this.config,
    required this.child,
    this.activationRequestId,
    required this.sessionEpoch,
  });

  final TugboatReplayConfig config;
  final Widget child;
  final String? activationRequestId;
  final int sessionEpoch;

  @override
  State<_TugboatReplayRoot> createState() => _TugboatReplayRootState();
}

class _TugboatReplayRootState extends State<_TugboatReplayRoot>
    with WidgetsBindingObserver {
  static const _backgroundFlushDelay = Duration(milliseconds: 500);

  late final TugboatReplayController controller;
  InputCapture? inputCapture;
  Timer? _backgroundFlushTimer;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = TugboatReplayController(
      config: widget.config,
      boundaryKey: TugboatReplay._boundaryKey,
      activationRequestId: widget.activationRequestId,
      sessionEpoch: widget.sessionEpoch,
    );
    TugboatReplay._controller = controller;
    inputCapture = InputCapture(
      controller: controller,
      rootKey: TugboatReplay._boundaryKey,
    );
    _scheduleSessionStart();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _scheduleBackgroundFlush();
      case AppLifecycleState.resumed:
        _cancelBackgroundFlush();
      case AppLifecycleState.detached:
        _cancelBackgroundFlush();
        unawaited(controller.endSession());
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _scheduleBackgroundFlush() {
    _backgroundFlushTimer?.cancel();
    _backgroundFlushTimer = Timer(_backgroundFlushDelay, () {
      _backgroundFlushTimer = null;
      unawaited(controller.flushCapture());
    });
  }

  void _cancelBackgroundFlush() {
    _backgroundFlushTimer?.cancel();
    _backgroundFlushTimer = null;
  }

  void _scheduleSessionStart() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _started) return;
      final viewport = _captureViewportSize();
      if (viewport == null) {
        _scheduleSessionStart();
        return;
      }
      await controller.initialize();
      if (!mounted) return;
      controller.navigatorContext =
          TugboatReplay.navigatorObserver.navigator?.context;
      controller.start(viewport, Platform.isIOS ? 'ios' : 'android');
      _started = true;
      TugboatReplay._lifecycle.markActive(widget.sessionEpoch);
      if (widget.config.enableGlobalPointerCapture) {
        inputCapture?.install();
      }
    });
  }

  Size? _captureViewportSize() {
    final rootRender = TugboatReplay._boundaryKey.currentContext
        ?.findRenderObject();
    if (rootRender is RenderBox &&
        rootRender.hasSize &&
        rootRender.size.width > 0 &&
        rootRender.size.height > 0) {
      return rootRender.size;
    }
    final mediaSize = MediaQuery.maybeSizeOf(context);
    if (mediaSize != null && mediaSize.width > 0 && mediaSize.height > 0) {
      return mediaSize;
    }
    return null;
  }

  @override
  void dispose() {
    _cancelBackgroundFlush();
    WidgetsBinding.instance.removeObserver(this);
    inputCapture?.dispose();
    if (identical(TugboatReplay._controller, controller)) {
      TugboatReplay._controller = null;
    }
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = NotificationListener<Notification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          controller.recordScrollStart(
            scrollContext: notification.context,
            metrics: notification.metrics,
            depth: notification.depth,
          );
        } else if (notification is ScrollUpdateNotification) {
          controller.recordScrollUpdate(
            scrollContext: notification.context,
            metrics: notification.metrics,
          );
        } else if (notification is ScrollEndNotification) {
          controller.recordScrollEnd(
            scrollContext: notification.context,
            metrics: notification.metrics,
          );
        } else if (notification is OverscrollNotification) {
          controller.recordScrollOverscroll(
            scrollContext: notification.context,
          );
        }
        return false;
      },
      child: RepaintBoundary(
        key: TugboatReplay._boundaryKey,
        child: widget.child,
      ),
    );

    return Stack(
      children: [
        if (widget.config.enableGlobalPointerCapture)
          content
        else
          Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (event) => inputCapture?.handlePointerDown(event),
            onPointerMove: (event) => inputCapture?.handlePointerMove(event),
            onPointerUp: (event) => inputCapture?.handlePointerUp(event),
            onPointerCancel: (event) =>
                inputCapture?.handlePointerCancel(event),
            child: content,
          ),
      ],
    );
  }
}
