part of 'anchors.dart';

/// Schema version for raw control value payloads.
const int tugboatControlValueSchemaVersion = 4;

/// Schema version for `tap_settled.controlValueTransition`.
const int tugboatControlValueTransitionSchemaVersion = 1;

/// Schema version for per-interaction semantic annotations.
const int tugboatSemanticAnnotationSchemaVersion = 2;

final RegExp _developerTokenPattern = RegExp(r'^[A-Za-z0-9_./:-]{1,64}$');
const String _developerTokenPrefix = 'tugboat:';
// AnchorResolver owns a per-controller key and still uses this zone to isolate
// its capture work. Raw control values no longer depend on the key.
const Symbol _controlValueHashKeyZoneKey = #tugboatControlValueHashKey;

List<int> _newControlValueHashKey() {
  final random = Random.secure();
  return List<int>.generate(32, (_) => random.nextInt(256), growable: false);
}

T _withControlValueHashKey<T>(List<int> key, T Function() body) {
  return runZoned(body, zoneValues: {_controlValueHashKeyZoneKey: key});
}

/// Encodes a single control scalar for analytics payloads.
class TugboatEncodedControlScalar {
  const TugboatEncodedControlScalar._({required this.kind, this.value});

  /// `null`, `bool`, `number`, `string`, `enum`, or a typed explicit value.
  final String kind;

  /// Raw scalar value.
  final Object? value;

  factory TugboatEncodedControlScalar.encode(Object? raw) {
    if (raw == null) {
      return const TugboatEncodedControlScalar._(kind: 'null');
    }
    if (raw is bool) {
      return TugboatEncodedControlScalar._(kind: 'bool', value: raw);
    }
    if (raw is num && raw.isFinite) {
      return TugboatEncodedControlScalar._(kind: 'number', value: raw);
    }
    if (raw is num) {
      return TugboatEncodedControlScalar._(
        kind: 'string',
        value: raw.toString(),
      );
    }
    if (raw is Enum) {
      return TugboatEncodedControlScalar._(
        kind: 'enum',
        value: '${raw.runtimeType}.${raw.name}',
      );
    }
    if (raw is String) {
      return TugboatEncodedControlScalar._(kind: 'string', value: raw);
    }
    return TugboatEncodedControlScalar._(kind: 'string', value: raw.toString());
  }

  /// Retains developer identifiers without the `tugboat:` namespace prefix.
  static TugboatEncodedControlScalar encodeDeveloperToken(String raw) {
    if (raw.startsWith(_developerTokenPrefix)) {
      final token = raw.substring(_developerTokenPrefix.length);
      if (_developerTokenPattern.hasMatch(token)) {
        return TugboatEncodedControlScalar._(kind: 'enum', value: token);
      }
    }
    return TugboatEncodedControlScalar.encode(raw);
  }

  Map<String, Object?> toJson() => {
    'kind': kind,
    if (kind != 'null') 'value': value,
  };

  @override
  bool operator ==(Object other) =>
      other is TugboatEncodedControlScalar &&
      kind == other.kind &&
      value == other.value;

  @override
  int get hashCode => Object.hash(kind, value);
}

/// A developer-declared typed control value.
class TugboatVisibleControlValue {
  const TugboatVisibleControlValue._(this._encoded);

  final TugboatEncodedControlScalar _encoded;

  /// A finite numeric value, such as a slider position or percentage.
  factory TugboatVisibleControlValue.number(num value) {
    if (!value.isFinite) {
      throw ArgumentError.value(value, 'value', 'must be finite');
    }
    return TugboatVisibleControlValue._(
      TugboatEncodedControlScalar._(kind: 'number', value: value),
    );
  }

  /// A boolean control state.
  TugboatVisibleControlValue.boolean(bool value)
    : _encoded = TugboatEncodedControlScalar._(kind: 'bool', value: value);

  /// A duration represented as an exact non-negative number of milliseconds.
  factory TugboatVisibleControlValue.duration(Duration value) {
    if (value.isNegative) {
      throw ArgumentError.value(value, 'value', 'must not be negative');
    }
    return TugboatVisibleControlValue._(
      TugboatEncodedControlScalar._(
        kind: 'duration_ms',
        value: value.inMilliseconds,
      ),
    );
  }

  /// A stable, developer-authored enum or template identifier.
  factory TugboatVisibleControlValue.enumId(String value) {
    final trimmed = value.trim();
    if (!_developerTokenPattern.hasMatch(trimmed)) {
      throw ArgumentError.value(
        value,
        'value',
        'must be 1-64 ASCII identifier characters',
      );
    }
    return TugboatVisibleControlValue._(
      TugboatEncodedControlScalar._(kind: 'enum', value: trimmed),
    );
  }

