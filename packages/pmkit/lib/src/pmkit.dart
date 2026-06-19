import 'dart:io';

import 'package:flutter/material.dart';

import 'capture_profile.dart';
import 'controller.dart';
import 'input_capture.dart';

export 'capture_profile.dart' show PmkitCaptureProfile;
export 'screenshot_mask_level.dart' show PmkitScreenshotMaskLevel;
export 'markers.dart'
    show PmkitInternal, PmkitSensitive, PmkitSubView, PmkitTag;

class PmkitReplay {
  PmkitReplay._();

  static PmkitReplayController? _controller;
  static final GlobalKey _boundaryKey = GlobalKey(
    debugLabel: 'pmkit-capture-boundary',
  );
  static final PmkitNavigatorObserver navigatorObserver =
      PmkitNavigatorObserver();

  static bool _activated = false;
  static String? _activeSessionId;
  static PmkitCaptureProfile? _activeProfile;

  static PmkitReplayController? get controller => _controller;
  static GlobalKey get boundaryKey => _boundaryKey;
  static bool get isActivated => _activated;
  static String? get activeSessionId => _activeSessionId;
  static PmkitCaptureProfile? get activeProfile => _activeProfile;

  /// Enables capture machinery for dormant builds at runtime.
  static void activate({
    required String sessionId,
    PmkitCaptureProfile profile = PmkitCaptureProfile.productionLean,
  }) {
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

  static Widget wrapApp({
    required Widget child,
    PmkitReplayConfig config = const PmkitReplayConfig(),
  }) {
    final effectiveProfile = _activeProfile ?? config.profile;
    if (effectiveProfile == PmkitCaptureProfile.dormant && !_activated) {
      return child;
    }
    return _PmkitReplayRoot(
      config: config.copyWith(profile: effectiveProfile),
      child: child,
    );
  }
}

class PmkitNavigatorObserver extends NavigatorObserver {
  void _syncContext() {
    PmkitReplay.controller?.navigatorContext = navigator?.context;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _syncContext();
    PmkitReplay.controller?.route('route_push', route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _syncContext();
    PmkitReplay.controller?.route('route_pop', previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _syncContext();
    PmkitReplay.controller?.route('route_replace', newRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _syncContext();
    PmkitReplay.controller?.route('route_remove', previousRoute);
  }
}

class _PmkitReplayRoot extends StatefulWidget {
  const _PmkitReplayRoot({required this.config, required this.child});

  final PmkitReplayConfig config;
  final Widget child;

  @override
  State<_PmkitReplayRoot> createState() => _PmkitReplayRootState();
}

class _PmkitReplayRootState extends State<_PmkitReplayRoot> {
  late final PmkitReplayController controller;
  InputCapture? inputCapture;

  @override
  void initState() {
    super.initState();
    controller = PmkitReplayController(
      config: widget.config,
      boundaryKey: PmkitReplay._boundaryKey,
    );
    PmkitReplay._controller = controller;
    inputCapture = InputCapture(
      controller: controller,
      rootKey: PmkitReplay._boundaryKey,
    );
    _scheduleSessionStart();
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
          PmkitReplay.navigatorObserver.navigator?.context;
      controller.start(viewport, Platform.isIOS ? 'ios' : 'android');
      if (widget.config.enableGlobalPointerCapture) {
        inputCapture?.install();
      }
    });
  }

  Size? _captureViewportSize() {
    final rootRender = PmkitReplay._boundaryKey.currentContext
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
    inputCapture?.dispose();
    if (identical(PmkitReplay._controller, controller)) {
      PmkitReplay._controller = null;
    }
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          controller.recordScrollStart(notification.metrics.pixels);
          inputCapture?.onScrollStart(notification.dragDetails?.globalPosition);
        } else if (notification is ScrollUpdateNotification &&
            controller.scrolling) {
          controller.recordScrollSample(notification.metrics.pixels);
        } else if (notification is ScrollEndNotification) {
          inputCapture?.onScrollEnd(null);
          controller.recordScrollEnd(notification.metrics.pixels);
        }
        return false;
      },
      child: RepaintBoundary(
        key: PmkitReplay._boundaryKey,
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
            onPointerDown: (event) =>
                controller.recordPointerDown(event.position),
            onPointerUp: (event) => controller.recordPointerUp(event.position),
            child: content,
          ),
      ],
    );
  }
}
