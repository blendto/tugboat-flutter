part of 'anchors.dart';

/// Shared classification of Material/Cupertino interactive widgets.
///
/// Used by token-map walks, screenshot masking, and inventory building so
/// role detection stays consistent across the SDK.
class WidgetRole {
  const WidgetRole(this.name, this.enabled, {this.actions = const []});

  final String name;
  final bool? enabled;
  final List<String> actions;
}

bool tugboatHidesSubtree(Widget widget) {
  if (widget is Offstage) return widget.offstage;
  if (widget is Visibility) return !widget.visible;
  if (widget is Opacity) return widget.opacity == 0;
  return false;
}

bool tugboatHidesRenderObject(RenderObject? renderObject) {
  if (renderObject is RenderOffstage) return renderObject.offstage;
  if (renderObject is RenderOpacity) return renderObject.opacity == 0;
  if (renderObject is RenderAnimatedOpacity) {
    return renderObject.opacity.value == 0;
  }
  return false;
}

bool tugboatIsCaptureChrome(Widget widget) {
  return widget is RepaintBoundary ||
      widget is NotificationListener ||
      widget is Listener ||
      widget is IgnorePointer ||
      widget is AbsorbPointer ||
      widget is Semantics;
}

bool tugboatIsSensitiveInput(EditableText widget) {
  return widget.obscureText ||
      widget.keyboardType == TextInputType.emailAddress ||
      widget.keyboardType == TextInputType.phone ||
      widget.keyboardType == TextInputType.visiblePassword;
}

/// Returns role metadata when [widget] is an interactive control; otherwise null.
WidgetRole? tugboatRoleForWidget(Widget widget) {
  for (final resolver in _widgetRoleResolvers) {
    final role = resolver(widget);
    if (role != null) return role;
  }
  return null;
}

final _widgetRoleResolvers = <WidgetRole? Function(Widget)>[
  _buttonRoleForWidget,
  _menuRoleForWidget,
  _inkRoleForWidget,
  _listTileRoleForWidget,
  _gestureRoleForWidget,
  _chipRoleForWidget,
  _scrollableRoleForWidget,
  _checkboxRoleForWidget,
  _switchRoleForWidget,
  _radioRoleForWidget,
  _sliderRoleForWidget,
  _dropdownRoleForWidget,
  _textFieldRoleForWidget,
];

WidgetRole _tapRole(String name, bool enabled) =>
    WidgetRole(name, enabled, actions: enabled ? const ['tap'] : const []);

WidgetRole? _buttonRoleForWidget(Widget widget) {
  if (widget is ButtonStyleButton) {
    return _tapRole('button', widget.onPressed != null);
  }
  if (widget is IconButton) return _tapRole('button', widget.onPressed != null);
  if (widget is CupertinoButton) {
    return _tapRole('button', widget.onPressed != null);
  }
  if (widget is MaterialButton) {
    return _tapRole('button', widget.onPressed != null);
  }
  if (widget is FloatingActionButton) {
    return _tapRole('button', widget.onPressed != null);
  }
  return null;
}

WidgetRole? _menuRoleForWidget(Widget widget) {
  if (widget is PopupMenuButton) return _tapRole('button', widget.enabled);
  if (widget is PopupMenuItem) return _tapRole('button', widget.enabled);
  if (widget is ExpansionTile) return _tapRole('button', widget.enabled);
  return null;
}

WidgetRole? _inkRoleForWidget(Widget widget) {
  if (widget is InkWell) return _tapRole('button', widget.onTap != null);
  if (widget is InkResponse) return _tapRole('button', widget.onTap != null);
  return null;
}

WidgetRole? _listTileRoleForWidget(Widget widget) {
  if (widget is! ListTile ||
      (widget.onTap == null && widget.onLongPress == null)) {
    return null;
  }
  final actions = <String>[];
  if (widget.enabled && widget.onTap != null) actions.add('tap');
  if (widget.enabled && widget.onLongPress != null) actions.add('longPress');
  return WidgetRole('button', widget.enabled, actions: actions);
}

WidgetRole? _gestureRoleForWidget(Widget widget) {
  if (widget is! GestureDetector) return null;
  final actions = <String>[];
  if (widget.onTap != null) actions.add('tap');
  if (widget.onDoubleTap != null) actions.add('doubleTap');
  if (widget.onLongPress != null) actions.add('longPress');
  return actions.isEmpty ? null : WidgetRole('button', true, actions: actions);
}

WidgetRole? _chipRoleForWidget(Widget widget) {
  final enabled = switch (widget) {
    InputChip w => w.onPressed != null || w.onSelected != null,
    ActionChip w => w.onPressed != null,
    FilterChip w => w.onSelected != null,
    ChoiceChip w => w.onSelected != null,
    _ => null,
  };
  return enabled == null ? null : _tapRole('button', enabled);
}

WidgetRole? _scrollableRoleForWidget(Widget widget) => widget is Scrollable
    ? const WidgetRole('scrollable', null, actions: ['scroll'])
    : null;

WidgetRole? _checkboxRoleForWidget(Widget widget) {
  if (widget is Checkbox) return _tapRole('checkbox', widget.onChanged != null);
  if (widget is CheckboxListTile) {
    return _tapRole('checkbox', widget.onChanged != null);
  }
  return null;
}

WidgetRole? _switchRoleForWidget(Widget widget) {
  if (widget is Switch) return _tapRole('switch', widget.onChanged != null);
  if (widget is CupertinoSwitch) {
    return _tapRole('switch', widget.onChanged != null);
  }
  if (widget is SwitchListTile) {
    return _tapRole('switch', widget.onChanged != null);
  }
  return null;
}

WidgetRole? _radioRoleForWidget(Widget widget) {
  if (widget is! Radio && widget is! RadioListTile) return null;
  return _tapRole('radio', (widget as dynamic).onChanged != null);
}

WidgetRole? _sliderRoleForWidget(Widget widget) {
  final enabled = switch (widget) {
    Slider w => w.onChanged != null,
    RangeSlider w => w.onChanged != null,
    CupertinoSlider w => w.onChanged != null,
    _ => null,
  };
  return enabled == null
      ? null
      : WidgetRole(
          'slider',
          enabled,
          actions: enabled ? const ['slide'] : const [],
        );
}

WidgetRole? _dropdownRoleForWidget(Widget widget) => widget is DropdownButton
    ? _tapRole('dropdown', (widget as dynamic).onChanged != null)
    : null;

WidgetRole? _textFieldRoleForWidget(Widget widget) {
  final enabled = switch (widget) {
    TextField w => w.enabled ?? true,
    TextFormField w => w.enabled,
    EditableText w => !w.readOnly,
    _ => null,
  };
  return enabled == null
      ? null
      : WidgetRole(
          'textField',
          enabled,
          actions: enabled ? const ['input'] : const [],
        );
}

bool tugboatIsActionableWidget(Widget widget) {
  final role = tugboatRoleForWidget(widget);
  if (role == null) return false;
  if (role.name == 'scrollable') return false;
  return role.enabled != false && role.actions.isNotEmpty;
}