  Map<String, Object?> toJson() => _encoded.toJson();
}

/// Declares a typed analytics value for a custom interactive control.
///
/// Wrap controls whose actual state is not available from a standard Flutter
/// widget. [controlKey] should be a stable developer-owned identifier, for
/// example `video_duration`, `text_curve`, or `template`.
class TugboatControlValueScope extends StatelessWidget {
  const TugboatControlValueScope({
    super.key,
    required this.controlKey,
    required this.value,
    required this.child,
    this.role,
    this.unit,
    this.min,
    this.max,
    this.step,
  });

  final String controlKey;
  final TugboatVisibleControlValue value;
  final Widget child;

  /// Optional role override, such as `slider`, `dropdown`, or `chip`.
  final String? role;

  /// Optional stable unit, such as `ratio`, `percent`, or `milliseconds`.
  final String? unit;

  /// Optional inclusive lower bound for [value].
  final num? min;

  /// Optional inclusive upper bound for [value].
  final num? max;

  /// Optional increment for [value].
  final num? step;

  @override
  Widget build(BuildContext context) => child;

  TugboatControlValue? _toControlValue({required String fallbackRole}) {
    if (!_hasValidNumericMetadata()) return null;
    final normalizedKey = controlKey.trim();
    if (!_developerTokenPattern.hasMatch(normalizedKey)) return null;
    final normalizedRole = role?.trim();
    final normalizedUnit = unit?.trim();
    return TugboatControlValue(
      role: normalizedRole != null && normalizedRole.isNotEmpty
          ? normalizedRole
          : fallbackRole,
      sources: const ['developer'],
      controlKey: normalizedKey,
      unit:
          normalizedUnit != null &&
              _developerTokenPattern.hasMatch(normalizedUnit)
          ? normalizedUnit
          : null,
      value: value._encoded,
      min: _finiteNumber(min),
      max: _finiteNumber(max),
      step: _finiteNumber(step),
    );
  }

  TugboatEncodedControlScalar? _finiteNumber(num? value) {
    if (value == null || !value.isFinite) return null;
    return TugboatEncodedControlScalar.encode(value);
  }

  bool _hasValidNumericMetadata() {
    if ((min != null && !min!.isFinite) ||
        (max != null && !max!.isFinite) ||
        (step != null && !step!.isFinite) ||
        (min != null && max != null && min! > max!) ||
        (step != null && step! <= 0)) {
      return false;
    }
    if (min == null && max == null && step == null) return true;
    final encoded = value._encoded;
    if (encoded.kind != 'number' && encoded.kind != 'duration_ms') return false;
    final numericValue = encoded.value as num;
    return (min == null || numericValue >= min!) &&
        (max == null || numericValue <= max!);
  }
}

/// Semantic annotation for any interaction target.
///
/// Attached to taps, settles, swipes, and scrolls whenever Flutter semantics
/// expose an identifier, label, value, or selection flag under the target.
class TugboatSemanticAnnotation {
  const TugboatSemanticAnnotation({
    this.role,
    this.identifier,
    this.label,
    this.value,
    this.selected,
    this.checked,
    this.toggled,
    this.schemaVersion = tugboatSemanticAnnotationSchemaVersion,
  });

  final int schemaVersion;
  final String? role;

  /// Developer-authored semantics identifier when set.
  final TugboatEncodedControlScalar? identifier;

  /// Raw semantics label when present.
  final TugboatEncodedControlScalar? label;

  /// Raw semantics value when present.
  final TugboatEncodedControlScalar? value;

  final bool? selected;
  final bool? checked;
  final bool? toggled;

  bool get hasPayload =>
      (role != null && role!.isNotEmpty) ||
      identifier != null ||
      label != null ||
      value != null ||
      selected != null ||
      checked != null ||
      toggled != null;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    if (role != null && role!.isNotEmpty) 'role': role,
    if (identifier != null) 'identifier': identifier!.toJson(),
    if (label != null) 'label': label!.toJson(),
    if (value != null) 'value': value!.toJson(),
    if (selected != null) 'selected': selected,
    if (checked != null) 'checked': checked,
    if (toggled != null) 'toggled': toggled,
  };

  @override
  bool operator ==(Object other) =>
      other is TugboatSemanticAnnotation &&
      schemaVersion == other.schemaVersion &&
      role == other.role &&
      identifier == other.identifier &&
      label == other.label &&
      value == other.value &&
      selected == other.selected &&
      checked == other.checked &&
      toggled == other.toggled;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    role,
    identifier,
    label,
    value,
    selected,
    checked,
    toggled,
  );
}

