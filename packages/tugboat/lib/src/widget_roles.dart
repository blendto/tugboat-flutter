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
  if (widget is ButtonStyleButton) {
    return WidgetRole(
      'button',
      widget.onPressed != null,
      actions: widget.onPressed != null ? const ['tap'] : const [],
    );
  }
  if (widget is IconButton) {
    return WidgetRole(
      'button',
      widget.onPressed != null,
      actions: widget.onPressed != null ? const ['tap'] : const [],
    );
  }
  if (widget is CupertinoButton) {
    return WidgetRole(
      'button',
      widget.onPressed != null,
      actions: widget.onPressed != null ? const ['tap'] : const [],
    );
  }
  if (widget is MaterialButton) {
    return WidgetRole(
      'button',
      widget.onPressed != null,
      actions: widget.onPressed != null ? const ['tap'] : const [],
    );
  }
  if (widget is FloatingActionButton) {
    return WidgetRole(
      'button',
      widget.onPressed != null,
      actions: widget.onPressed != null ? const ['tap'] : const [],
    );
  }
  if (widget is PopupMenuButton) {
    return WidgetRole(
      'button',
      widget.enabled,
      actions: widget.enabled ? const ['tap'] : const [],
    );
  }
  if (widget is PopupMenuItem) {
    return WidgetRole(
      'button',
      widget.enabled,
      actions: widget.enabled ? const ['tap'] : const [],
    );
  }
  if (widget is ExpansionTile) {
    return WidgetRole(
      'button',
      widget.enabled,
      actions: widget.enabled ? const ['tap'] : const [],
    );
  }
  if (widget is InkWell) {
    return WidgetRole(
      'button',
      widget.onTap != null,
      actions: widget.onTap != null ? const ['tap'] : const [],
    );
  }
  if (widget is InkResponse) {
    return WidgetRole(
      'button',
      widget.onTap != null,
      actions: widget.onTap != null ? const ['tap'] : const [],
    );
  }
  if (widget is ListTile &&
      (widget.onTap != null || widget.onLongPress != null)) {
    final actions = <String>[];
    if (widget.enabled && widget.onTap != null) actions.add('tap');
    if (widget.enabled && widget.onLongPress != null) {
      actions.add('longPress');
    }
    return WidgetRole('button', widget.enabled, actions: actions);
  }
  if (widget is GestureDetector) {
    final actions = <String>[];
    if (widget.onTap != null) actions.add('tap');
    if (widget.onDoubleTap != null) actions.add('doubleTap');
    if (widget.onLongPress != null) actions.add('longPress');
    if (actions.isNotEmpty) return WidgetRole('button', true, actions: actions);
  }
  if (widget is InputChip ||
      widget is ActionChip ||
      widget is FilterChip ||
      widget is ChoiceChip) {
    final enabled = switch (widget) {
      InputChip w => w.onPressed != null || w.onSelected != null,
      ActionChip w => w.onPressed != null,
      FilterChip w => w.onSelected != null,
      ChoiceChip w => w.onSelected != null,
      _ => false,
    };
    return WidgetRole(
      'button',
      enabled,
      actions: enabled ? const ['tap'] : const [],
    );
  }
  if (widget is Scrollable) {
    return const WidgetRole('scrollable', null, actions: ['scroll']);
  }
  if (widget is Checkbox) {
    return WidgetRole(
      'checkbox',
      widget.onChanged != null,
      actions: widget.onChanged != null ? const ['tap'] : const [],
    );
  }
  if (widget is CheckboxListTile) {
    return WidgetRole(
      'checkbox',
      widget.onChanged != null,
      actions: widget.onChanged != null ? const ['tap'] : const [],
    );
  }
  if (widget is Switch) {
    return WidgetRole(
      'switch',
      widget.onChanged != null,
      actions: widget.onChanged != null ? const ['tap'] : const [],
    );
  }
  if (widget is CupertinoSwitch) {
    return WidgetRole(
      'switch',
      widget.onChanged != null,
      actions: widget.onChanged != null ? const ['tap'] : const [],
    );
  }
  if (widget is SwitchListTile) {
    return WidgetRole(
      'switch',
      widget.onChanged != null,
      actions: widget.onChanged != null ? const ['tap'] : const [],
    );
  }
  if (widget is Radio || widget is RadioListTile) {
    final enabled = switch (widget) {
      // ignore: deprecated_member_use
      Radio w => w.onChanged != null,
      // ignore: deprecated_member_use
      RadioListTile w => w.onChanged != null,
      _ => false,
    };
    return WidgetRole(
      'radio',
      enabled,
      actions: enabled ? const ['tap'] : const [],
    );
  }
  if (widget is Slider || widget is RangeSlider || widget is CupertinoSlider) {
    final enabled = switch (widget) {
      Slider w => w.onChanged != null,
      RangeSlider w => w.onChanged != null,
      CupertinoSlider w => w.onChanged != null,
      _ => false,
    };
    return WidgetRole(
      'slider',
      enabled,
      actions: enabled ? const ['slide'] : const [],
    );
  }
  if (widget is DropdownButton) {
    // Reading a generic DropdownButton callback through the promoted
    // DropdownButton<dynamic> view can cast a typed async callback to
    // void Function(dynamic), which is not a valid runtime cast. Keep this
    // inspection dynamic so role detection never invokes that cast.
    final enabled = (widget as dynamic).onChanged != null;
    return WidgetRole(
      'dropdown',
      enabled,
      actions: enabled ? const ['tap'] : const [],
    );
  }
  if (widget is EditableText ||
      widget is TextField ||
      widget is TextFormField) {
    final enabled = switch (widget) {
      TextField w => w.enabled ?? true,
      TextFormField w => w.enabled,
      EditableText w => !w.readOnly,
      _ => true,
    };
    return WidgetRole(
      'textField',
      enabled,
      actions: enabled ? const ['input'] : const [],
    );
  }
  return null;
}

bool tugboatIsActionableWidget(Widget widget) {
  final role = tugboatRoleForWidget(widget);
  if (role == null) return false;
  if (role.name == 'scrollable') return false;
  return role.enabled != false && role.actions.isNotEmpty;
}
