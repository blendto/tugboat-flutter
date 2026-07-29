part of 'anchors.dart';

/// Schema version for privacy-safe control value payloads.
const int tugboatControlValueSchemaVersion = 2;

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
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        return const TugboatEncodedControlScalar._(kind: 'null');
      }
      final asNum = num.tryParse(trimmed);
      if (asNum != null) {
        return TugboatEncodedControlScalar._(kind: 'number', value: asNum);
      }
      if (_developerTokenPattern.hasMatch(trimmed)) {
        return TugboatEncodedControlScalar._(kind: 'token', value: trimmed);
      }
      return TugboatEncodedControlScalar._(
        kind: 'token',
        value: 'str:${tugboatLabelHash(trimmed)}',
        length: trimmed.length,
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
/// Prefer typed widget state for standard Material/Cupertino controls. When
/// the hit target exposes Flutter semantics, [semanticValue] / [semanticLabel]
/// are attached as well so custom rows (e.g. GestureDetector lists) can still
/// report developer-authored semantic tokens.
///
/// Free-text strings are hashed. Bools, numbers, enums, numeric strings, and
/// short developer-token strings are retained.
class TugboatControlValue {
  const TugboatControlValue({
    required this.role,
    this.widgetType,
    this.sources = const ['widget'],
    this.value,
    this.groupValue,
    this.selected,
    this.index,
    this.start,
    this.end,
    this.semanticValue,
    this.semanticLabel,
    this.schemaVersion = tugboatControlValueSchemaVersion,
  });

  final int schemaVersion;

  /// Control role (`checkbox`, `switch`, `radio`, `slider`, `dropdown`,
  /// `dropdownItem`, `menuItem`, `chip`, `button`, `semantic`, …).
  final String role;
  final String? widgetType;

  /// Provenance markers such as `widget` and/or `semantics`.
  final List<String> sources;

  /// Primary sampled value (option identity, toggle state, slider position,
  /// or best-effort semantic value when no typed widget value exists).
  final TugboatEncodedControlScalar? value;

  /// Current group selection for radio controls.
  final TugboatEncodedControlScalar? groupValue;

  /// Whether this option is the active selection (radios/chips/semantics).
  final bool? selected;

  /// Zero-based index among sibling options when known.
  final int? index;

  /// Range slider start (inclusive).
  final TugboatEncodedControlScalar? start;

  /// Range slider end (inclusive).
  final TugboatEncodedControlScalar? end;

  /// Encoded [SemanticsData.value] / [SemanticsProperties.value] when present.
  final TugboatEncodedControlScalar? semanticValue;

  /// Encoded [SemanticsData.label] / [SemanticsProperties.label] when present.
  final TugboatEncodedControlScalar? semanticLabel;

  bool get hasPayload =>
      value != null ||
      groupValue != null ||
      selected != null ||
      start != null ||
      end != null ||
      semanticValue != null ||
      semanticLabel != null;

  TugboatControlValue copyWith({
    String? role,
    String? widgetType,
    List<String>? sources,
    TugboatEncodedControlScalar? value,
    TugboatEncodedControlScalar? groupValue,
    bool? selected,
    int? index,
    TugboatEncodedControlScalar? start,
    TugboatEncodedControlScalar? end,
    TugboatEncodedControlScalar? semanticValue,
    TugboatEncodedControlScalar? semanticLabel,
  }) {
    return TugboatControlValue(
      schemaVersion: schemaVersion,
      role: role ?? this.role,
      widgetType: widgetType ?? this.widgetType,
      sources: sources ?? this.sources,
      value: value ?? this.value,
      groupValue: groupValue ?? this.groupValue,
      selected: selected ?? this.selected,
      index: index ?? this.index,
      start: start ?? this.start,
      end: end ?? this.end,
      semanticValue: semanticValue ?? this.semanticValue,
      semanticLabel: semanticLabel ?? this.semanticLabel,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'role': role,
    if (widgetType != null && widgetType!.isNotEmpty) 'widgetType': widgetType,
    if (sources.isNotEmpty) 'sources': sources,
    if (value != null) 'value': value!.toJson(),
    if (groupValue != null) 'groupValue': groupValue!.toJson(),
    if (selected != null) 'selected': selected,
    if (index != null) 'index': index,
    if (start != null) 'start': start!.toJson(),
    if (end != null) 'end': end!.toJson(),
    if (semanticValue != null) 'semanticValue': semanticValue!.toJson(),
    if (semanticLabel != null) 'semanticLabel': semanticLabel!.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is TugboatControlValue &&
      schemaVersion == other.schemaVersion &&
      role == other.role &&
      widgetType == other.widgetType &&
      _listEquals(sources, other.sources) &&
      value == other.value &&
      groupValue == other.groupValue &&
      selected == other.selected &&
      index == other.index &&
      start == other.start &&
      end == other.end &&
      semanticValue == other.semanticValue &&
      semanticLabel == other.semanticLabel;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    role,
    widgetType,
    Object.hashAll(sources),
    value,
    groupValue,
    selected,
    index,
    start,
    end,
    semanticValue,
    semanticLabel,
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

/// Builds a control-value snapshot from explicit [SemanticsProperties].
TugboatControlValue? tugboatControlValueFromSemanticsProperties(
  SemanticsProperties properties, {
  String? widgetType,
  int? index,
  String? roleHint,
}) {
  final label = properties.label;
  final valueText = properties.value;
  final selected = properties.selected;
  final checked = properties.checked;
  final toggled = properties.toggled;

  final semanticValue = (valueText != null && valueText.trim().isNotEmpty)
      ? TugboatEncodedControlScalar.encode(valueText)
      : null;
  final semanticLabel = (label != null && label.trim().isNotEmpty)
      ? TugboatEncodedControlScalar.encode(label)
      : null;

  if (semanticValue == null &&
      semanticLabel == null &&
      selected == null &&
      checked == null &&
      toggled == null) {
    return null;
  }

  final role =
      roleHint ??
      (properties.slider == true
          ? 'slider'
          : properties.button == true
          ? 'button'
          : checked != null
          ? 'checkbox'
          : toggled != null
          ? 'switch'
          : 'semantic');

  return TugboatControlValue(
    role: role,
    widgetType: widgetType,
    sources: const ['semantics'],
    value:
        semanticValue ??
        (checked != null
            ? TugboatEncodedControlScalar.encode(checked)
            : toggled != null
            ? TugboatEncodedControlScalar.encode(toggled)
            : selected != null
            ? TugboatEncodedControlScalar.encode(selected)
            : null),
    selected: selected ?? checked ?? toggled,
    index: index,
    semanticValue: semanticValue,
    semanticLabel: semanticLabel,
  );
}

/// Builds a control-value snapshot from a live [SemanticsNode].
TugboatControlValue? tugboatControlValueFromSemanticsNode(
  SemanticsNode node, {
  String? roleHint,
}) {
  final data = node.getSemanticsData();
  final flags = data.flagsCollection;
  final checked = semanticsCheckedFromFlags(flags);
  final toggled = semanticsToggledFromFlags(flags);
  final selected = semanticsSelectedFromFlags(flags);

  final semanticValue = data.value.trim().isNotEmpty
      ? TugboatEncodedControlScalar.encode(data.value)
      : null;
  final semanticLabel = data.label.trim().isNotEmpty
      ? TugboatEncodedControlScalar.encode(data.label)
      : null;

  if (semanticValue == null &&
      semanticLabel == null &&
      checked == null &&
      toggled == null &&
      selected == null) {
    return null;
  }

  final role =
      roleHint ??
      (flags.isButton
          ? 'button'
          : checked != null
          ? 'checkbox'
          : toggled != null
          ? 'switch'
          : data.role != SemanticsRole.none
          ? data.role.name
          : 'semantic');

  return TugboatControlValue(
    role: role,
    sources: const ['semantics'],
    value:
        semanticValue ??
        (checked != null
            ? TugboatEncodedControlScalar.encode(checked)
            : toggled != null
            ? TugboatEncodedControlScalar.encode(toggled)
            : selected != null
            ? TugboatEncodedControlScalar.encode(selected)
            : null),
    selected: selected ?? checked ?? toggled,
    semanticValue: semanticValue,
    semanticLabel: semanticLabel,
  );
}

/// Merges typed widget state with semantic annotations.
TugboatControlValue? tugboatMergeControlValues(
  TugboatControlValue? widgetValue,
  TugboatControlValue? semanticsValue,
) {
  if (widgetValue == null) return semanticsValue;
  if (semanticsValue == null) {
    return widgetValue.sources.contains('widget')
        ? widgetValue
        : widgetValue.copyWith(sources: const ['widget']);
  }

  final sources = <String>{
    ...widgetValue.sources,
    ...semanticsValue.sources,
    'widget',
    'semantics',
  }.toList()..sort();

  return widgetValue.copyWith(
    sources: sources,
    value: widgetValue.value ?? semanticsValue.value,
    selected: widgetValue.selected ?? semanticsValue.selected,
    semanticValue: semanticsValue.semanticValue ?? widgetValue.semanticValue,
    semanticLabel: semanticsValue.semanticLabel ?? widgetValue.semanticLabel,
  );
}

/// Walks [hitElement] and its ancestors for widget + semantic control values.
TugboatControlValue? tugboatControlValueForElement(Element hitElement) {
  TugboatControlValue? widgetValue;
  TugboatControlValue? semanticsValue;

  void consider(Element element) {
    final index = widgetValue == null
        ? _optionIndexAmongSiblings(element)
        : null;
    widgetValue ??= tugboatControlValueForWidget(element.widget, index: index);
    // Explicit Semantics widgets are preferred over live nodes for labels.
    if (semanticsValue == null && element.widget is Semantics) {
      semanticsValue = tugboatControlValueFromSemanticsProperties(
        (element.widget as Semantics).properties,
        widgetType: element.widget.runtimeType.toString(),
      );
    }
    if (semanticsValue == null) {
      final node = element.renderObject?.debugSemantics;
      if (node != null) {
        semanticsValue = tugboatControlValueFromSemanticsNode(node);
      }
    }
  }

  consider(hitElement);
  hitElement.visitAncestorElements((ancestor) {
    consider(ancestor);
    return widgetValue == null || semanticsValue == null;
  });

  final merged = tugboatMergeControlValues(widgetValue, semanticsValue);
  if (merged == null || !merged.hasPayload) return null;
  return merged;
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