/// Builds a semantic annotation from explicit [SemanticsProperties].
TugboatSemanticAnnotation? tugboatSemanticAnnotationFromProperties(
  SemanticsProperties properties, {
  String? roleHint,
}) {
  final identifierText = properties.identifier;
  final labelText = properties.label;
  final valueText = properties.value;
  final selected = properties.selected;
  final checked = properties.checked;
  final toggled = properties.toggled;

  final identifier =
      (identifierText != null && identifierText.trim().isNotEmpty)
      ? TugboatEncodedControlScalar.encodeDeveloperToken(identifierText)
      : null;
  final label = (labelText != null && labelText.trim().isNotEmpty)
      ? TugboatEncodedControlScalar.encode(labelText)
      : null;
  final value = (valueText != null && valueText.trim().isNotEmpty)
      ? TugboatEncodedControlScalar.encode(valueText)
      : null;

  final role =
      roleHint ??
      (properties.slider == true
          ? 'slider'
          : properties.button == true
          ? 'button'
          : properties.link == true
          ? 'link'
          : properties.textField == true
          ? 'textField'
          : properties.header == true
          ? 'header'
          : checked != null
          ? 'checkbox'
          : toggled != null
          ? 'switch'
          : null);

  final annotation = TugboatSemanticAnnotation(
    role: role,
    identifier: identifier,
    label: label,
    value: value,
    selected: selected,
    checked: checked,
    toggled: toggled,
  );
  return annotation.hasPayload ? annotation : null;
}

/// Builds a semantic annotation from a live [SemanticsNode].
TugboatSemanticAnnotation? tugboatSemanticAnnotationFromNode(
  SemanticsNode node, {
  String? roleHint,
}) {
  final data = node.getSemanticsData();
  final flags = data.flagsCollection;
  final checked = semanticsCheckedFromFlags(flags);
  final toggled = semanticsToggledFromFlags(flags);
  final selected = semanticsSelectedFromFlags(flags);

  final identifier = data.identifier.trim().isNotEmpty
      ? TugboatEncodedControlScalar.encodeDeveloperToken(data.identifier)
      : null;
  final label = data.label.trim().isNotEmpty
      ? TugboatEncodedControlScalar.encode(data.label)
      : null;
  final value = data.value.trim().isNotEmpty
      ? TugboatEncodedControlScalar.encode(data.value)
      : null;

  final role =
      roleHint ??
      (flags.isButton
          ? 'button'
          : flags.isLink
          ? 'link'
          : flags.isTextField
          ? 'textField'
          : flags.isHeader
          ? 'header'
          : checked != null
          ? 'checkbox'
          : toggled != null
          ? 'switch'
          : data.role != SemanticsRole.none
          ? data.role.name
          : null);

  final annotation = TugboatSemanticAnnotation(
    role: role,
    identifier: identifier,
    label: label,
    value: value,
    selected: selected,
    checked: checked,
    toggled: toggled,
  );
  return annotation.hasPayload ? annotation : null;
}

/// Merges two annotations, preferring [primary] fields and filling gaps.
///
/// An ancestor that supplies both a label and a value semantically describes a
/// parameter/value pair. Keep that label as the parameter identity instead of
/// replacing it with the descendant button's visible value text.
TugboatSemanticAnnotation tugboatMergeSemanticAnnotations(
  TugboatSemanticAnnotation primary,
  TugboatSemanticAnnotation fallback,
) {
  final fallbackDescribesParameter =
      fallback.label != null && fallback.value != null;
  return TugboatSemanticAnnotation(
    role: (primary.role != null && primary.role!.isNotEmpty)
        ? primary.role
        : fallback.role,
    identifier: primary.identifier ?? fallback.identifier,
    label: fallbackDescribesParameter
        ? fallback.label
        : primary.label ?? fallback.label,
    value: primary.value ?? fallback.value,
    selected: primary.selected ?? fallback.selected,
    checked: primary.checked ?? fallback.checked,
    toggled: primary.toggled ?? fallback.toggled,
  );
}

