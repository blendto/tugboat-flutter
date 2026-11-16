import 'dart:async';

import 'package:flutter/scheduler.dart';

/// Quiet window after the last drawn frame before a settled re-sample.
const Duration settledInventoryDebounce = Duration(milliseconds: 400);

/// Continuous frame activity after which a sample is taken anyway, so a page
/// that never goes quiet (a spinner that keeps turning beside loaded content)
/// is still sampled.
const Duration settledInventoryMaxBusy = Duration(seconds: 2);

/// Longest window between samples. Each sample that finds nothing new doubles
/// the window from [settledInventoryDebounce] up to this; a sample that finds
/// something new resets it.
const Duration settledInventoryMaxWindow = Duration(milliseconds: 6400);

/// At most this many settled inventories per route key per session, and per
/// route visit (route epoch).
const int settledInventoryEmissionCap = 5;

/// Grid step for the coarse bounds signature (2% of the boundary).
const double settledInventoryGridStep = 0.02;

/// Watches one route epoch for frame activity after an inventory, and asks
/// its owner to re-sample once the page has settled.
///
/// - Armed, it parks one post-frame callback and holds no timer. A page that
///   draws no frame costs nothing, however long it stays armed.
/// - A drawn frame opens a window of the current length (first
///   [settledInventoryDebounce]). A window with no frame in it means the page
///   is quiet: [onSample] runs. A window with frames opens another, until
///   [settledInventoryMaxBusy] of activity forces a sample.
/// - After a sample no timer is left; the next drawn frame opens the next
///   window. A sample that found nothing new doubles the window up to
///   [settledInventoryMaxWindow], so a blinking cursor or a looping animation
///   is re-sampled ever more rarely; [nudge] resets it.
///
/// It never expires on its own: the owner cancels it on route change, pause,
/// session end and dispose, or when its cap is reached. It never throws.
class SettledInventoryWatch {
  SettledInventoryWatch({required this.routeEpoch, required this.onSample});

  /// The route epoch the watch was armed on. The owner compares it with the
  /// current epoch before it acts.
  final int routeEpoch;

  /// Re-samples the page; returns whether the sample found a new structure.
  /// Called on a timer, never inside a frame.
  final bool Function(SettledInventoryWatch watch) onSample;

  bool _cancelled = false;
  Timer? _window;
  bool _framedInWindow = false;
  Duration _windowLength = settledInventoryDebounce;
  Duration _busyFor = Duration.zero;

  bool get isCancelled => _cancelled;

  /// Whether a window timer is pending (test visibility only).
  bool get hasPendingWindow => _window != null;

  void arm() {
    if (_cancelled) return;
    SchedulerBinding.instance.addPostFrameCallback(_onFrame);
  }

  /// Fresh inventory activity on the same route: back to the shortest window.
  void nudge() {
    _windowLength = settledInventoryDebounce;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _window?.cancel();
    _window = null;
  }

  void _onFrame(Duration _) {
    if (_cancelled) return;
    if (_window == null) {
      _busyFor = Duration.zero;
      _openWindow();
    } else {
      _framedInWindow = true;
    }
    SchedulerBinding.instance.addPostFrameCallback(_onFrame);
  }

  void _openWindow() {
    _framedInWindow = false;
    _window = Timer(_windowLength, _onWindowEnd);
  }

  void _onWindowEnd() {
    _window = null;
    if (_cancelled) return;
    if (_framedInWindow) {
      _busyFor += _windowLength;
      if (_busyFor < settledInventoryMaxBusy) {
        _openWindow();
        return;
      }
    } else if (SchedulerBinding.instance.hasScheduledFrame) {
      // A frame is on its way and will open the next window.
      return;
    }
    _sample();
  }

  void _sample() {
    _busyFor = Duration.zero;
    var changed = false;
    try {
      changed = onSample(this);
    } catch (_) {
      cancel();
      return;
    }
    _windowLength = changed ? settledInventoryDebounce : _longerWindow();
  }

  Duration _longerWindow() {
    final doubled = _windowLength * 2;
    return doubled > settledInventoryMaxWindow
        ? settledInventoryMaxWindow
        : doubled;
  }
}
