part of 'anchors.dart';

/// Schema version for privacy-safe control value payloads.
const int tugboatControlValueSchemaVersion = 1;

final RegExp _developerTokenPattern = RegExp(r'^[A-Za-z0-9_./:-]{1,64}$');

/// Encodes a single control scalar without retaining free-text labels.
class TugboatEncodedControlScalar {
  const TugboatEncodedControlScalar._({
    required this.kind,
    this.value,
    this.length,
  });

  /// `null`, `bool`, `number`, or `token`.
  final String kind;

  /// Literal bool/num, or a privacy-safe token string.
  final Object? value;

  /// Original string length when [kind] is `token` derived from a String.
  final int? length;

  factory TugboatEncodedControlScalar.encode(Object? raw) {
    if (raw == null) {
      return const TugboatEncodedControlScalar._(kind: 'null');
    }
    if (raw is bool) {
      return TugboatEncodedControlScalar._(kind: 'bool', value: raw);
    }
    if (raw is num) {
      return TugboatEncodedControlScalar._(kind: 'number', value: raw);
    }
    if (raw is Enum) {
      return TugboatEncodedControlScalar._(
        kind: 'token',
        value: '${raw.runtimeType}.${raw.name}',
      );
    }
    if (raw is String) {
      if (_developerTokenPattern.hasMatch(raw)) {
        return TugboatEncodedControlScalar._(kind: 'token', value: raw);
      }
      return TugboatEncodedControlScalar._(
        kind: 'token',
        value: 'str:${tugboatLabelHash(raw)}',
        length: raw.length,
      );
    }
    final text = raw.toString();
    return TugboatEncodedControlScalar._(
      kind: 'token',
      value: '${raw.runtimeType}:${tugboatLabelHash(text)}',
      length: text.length,
    );
  }

  Map<String, Object?> toJson() => {
    'kind': kind,
    if (kind != 'null') 'value': value,
    if (length != null) 'length': length,
  };

  @override
  bool operator ==(Object other) =>
      other is TugboatEncodedControlScalar &&
      kind == other.kind &&
      value == other.value &&
      length == other.length;

  @override
  int get hashCode => Object.hash(kind, value, length);
}

/// Privacy-safe snapshot of an interactive control's value at sample time.
///
/// Free-text option labels are hashed. Bools, numbers, enums, and short
/// developer-token strings are retained so taps on radios, dropdowns,
/// toggles, and sliders remain interpretable without storing arbitrary UI copy.
class TugboatControlValue {
  const TugboatControlValue({
    required this.role,
    this.widgetType,
    this.value,
    this.groupValue,
    this.selected,
    this.index,
    this.start,
    this.end,
    this.schemaVersion = tugboatControlValueSchemaVersion,
  });

  final int schemaVersion;

  /// Control role (`checkbox`, `switch`, `radio`, `slider`, `dropdown`,
  /// `dropdownItem`, `menuItem`, `chip`).
  final String role;
  final String? widgetType;

  /// Primary sampled value (option identity, toggle state, slider position).
  final TugboatEncodedControlScalar? value;

  /// Current group selection for radio controls.
  final TugboatEncodedControlScalar? groupValue;

  /// Whether this option is the active selection (radios/chips).
  final bool? selected;

  /// Zero-based index among sibling options when known.
  final int? index;

  /// Range slider start (inclusive).
  final TugboatEncodedControlScalar? start;

  /// Range slider end (inclusive).
  final TugboatEncodedControlScalar? end;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'role': role,
    if (widgetType != null && widgetType!.isNotEmpty) 'widgetType': widgetType,
    if (value != null) 'value': value!.toJson(),
    if (groupValue != null) 'groupValue': groupValue!.toJson(),
    if (selected != null) 'selected': selected,
    if (index != null) 'index': index,
    if (start != null) 'start': start!.toJson(),
    if (end != null) 'end': end!.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is TugboatControlValue &&
      schemaVersion == other.schemaVersion &&
      role == other.role &&
      widgetType == other.widgetType &&
      value == other.value &&
      groupValue == other.groupValue &&
      selected == other.selected &&
      index == other.index &&
      start == other.start &&
      end == other.end;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    role,
    widgetType,
    value,
    groupValue,
    selected,
    index,
    start,
    end,
  );
}

