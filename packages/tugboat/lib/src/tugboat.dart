import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'capture_boundary.dart';
import 'capture_profile.dart';
import 'controller.dart';
import 'external_event.dart';
import 'health.dart';
import 'input_capture.dart';
import 'lifecycle.dart';
import 'models.dart';
import 'network_observer.dart';

export 'capture_profile.dart' show TugboatCaptureProfile;
export 'lifecycle.dart' show TugboatLifecycleState;
export 'screenshot_mask_level.dart' show TugboatScreenshotMaskLevel;
export 'markers.dart'
    show TugboatInternal, TugboatSensitive, TugboatSubView, TugboatTag;

typedef TugboatControllerTestHook =
    void Function(TugboatReplayController controller);

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

  /// Process-local identity retained across controller mount/unmount.
  static Map<String, dynamic>? _pendingTraits;
  static String? _pendingTraitsId;
  static String? _pendingUserId;
  static bool _pendingUserIdSet = false;
  static TugboatLocaleInfo? _localeOverride;

  /// Convenience root [NavigatorObserver]. Prefer this for the app's primary
  /// Navigator.
  static final TugboatNavigatorObserver navigatorObserver =
      TugboatNavigatorObserver();

  /// Creates a dedicated observer for a nested [Navigator].
  ///
  /// Flutter does not safely auto-discover nested Navigators; install one
  /// observer instance per Navigator whose transitions must be attributed.
  static TugboatNavigatorObserver createNavigatorObserver() =>
      TugboatNavigatorObserver();
  static final TugboatLifecycleNotifier _lifecycle = TugboatLifecycleNotifier();

  /// Installs deterministic controller seams before its first post-frame
  /// session start. This exists only for widget tests: production callers
  /// never configure a controller before capture begins.
  @visibleForTesting
  static TugboatControllerTestHook? debugConfigureControllerForTest;

  static TugboatReplayController? get controller => _controller;
  static GlobalKey get boundaryKey => _boundaryKey;
  static TugboatLifecycleNotifier get lifecycle => _lifecycle;
  static TugboatLifecycleState get lifecycleState => _lifecycle.state;
  static bool get isActivated => _lifecycle.isActivated;
  static String? get activationRequestId => _lifecycle.activationRequestId;

  static TugboatCaptureProfile? get activeProfile => _lifecycle.activeProfile;

  /// When `true`, the SDK is fully inert (no capture, no wrapping overhead).
  ///
  /// Setting this to `true` tears down any active session. Intended for remote
  /// config or feature-flag kill switches.
  static bool get disabled => _lifecycle.disabled;

  static set disabled(bool value) {
    _lifecycle.setDisabled(value);
    if (value) {
      _syncIdentityFromController();
      _controller?.dispose();
      _controller = null;
    }
  }

  /// Registers a full user-traits snapshot with the collector.
  ///
  /// When a capture session is active and the bag changes, debounces lifecycle
  /// posts (3s). Combined with a pending user change, posts
  /// `session_identify`; otherwise `traits_updated`. While `session_start` is
  /// still pending, updates memory only (folded into start at send time).
  static Future<void> setTraits(Map<String, dynamic> traits) async {
    if (mapEquals(_pendingTraits, traits)) return;
    _pendingTraits = Map<String, dynamic>.from(traits);
    final controller = _controller;
    if (controller == null) return;
    await controller.setTraits(traits);
    _pendingTraitsId = controller.collectorTraitsId ?? _pendingTraitsId;
  }

  /// Updates the runtime user id used on collector sessions and events.
  ///
  /// Always records a remount override via [hasPendingUserIdOverride]. Collector
  /// posting no-ops when [userId] equals the current runtime id. When a capture
  /// session is active and the id changes, debounces lifecycle posts (3s).
  /// Combined with a pending traits change, posts `session_identify`; otherwise
  /// `user_changed`. While `session_start` is still pending, updates memory only.
  static Future<void> setUserId(String? userId) async {
    _pendingUserId = userId;
    _pendingUserIdSet = true;
    final controller = _controller;
    if (controller == null) return;
    await controller.setUserId(userId);
    _pendingTraitsId = controller.collectorTraitsId ?? _pendingTraitsId;
  }

  /// Overrides automatic app-locale observation and emits later changes.
  ///
  /// Standard `MaterialApp.builder` and `CupertinoApp.builder` installation
  /// does not need this call. Use it when Tugboat wraps the app above
  /// [Localizations] or when the host owns a separate locale state.
  static void setLocale(Locale locale) {
    final info = TugboatLocaleInfo.fromLocale(locale);
    _localeOverride = info;
    _controller?.recordLocale(info);
  }

  /// Pending traits bag applied when the next [CollectorHttpSink] is created.
  static Map<String, dynamic>? get pendingTraits => _pendingTraits == null
      ? null
      : Map<String, dynamic>.unmodifiable(_pendingTraits!);

  /// Pending collector traits id applied when the next sink is created.
  static String? get pendingTraitsId => _pendingTraitsId;

  /// Whether [setUserId] has been called (including with `null`).
  static bool get hasPendingUserIdOverride => _pendingUserIdSet;

  /// Pending user id from [setUserId], when [hasPendingUserIdOverride] is true.
  static String? get pendingUserId => _pendingUserId;

  static void _syncIdentityFromController() {
    final controller = _controller;
    if (controller == null) return;
    final traits = controller.collectorTraits;
    if (traits != null) {
      _pendingTraits = Map<String, dynamic>.from(traits);
    }
    final traitsId = controller.collectorTraitsId;
    if (traitsId != null && traitsId.isNotEmpty) {
      _pendingTraitsId = traitsId;
    }
    // Only refresh when the host explicitly called setUserId. Config-applied
    // collectorUserId must not promote hasPendingUserIdOverride, or remounts
    // ignore updated TugboatReplayConfig.userId.
    if (_pendingUserIdSet) {
      _pendingUserId = controller.collectorUserId;
    }
  }

  /// Whether capture machinery is allowed to run ([disabled] is `false`).
  static bool get isEnabled => !_lifecycle.disabled;

  /// Whether the current session can accept app and network evidence now.
  ///
  /// Companion adapters should check this before invoking host callbacks or
  /// attaching observation metadata. The core APIs remain safe no-ops if the
  /// lifecycle changes before an observation reaches them.
  static bool get isAcceptingEvidence =>
      !disabled &&
      _lifecycle.state != TugboatLifecycleState.stopping &&
      (_controller?.acceptingEvidence ?? false);

  /// Enables capture machinery for dormant builds at runtime.
  ///
  static void activate({
    required String activationRequestId,
    TugboatCaptureProfile profile = TugboatCaptureProfile.productionLean,
  }) {
    _lifecycle.activate(
      activationRequestId: activationRequestId,
      profile: profile,
    );
  }

  /// Returns the SDK to dormant mode without tearing down the host app.
  static void deactivate() {
    _lifecycle.deactivate();
    // Widget teardown (and session_end) happens on the next gate rebuild.
    // Fence evidence now so same-turn host callbacks cannot append.
    _controller?.fenceEvidence();
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

  /// Returns a provider-neutral hook that records logical app/analytics events.
  ///
  /// The hook resolves the active controller at [TugboatEventHook.record] time
  /// so it never retains a stale session reference. Calls made while capture is
  /// dormant, disabled, or ended are safe no-ops.
  ///
  /// By default, [parameterPolicy] is
  /// [TugboatParameterPolicy.allowAllInProduction], so JSON-safe parameter
  /// values are retained within hard limits. Pass
  /// [TugboatParameterPolicy.namesOnly] to keep keys without values.
  static TugboatEventHook eventHook({
    String? source,
    TugboatParameterPolicy parameterPolicy =
        TugboatParameterPolicy.allowAllInProduction,
  }) {
    return _TugboatEventHook(source: source, parameterPolicy: parameterPolicy);
  }

  /// Begins observation of one logical network call.
  ///
  /// [route] must be a bounded absolute path such as `/blend/RC-T4KE7`.
  /// Dynamic identifier segments are allowed. Returns a no-op token when
  /// Tugboat is dormant/disabled or [route] is null/invalid.
  static TugboatNetworkCall beginNetworkCall({
    required String method,
    String? route,
  }) {
    try {
      if (!isAcceptingEvidence) return const TugboatNoOpNetworkCall();
      final controller = _controller;
      if (controller == null) return const TugboatNoOpNetworkCall();
      return controller.beginNetworkCall(method: method, route: route);
    } catch (_) {
      return const TugboatNoOpNetworkCall();
    }
  }

  /// Resets lifecycle state between tests.
  @visibleForTesting
  static void resetForTest() {
    _syncIdentityFromController();
    _controller?.dispose();
    _controller = null;
    debugConfigureControllerForTest = null;
    _lifecycle.resetForTest();
    _pendingTraits = null;
    _pendingTraitsId = null;
    _pendingUserId = null;
    _pendingUserIdSet = false;
    _localeOverride = null;
  }
}