/// Walks [hitElement] and ancestors, merging semantic fields.
///
/// Child/deeper nodes win for concrete fields; ancestors fill gaps so a
/// Material button role can combine with a child Text label.
TugboatSemanticAnnotation? tugboatSemanticAnnotationForElement(
  Element hitElement,
) {
  TugboatSemanticAnnotation? merged;

  void consider(Element element) {
    TugboatSemanticAnnotation? next;
    if (element.widget is Semantics) {
      next = tugboatSemanticAnnotationFromProperties(
        (element.widget as Semantics).properties,
      );
    }
    next ??= () {
      final node = element.renderObject?.debugSemantics;
      return node == null ? null : tugboatSemanticAnnotationFromNode(node);
    }();
    if (next == null) return;
    merged = merged == null
        ? next
        : tugboatMergeSemanticAnnotations(merged!, next);
  }

  consider(hitElement);
  hitElement.visitAncestorElements((ancestor) {
    consider(ancestor);
    return true;
  });
  return merged;
}

/// Privacy-safe snapshot of an interactive control's value at sample time.
///
/// Prefer typed widget state for standard Material/Cupertino controls. When
/// the hit target exposes Flutter semantics, [semanticValue] / [semanticLabel]
/// are attached as well so custom rows (e.g. GestureDetector lists) can still
/// report developer-authored semantic values.
///
/// Bools, finite numbers, enums, and strings are retained as raw values.
class TugboatControlValue {
  const TugboatControlValue({
    required this.role,
    this.widgetType,
    this.sources = const ['widget'],
    this.controlKey,
    this.unit,
    this.min,
    this.max,
    this.step,
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

  /// Stable developer-owned key for an explicitly visible custom value.
  final String? controlKey;

  /// Optional unit for [value], such as `ratio` or `milliseconds`.
  final String? unit;

  /// Optional inclusive lower bound for an explicitly declared value.
  final TugboatEncodedControlScalar? min;

  /// Optional inclusive upper bound for an explicitly declared value.
  final TugboatEncodedControlScalar? max;

  /// Optional increment for an explicitly declared value.
  final TugboatEncodedControlScalar? step;

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
    String? controlKey,
    String? unit,
    TugboatEncodedControlScalar? min,
    TugboatEncodedControlScalar? max,
    TugboatEncodedControlScalar? step,
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
      controlKey: controlKey ?? this.controlKey,
      unit: unit ?? this.unit,
      min: min ?? this.min,
      max: max ?? this.max,
      step: step ?? this.step,
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
    if (controlKey != null && controlKey!.isNotEmpty) 'controlKey': controlKey,
    if (unit != null && unit!.isNotEmpty) 'unit': unit,
    if (min != null) 'min': min!.toJson(),
    if (max != null) 'max': max!.toJson(),
    if (step != null) 'step': step!.toJson(),
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
      controlKey == other.controlKey &&
      unit == other.unit &&
      min == other.min &&
      max == other.max &&
      step == other.step &&
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
    controlKey,
    unit,
    min,
    max,
    step,
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

/// Reads a control value from [widget], or null when unsupported.
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

  final semanticState = role == 'checkbox' || role == 'switch'
      ? (checked ?? toggled ?? selected)
      : null;

  return TugboatControlValue(
    role: role,
    widgetType: widgetType,
    sources: const ['semantics'],
    value:
        semanticValue ??
        (semanticState != null
            ? TugboatEncodedControlScalar.encode(semanticState)
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

  final semanticState = role == 'checkbox' || role == 'switch'
      ? (checked ?? toggled ?? selected)
      : null;

  return TugboatControlValue(
    role: role,
    sources: const ['semantics'],
    value:
        semanticValue ??
        (semanticState != null
            ? TugboatEncodedControlScalar.encode(semanticState)
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
  if (semanticsValue == null) return widgetValue;

  final sources = <String>{
    ...widgetValue.sources,
    ...semanticsValue.sources,
  }.toList()..sort();

  return widgetValue.copyWith(
    sources: sources,
    controlKey: widgetValue.controlKey ?? semanticsValue.controlKey,
    unit: widgetValue.unit ?? semanticsValue.unit,
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
  TugboatControlValueScope? developerScope;

  void consider(Element element) {
    developerScope ??= element.widget is TugboatControlValueScope
        ? element.widget as TugboatControlValueScope
        : null;
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
    return true;
  });

  final merged = tugboatMergeControlValues(widgetValue, semanticsValue);
  final developerValue = developerScope?._toControlValue(
    fallbackRole: merged?.role ?? 'semantic',
  );
  final value = tugboatMergeControlValues(developerValue, merged);
  if (value == null || !value.hasPayload) return null;
  return value;
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
