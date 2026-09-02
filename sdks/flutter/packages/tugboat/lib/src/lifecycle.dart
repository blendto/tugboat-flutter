import 'package:flutter/foundation.dart';

/// Explicit capture lifecycle states owned by the SDK gate.
enum TugboatLifecycleState { dormant, starting, active, stopping }

/// Monotonic lifecycle requests observed by the always-mounted activation gate.
class TugboatLifecycleNotifier extends ChangeNotifier {
  TugboatLifecycleState _state = TugboatLifecycleState.dormant;
  int _requestEpoch = 0;
  String? _activationRequestId;
  bool? _captureOverride;
  bool _disabled = false;

  TugboatLifecycleState get state => _state;
  int get requestEpoch => _requestEpoch;
  String? get activationRequestId => _activationRequestId;
  bool get disabled => _disabled;
  bool get isActivated =>
      _activationRequestId != null &&
      (_state == TugboatLifecycleState.starting ||
          _state == TugboatLifecycleState.active ||
          _state == TugboatLifecycleState.stopping);

  /// Whether the gate should mount capture machinery for [configEnabled].
  bool shouldCapture(bool configEnabled) {
    if (_disabled) return false;
    return _captureOverride ?? configEnabled;
  }

  /// Enables capture. An identical active request is idempotent.
  void activate({required String activationRequestId}) {
    if (_disabled) return;

    final sameRequest =
        _activationRequestId == activationRequestId &&
        _captureOverride == true &&
        (_state == TugboatLifecycleState.starting ||
            _state == TugboatLifecycleState.active);
    if (sameRequest) return;

    _requestEpoch += 1;
    _activationRequestId = activationRequestId;
    _captureOverride = true;
    _state = TugboatLifecycleState.starting;
    notifyListeners();
  }

  void deactivate() {
    if (_state == TugboatLifecycleState.dormant &&
        _activationRequestId == null) {
      return;
    }
    _requestEpoch += 1;
    _activationRequestId = null;
    _captureOverride = false;
    _state = TugboatLifecycleState.stopping;
    notifyListeners();
  }

  void setDisabled(bool value) {
    if (_disabled == value) return;
    _disabled = value;
    if (value) {
      _requestEpoch += 1;
      _activationRequestId = null;
      _state = TugboatLifecycleState.stopping;
    } else if (_activationRequestId == null) {
      // Re-enable: drop the runtime override so configuration applies again.
      _captureOverride = null;
      _state = TugboatLifecycleState.dormant;
    }
    notifyListeners();
  }

  /// Test/helper: reset to a clean dormant state.
  void resetForTest() {
    _disabled = false;
    _activationRequestId = null;
    _captureOverride = null;
    _state = TugboatLifecycleState.dormant;
    _requestEpoch += 1;
    notifyListeners();
  }

  /// Called by the gate before it mounts configuration-enabled capture.
  void markStarting(int epoch) {
    if (_disabled || epoch != _requestEpoch) return;
    if (_state != TugboatLifecycleState.dormant) return;
    _state = TugboatLifecycleState.starting;
    notifyListeners();
  }

  /// Advances the session epoch while the gate rebuilds for changed grants.
  ///
  /// The gate is already rebuilding, so [markActive] sends the next lifecycle
  /// notification after the replacement session starts.
  int beginCapabilityRemount() {
    _requestEpoch += 1;
    _state = TugboatLifecycleState.starting;
    return _requestEpoch;
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
    if (_captureOverride == true) {
      // Replacement still requested under this epoch — stay starting/active.
      if (_state == TugboatLifecycleState.stopping) {
        _state = TugboatLifecycleState.starting;
        notifyListeners();
      }
      return;
    }
    _state = TugboatLifecycleState.dormant;
    notifyListeners();
  }
}
