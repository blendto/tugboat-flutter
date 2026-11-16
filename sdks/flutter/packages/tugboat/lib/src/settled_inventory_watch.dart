import 'dart:async';

import 'package:flutter/scheduler.dart';

/// Quiet window after the last frame before a settled re-sample.
const Duration settledInventoryDebounce = Duration(milliseconds: 400);

/// Longest a watch stays armed. A page that never goes quiet (an endless
/// animation that moves things) stops being watched after this.
const Duration settledInventoryMaxArm = Duration(seconds: 5);

/// At most this many settled inventories per route key per session.
const int settledInventoryEmissionCap = 5;

/// Hard flood guard: settled inventories per session across all routes.
const int settledInventorySessionEmissionCap = 40;

/// Hard flood guard: settled rebuilds per session, emitted or not.
const int settledInventorySessionRebuildCap = 200;

/// Grid step for the coarse bounds signature (2% of the boundary).
const double settledInventoryGridStep = 0.02;

/// Debounces layout activity after an inventory emission for one route.
///
/// Armed on an emission, it registers a frame callback. Every frame drawn while
/// armed starts or pushes back a quiet timer of [settledInventoryDebounce]. An
/// idle page draws no frames, so the quiet timer fires once and nothing is
/// pending. The watch stops itself once [settledInventoryMaxArm] has passed
/// (checked on frames, so an endless animation holds no timer), and [cancel]
/// stops everything.
class SettledInventoryWatch {
  SettledInventoryWatch({required this.route, required this.onQuiet});

  /// The raw route the watch was armed on. The owner compares it with the
  /// current route before it acts.
  final String? route;

  /// Called once per quiet window, on the timer, never inside a frame.
  final void Function(SettledInventoryWatch watch) onQuiet;

  bool _cancelled = false;
  Timer? _quiet;
  final Stopwatch _armedFor = Stopwatch();

  bool get isCancelled => _cancelled;

  void arm() {
    if (_cancelled) return;
    _armedFor.start();
    // No quiet timer yet: the first drawn frame after arming starts it. A
    // change always draws a frame, so nothing is missed, and an armed watch on
    // a page that never draws again holds no timer at all.
    _scheduleFrame();
  }

  /// Pushes the quiet deadline back by one full window. Used after a settled
  /// emission to watch for the next change.
  void restartQuietWindow() => _restartQuiet();

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _quiet?.cancel();
    _quiet = null;
    _armedFor.stop();
  }

  void _scheduleFrame() {
    if (_cancelled) return;
    SchedulerBinding.instance.addPostFrameCallback(_onFrame);
  }

  void _onFrame(Duration _) {
    if (_cancelled) return;
    // Checked on frames rather than with a timer, so an armed watch holds no
    // timer past its maximum arm (an endless animation never goes quiet).
    if (_armedFor.elapsed >= settledInventoryMaxArm) {
      cancel();
      return;
    }
    _restartQuiet();
    _scheduleFrame();
  }

  void _restartQuiet() {
    if (_cancelled) return;
    _quiet?.cancel();
    _quiet = Timer(settledInventoryDebounce, _fireQuiet);
  }

  void _fireQuiet() {
    if (_cancelled) return;
    onQuiet(this);
  }
}