/// Reads a privacy-safe control value from [widget], or null when unsupported.
TugboatControlValue? tugboatControlValueForWidget(Widget widget, {int? index}) {
  final widgetType = widget.runtimeType.toString();

  if (widget is Checkbox) {
    return TugboatControlValue(
      role: 'checkbox',
      widgetType: widgetType,
      value: TugboatEncodedControlScalar.encode(widget.value),
      selected: widget.value == true,
      index: index,
    );
  }
  if (widget is CheckboxListTile) {
    return TugboatControlValue(
      role: 'checkbox',
      widgetType: widgetType,
      value: TugboatEncodedControlScalar.encode(widget.value),
      selected: widget.value == true,
      index: index,
    );
  }
  if (widget is Switch) {
    return TugboatControlValue(
      role: 'switch',
      widgetType: widgetType,
      value: TugboatEncodedControlScalar.encode(widget.value),
      selected: widget.value,
      index: index,
    );
  }
  if (widget is CupertinoSwitch) {
    return TugboatControlValue(
      role: 'switch',
      widgetType: widgetType,
      value: TugboatEncodedControlScalar.encode(widget.value),
      selected: widget.value,
      index: index,
    );
  }
  if (widget is SwitchListTile) {
    return TugboatControlValue(
      role: 'switch',
      widgetType: widgetType,
      value: TugboatEncodedControlScalar.encode(widget.value),
      selected: widget.value,
      index: index,
    );
  }
  if (widget is Radio || widget is RadioListTile) {
    // Typed Radio<T> / RadioListTile<T> cannot be read through a promoted
    // Radio<dynamic> view; keep access dynamic like role detection.
    final dynamic radio = widget;
    final option = radio.value;
    final group = radio.groupValue;
    return TugboatControlValue(
      role: 'radio',
      widgetType: widgetType,
      value: TugboatEncodedControlScalar.encode(option),
      groupValue: TugboatEncodedControlScalar.encode(group),
      selected: option == group,
      index: index,
    );
  }
  if (widget is Slider) {
    return TugboatControlValue(
      role: 'slider',
      widgetType: widgetType,
      value: TugboatEncodedControlScalar.encode(widget.value),
      index: index,
    );
  }
  if (widget is CupertinoSlider) {
    return TugboatControlValue(
      role: 'slider',
      widgetType: widgetType,
      value: TugboatEncodedControlScalar.encode(widget.value),
      index: index,
    );
  }
  if (widget is RangeSlider) {
    return TugboatControlValue(
      role: 'slider',
      widgetType: widgetType,
      start: TugboatEncodedControlScalar.encode(widget.values.start),
      end: TugboatEncodedControlScalar.encode(widget.values.end),
      index: index,
    );
  }
  if (widget is DropdownButton) {
    final dynamic dropdown = widget;
    return TugboatControlValue(
      role: 'dropdown',
      widgetType: widgetType,
      value: TugboatEncodedControlScalar.encode(dropdown.value),
      index: index,
    );
  }
  if (widget is DropdownMenuItem) {
    final dynamic item = widget;
    return TugboatControlValue(
      role: 'dropdownItem',
      widgetType: widgetType,
      value: TugboatEncodedControlScalar.encode(item.value),
      index: index,
    );
  }
  if (widget is PopupMenuItem) {
    final dynamic item = widget;
    return TugboatControlValue(
      role: 'menuItem',
      widgetType: widgetType,
      value: TugboatEncodedControlScalar.encode(item.value),
      index: index,
    );
  }
  if (widget is FilterChip) {
    return TugboatControlValue(
      role: 'chip',
      widgetType: widgetType,
      value: TugboatEncodedControlScalar.encode(widget.selected),
      selected: widget.selected,
      index: index,
    );
  }
  if (widget is ChoiceChip) {
    return TugboatControlValue(
      role: 'chip',
      widgetType: widgetType,
      value: TugboatEncodedControlScalar.encode(widget.selected),
      selected: widget.selected,
      index: index,
    );
  }
  return null;
}

/// Walks [hitElement] and its ancestors for the deepest valued control.
TugboatControlValue? tugboatControlValueForElement(Element hitElement) {
  TugboatControlValue? found;

  void consider(Element element) {
    if (found != null) return;
    final index = _optionIndexAmongSiblings(element);
    found = tugboatControlValueForWidget(element.widget, index: index);
  }

  consider(hitElement);
  hitElement.visitAncestorElements((ancestor) {
    consider(ancestor);
    return found == null;
  });
  return found;
}

int? _optionIndexAmongSiblings(Element element) {
  final self = tugboatControlValueForWidget(element.widget);
  if (self == null) return null;
  const optionRoles = {'radio', 'dropdownItem', 'menuItem', 'chip'};
  if (!optionRoles.contains(self.role)) return null;

  // Walk up until a parent exposes multiple same-role options among its
  // descendants, then return this element's ordinal among those options.
  Element? parent;
  element.visitAncestorElements((ancestor) {
    parent = ancestor;
    return false;
  });
  while (parent != null) {
    final options = <Element>[];
    void collect(Element node) {
      final value = tugboatControlValueForWidget(node.widget);
      if (value != null && value.role == self.role) {
        options.add(node);
        return;
      }
      node.visitChildElements(collect);
    }

    parent!.visitChildElements(collect);
    if (options.length > 1) {
      final index = options.indexWhere((option) => identical(option, element));
      return index >= 0 ? index : null;
    }

    Element? next;
    parent!.visitAncestorElements((ancestor) {
      next = ancestor;
      return false;
    });
    parent = next;
  }
  return null;
}
