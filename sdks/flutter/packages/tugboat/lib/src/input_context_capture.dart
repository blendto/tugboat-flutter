import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Closed focus vocabulary for `focus_changed` evidence.
///
/// It records only what kind of node holds primary focus; it never records
/// field contents, labels, or which field it is.
enum TugboatFocusKind {
  /// An editable text field (a [TextField], [EditableText], or anything that
  /// builds one) holds primary focus.
  textInput('text_input'),

  /// Some other focus node holds primary focus, such as a route's scope.
  other('other'),

  /// Nothing below the root scope holds primary focus.
  none('none');

  const TugboatFocusKind(this.wireName);

  final String wireName;
}

/// Closed system-input vocabulary for `system_input` evidence.
enum TugboatSystemInput {
  /// A system back request (Android back button or back gesture) that
  /// reached Flutter as a navigation pop request.
  back('back'),
  volumeUp('volume_up'),
  volumeDown('volume_down'),
  volumeMute('volume_mute'),
  power('power'),
  mediaPlayPause('media_play_pause');

  const TugboatSystemInput(this.wireName);

  final String wireName;

  /// Maps a hardware key to a system input, or null for every other key.
  ///
  /// This is a closed allowlist: character, editing, and navigation keys are
  /// never recorded. Back is deliberately absent because Android may deliver
  /// it both as a key and as a navigation pop request; only the pop request
  /// is recorded, so one press yields one event.
  static TugboatSystemInput? fromLogicalKey(LogicalKeyboardKey key) =>
      _systemKeys[key];
}

final _systemKeys = <LogicalKeyboardKey, TugboatSystemInput>{
  LogicalKeyboardKey.audioVolumeUp: TugboatSystemInput.volumeUp,
  LogicalKeyboardKey.audioVolumeDown: TugboatSystemInput.volumeDown,
  LogicalKeyboardKey.audioVolumeMute: TugboatSystemInput.volumeMute,
  LogicalKeyboardKey.power: TugboatSystemInput.power,
  LogicalKeyboardKey.mediaPlayPause: TugboatSystemInput.mediaPlayPause,
};

/// Classifies [node] for `focus_changed` evidence.
TugboatFocusKind tugboatFocusKindFor(FocusNode? node) {
  if (node == null || identical(node, FocusManager.instance.rootScope)) {
    return TugboatFocusKind.none;
  }
  final context = node.context;
  if (context == null || !context.mounted) return TugboatFocusKind.other;
  final ownsText =
      context.widget is EditableText ||
      context.findAncestorStateOfType<EditableTextState>() != null;
  return ownsText ? TugboatFocusKind.textInput : TugboatFocusKind.other;
}

/// Reports primary-focus transitions that involve an editable text field.
///
/// Route and scope churn between non-text nodes is ignored so navigation does
/// not produce focus evidence of its own.
class FocusChangeCapture {
  FocusChangeCapture({required this.onFocusChange});

  final void Function(TugboatFocusKind focus, TugboatFocusKind previous)
  onFocusChange;

  bool _installed = false;
  FocusNode? _lastNode;
  TugboatFocusKind _lastKind = TugboatFocusKind.none;

  void install() {
    if (_installed) return;
    _installed = true;
    _lastNode = FocusManager.instance.primaryFocus;
    _lastKind = tugboatFocusKindFor(_lastNode);
    FocusManager.instance.addListener(_handleFocusChange);
  }

  void dispose() {
    if (_installed) {
      FocusManager.instance.removeListener(_handleFocusChange);
    }
    _installed = false;
    _lastNode = null;
  }

  void _handleFocusChange() {
    try {
      final node = FocusManager.instance.primaryFocus;
      if (identical(node, _lastNode)) return;
      final kind = tugboatFocusKindFor(node);
      final previous = _lastKind;
      _lastNode = node;
      _lastKind = kind;
      if (kind != TugboatFocusKind.textInput &&
          previous != TugboatFocusKind.textInput) {
        return;
      }
      onFocusChange(kind, previous);
    } catch (error, stackTrace) {
      // Capture must never interrupt the host's focus handling.
      debugPrint('[tugboat] focus capture failed: $error\n$stackTrace');
    }
  }
}

/// Reports allowlisted system keys without consuming any key event.
class SystemKeyCapture {
  SystemKeyCapture({required this.onSystemInput});

  final void Function(TugboatSystemInput input) onSystemInput;

  bool _installed = false;

  void install() {
    if (_installed) return;
    _installed = true;
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  void dispose() {
    if (_installed) {
      HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    }
    _installed = false;
  }

  bool _handleKeyEvent(KeyEvent event) {
    try {
      // Key-down only: holding a volume key must not produce a repeat storm.
      if (event is! KeyDownEvent) return false;
      final input = TugboatSystemInput.fromLogicalKey(event.logicalKey);
      if (input != null) onSystemInput(input);
    } catch (error, stackTrace) {
      debugPrint('[tugboat] system key capture failed: $error\n$stackTrace');
    }
    // Never claim the event: the host and the platform keep their behavior.
    return false;
  }
}

/// Reports system back requests without ever claiming them.
///
/// [WidgetsBinding] offers a pop request to observers in registration order
/// and stops at the first that handles it, and `WidgetsApp` handles every pop
/// its Navigator can perform. Register this observer before the app's
/// `WidgetsApp` mounts (see [ensureRegistered]) to see every back request; a
/// later registration only sees the requests the app did not handle, such as
/// back on the root route.
class SystemBackObserver with WidgetsBindingObserver {
  SystemBackObserver({required this.onBack});

  final VoidCallback onBack;

  bool _registered = false;

  /// Registers with [WidgetsBinding] once. Safe to call before the binding
  /// exists; it then does nothing and a later call registers instead.
  void ensureRegistered() {
    if (_registered) return;
    final WidgetsBinding binding;
    try {
      binding = WidgetsBinding.instance;
    } catch (_) {
      return;
    }
    binding.addObserver(this);
    _registered = true;
  }

  @override
  Future<bool> didPopRoute() {
    try {
      onBack();
    } catch (error, stackTrace) {
      debugPrint('[tugboat] system back capture failed: $error\n$stackTrace');
    }
    return SynchronousFuture<bool>(false);
  }
}