class _TugboatEventHook implements TugboatEventHook {
  _TugboatEventHook({required this.source, required this.parameterPolicy});

  final String? source;
  final TugboatParameterPolicy parameterPolicy;

  @override
  void record(String name, {Map<String, Object?>? parameters}) {
    try {
      if (!TugboatReplay.isAcceptingEvidence) return;
      final controller = TugboatReplay.controller;
      if (controller == null) return;
      controller.recordExternalEvent(
        name: name,
        source: source,
        parameters: parameters,
        parameterPolicy: parameterPolicy,
      );
    } catch (_) {
      // Host analytics must never fail because of Tugboat.
    }
  }
}

/// Observes one [Navigator] and reports transitions to the active controller.
///
/// Install the root convenience instance via [TugboatReplay.navigatorObserver].
/// For nested Navigators that must be attributed, create a dedicated observer
/// with [TugboatReplay.createNavigatorObserver] (or `TugboatNavigatorObserver()`)
/// and install it on that Navigator — one observer instance per Navigator.
class TugboatNavigatorObserver extends NavigatorObserver {
  void _syncContext() {
    if (TugboatReplay.disabled) return;
    // Prefer the root navigator for pointer/anchor context; nested observers
    // still report their own NavigatorState into route ownership.
    if (identical(this, TugboatReplay.navigatorObserver)) {
      TugboatReplay.controller?.navigatorContext = navigator?.context;
    }
  }

