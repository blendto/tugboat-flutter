import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'capture_profile.dart';
import 'controller.dart';
import 'input_capture.dart';

export 'capture_profile.dart' show TugboatCaptureProfile;
export 'screenshot_mask_level.dart' show TugboatScreenshotMaskLevel;
export 'markers.dart'
    show TugboatInternal, TugboatSensitive, TugboatSubView, TugboatTag;

/// Host-app entry point for Tugboat session capture.
///
/// Install [navigatorObserver] on [MaterialApp]/[CupertinoApp] and wrap the
/// app builder with [wrapApp]. Capture stays dormant until [activate] when
/// using [TugboatCaptureProfile.dormant].
class TugboatReplay {
  TugboatReplay._();

  static TugboatReplayController? _controller;
  static final GlobalKey _boundaryKey = GlobalKey(
    debugLabel: 'tugboat-capture-boundary',
  );
  static final TugboatNavigatorObserver navigatorObserver =
      TugboatNavigatorObserver();

  static bool _activated = false;
  static String? _activeSessionId;
  static TugboatCaptureProfile? _activeProfile;
  static bool _disabled = false;

  static TugboatReplayController? get controller => _controller;
  static GlobalKey get boundaryKey => _boundaryKey;
  static bool get isActivated => _activated;
  static String? get activeSessionId => _activeSessionId;
  static TugboatCaptureProfile? get activeProfile => _activeProfile;

  /// When `true`, the SDK is fully inert (no capture, no wrapping overhead).
  ///
  /// Setting this to `true` tears down any active session. Intended for remote
  /// config or feature-flag kill switches.
  static bool get disabled => _disabled;

  static set disabled(bool value) {
    if (value == _disabled) return;
    _disabled = value;
    if (value) {
      deactivate();
    }
  }

  /// Whether capture machinery is allowed to run ([disabled] is `false`).
  static bool get isEnabled => !_disabled;

  /// Enables capture machinery for dormant builds at runtime.
  static void activate({
    required String sessionId,
    TugboatCaptureProfile profile = TugboatCaptureProfile.productionLean,
  }) {
    if (_disabled) return;
    _activated = true;
    _activeSessionId = sessionId;
    _activeProfile = profile;
  }

  /// Returns the SDK to dormant mode without tearing down the host app.
  static void deactivate() {
    _activated = false;
    _activeSessionId = null;
    _activeProfile = null;
    _controller?.dispose();
    _controller = null;
  }

  /// Wraps [child] with capture plumbing (repaint boundary, scroll listener).
  ///
  /// Returns [child] unchanged when the profile is dormant and [activate] has
  /// not been called.
  static Widget wrapApp({
    required Widget child,
    TugboatReplayConfig config = const TugboatReplayConfig(),
  }) {
    if (_disabled) {
      return child;
    }
    final effectiveProfile = _activeProfile ?? config.profile;
    if (effectiveProfile == TugboatCaptureProfile.dormant && !_activated) {
      return child;
    }
    return _TugboatReplayRoot(
      config: config.copyWith(profile: effectiveProfile),
      child: child,
    );
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

class _TugboatReplayRoot extends StatefulWidget {
  const _TugboatReplayRoot({required this.config, required this.child});

  final TugboatReplayConfig config;
  final Widget child;

  @override
  State<_TugboatReplayRoot> createState() => _TugboatReplayRootState();
}

class _TugboatReplayRootState extends State<_TugboatReplayRoot>
    with WidgetsBindingObserver {
  static const _backgroundFlushDelay = Duration(milliseconds: 500);

  late final TugboatReplayController controller;
  InputCapture? inputCapture;
  Timer? _backgroundFlushTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = TugboatReplayController(
      config: widget.config,
      boundaryKey: TugboatReplay._boundaryKey,
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
      if (!mounted) return;
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
