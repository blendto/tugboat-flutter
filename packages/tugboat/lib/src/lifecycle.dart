import 'package:flutter/foundation.dart';

import 'capture_profile.dart';

/// Explicit capture lifecycle states owned by the SDK gate.
enum TugboatLifecycleState { dormant, starting, active, stopping }

/// Monotonic lifecycle requests observed by the always-mounted activation gate.
class TugboatLifecycleNotifier extends ChangeNotifier {
  TugboatLifecycleState _state = TugboatLifecycleState.dormant;
  int _requestEpoch = 0;
  String? _activationRequestId;
  TugboatCaptureProfile? _activeProfile;
  bool _disabled = false;

  TugboatLifecycleState get state => _state;
  int get requestEpoch => _requestEpoch;
  String? get activationRequestId => _activationRequestId;
  TugboatCaptureProfile? get activeProfile {
    final profile = _activeProfile;
    if (profile == null || profile == TugboatCaptureProfile.dormant) {
      return null;
    }
    return profile;
  }

  bool get disabled => _disabled;
  bool get isActivated =>
      _activationRequestId != null &&
      (_state == TugboatLifecycleState.starting ||
          _state == TugboatLifecycleState.active ||
          _state == TugboatLifecycleState.stopping);

  /// Whether the gate should mount capture machinery for [configProfile].
  bool shouldCapture(TugboatCaptureProfile configProfile) {
    if (_disabled) return false;
    if (_activeProfile != null) {
      return _activeProfile != TugboatCaptureProfile.dormant;
    }
    return configProfile != TugboatCaptureProfile.dormant;
  }

  TugboatCaptureProfile effectiveProfile(TugboatCaptureProfile configProfile) {
    final override = _activeProfile;
    if (override != null && override != TugboatCaptureProfile.dormant) {
      return override;
    }
    if (override == TugboatCaptureProfile.dormant) {
      return TugboatCaptureProfile.dormant;
    }
    return configProfile;
  }

  /// Enables capture. Identical request+profile while already capturing is
  /// idempotent. A different request or profile while active bumps the epoch
  /// and forces stop-then-start via a new capture key.
  void activate({
    required String activationRequestId,
    TugboatCaptureProfile profile = TugboatCaptureProfile.productionLean,
  }) {
    if (_disabled) return;
    if (profile == TugboatCaptureProfile.dormant) return;

    final sameRequest =
        _activationRequestId == activationRequestId &&
        _activeProfile == profile &&
        (_state == TugboatLifecycleState.starting ||
            _state == TugboatLifecycleState.active);
    if (sameRequest) return;

    _requestEpoch += 1;
    _activationRequestId = activationRequestId;
    _activeProfile = profile;
    _state = TugboatLifecycleState.starting;
    notifyListeners();
  }

  void deactivate() {
    if (_state == TugboatLifecycleState.dormant &&
        _activeProfile == null &&
        _activationRequestId == null) {
      return;
    }
    _requestEpoch += 1;
    _activationRequestId = null;
    // Explicit dormant override so config-active profiles also stop.
    _activeProfile = TugboatCaptureProfile.dormant;
    _state = TugboatLifecycleState.stopping;
    notifyListeners();
  }

  void setDisabled(bool value) {
    if (_disabled == value) return;
    _disabled = value;
    if (value) {
      _requestEpoch += 1;
      _activationRequestId = null;
      _activeProfile = TugboatCaptureProfile.dormant;
      _state = TugboatLifecycleState.stopping;
    } else if (_activeProfile == TugboatCaptureProfile.dormant &&
        _activationRequestId == null) {
      // Re-enable: drop forced dormant so config profiles can capture again.
      _activeProfile = null;
      _state = TugboatLifecycleState.dormant;
    }
    notifyListeners();
  }

  /// Test/helper: reset to a clean dormant state.
  void resetForTest() {
    _disabled = false;
    _activationRequestId = null;
    _activeProfile = null;
    _state = TugboatLifecycleState.dormant;
    _requestEpoch += 1;
    notifyListeners();
  }

  /// Called by the gate when capture machinery is fully up.
  void markActive(int epoch) {
    if (epoch != _requestEpoch) return;
    if (_state != TugboatLifecycleState.starting &&
        _state != TugboatLifecycleState.active) {
      return;
    }
    _state = TugboatLifecycleState.active;
    notifyListeners();
  }

  /// Called by the gate when capture machinery has been torn down.
  void markDormant(int epoch) {
    if (_disabled) {
      _state = TugboatLifecycleState.dormant;
      notifyListeners();
      return;
    }
    if (epoch != _requestEpoch) return;
    if (_activeProfile != null &&
        _activeProfile != TugboatCaptureProfile.dormant) {
      // Replacement still requested under this epoch — stay starting/active.
      if (_state == TugboatLifecycleState.stopping) {
        _state = TugboatLifecycleState.starting;
        notifyListeners();
      }
      return;
    }
    _state = TugboatLifecycleState.dormant;
    _activeProfile = null;
    notifyListeners();
  }
}