  void _emit(
    String type,
    Route<dynamic>? destination, {
    Route<dynamic>? departing,
  }) {
    if (TugboatReplay.disabled) return;
    _syncContext();
    TugboatReplay.controller?.route(
      type,
      destination,
      navigatorState: navigator,
      departingRoute: departing,
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _emit('route_push', route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _emit('route_pop', previousRoute, departing: route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _emit('route_replace', newRoute, departing: oldRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _emit('route_remove', previousRoute, departing: route);
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
  TugboatLocaleInfo? _observedLocale;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = TugboatReplayController(
      config: widget.config,
      boundaryKey: TugboatReplay._boundaryKey,
      activationRequestId: widget.activationRequestId,
      sessionEpoch: widget.sessionEpoch,
      initialTraits: TugboatReplay.pendingTraits,
      initialTraitsId: TugboatReplay.pendingTraitsId,
      initialUserId: TugboatReplay.pendingUserId,
      initialUserIdOverride: TugboatReplay.hasPendingUserIdOverride,
    );
    TugboatReplay._controller = controller;
    TugboatReplay.debugConfigureControllerForTest?.call(controller);
    inputCapture = InputCapture(
      controller: controller,
      rootKey: TugboatReplay._boundaryKey,
    );
    _scheduleSessionStart();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!TugboatReplay.disabled) {
      TugboatReplay.controller?.recordAppLifecycleState(state);
    }
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _observeLocale();
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _observeLocale();
    });
  }

  TugboatLocaleInfo _activeLocale() {
    final override = TugboatReplay._localeOverride;
    if (override != null) return override;
    final locale =
        Localizations.maybeLocaleOf(context) ??
        WidgetsBinding.instance.platformDispatcher.locale;
    return TugboatLocaleInfo.fromLocale(locale);
  }

  void _observeLocale() {
    final locale = _activeLocale();
    if (locale == _observedLocale) return;
    _observedLocale = locale;
    if (_started) controller.recordLocale(locale);
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
      final locale = _observedLocale ?? _activeLocale();
      _observedLocale = locale;
      controller.start(
        viewport,
        Platform.isIOS ? 'ios' : 'android',
        locale: locale,
      );
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
      TugboatReplay._syncIdentityFromController();
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
      child: TugboatCaptureBoundary(
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
            onPointerPanZoomStart: (event) =>
                inputCapture?.handlePanZoomStart(event),
            onPointerPanZoomUpdate: (event) =>
                inputCapture?.handlePanZoomUpdate(event),
            onPointerPanZoomEnd: (event) =>
                inputCapture?.handlePanZoomEnd(event),
            child: content,
          ),
      ],
    );
  }
}
