part of 'anchors.dart';

/// Normalized bounds within the viewport (0–1).
class PmkitNormalizedBounds {
  const PmkitNormalizedBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  factory PmkitNormalizedBounds.fromRect(Rect rect, Size viewport) {
    if (viewport.width <= 0 || viewport.height <= 0) {
      return const PmkitNormalizedBounds(left: 0, top: 0, width: 0, height: 0);
    }
    return PmkitNormalizedBounds(
      left: rect.left / viewport.width,
      top: rect.top / viewport.height,
      width: rect.width / viewport.width,
      height: rect.height / viewport.height,
    );
  }

  Map<String, Object?> toJson() => {
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };

  factory PmkitNormalizedBounds.fromJson(Map<String, dynamic> json) =>
      PmkitNormalizedBounds(
        left: (json['left'] as num).toDouble(),
        top: (json['top'] as num).toDouble(),
        width: (json['width'] as num).toDouble(),
        height: (json['height'] as num).toDouble(),
      );
}

/// Compact description of the actionable target under a touch.
class PmkitTargetAnchor {
  const PmkitTargetAnchor({
    this.schemaVersion = 1,
    this.widgetType,
    this.role,
    this.fingerprint,
    this.fingerprintConfidence,
    this.tagFingerprint,
    this.fingerprintParts = const {},
    this.canonicalPath,
    this.relativePosition,
    this.enabled,
    this.actions = const [],
  });

  final int schemaVersion;
  final String? widgetType;
  final String? role;
  final String? fingerprint;
  final String? fingerprintConfidence;
  final String? tagFingerprint;

  /// Stable fields used to derive [fingerprint]. Dynamic labels are excluded.
  final Map<String, String> fingerprintParts;

  /// Canonical structural path used to identify this target within its route.
  final String? canonicalPath;
  final String? relativePosition;
  final bool? enabled;
  final List<String> actions;

  Map<String, Object?> toJson() => {
    if (schemaVersion != 1) 'schemaVersion': schemaVersion,
    if (widgetType != null) 'widgetType': widgetType,
    if (role != null) 'role': role,
    if (fingerprint != null && fingerprint!.isNotEmpty)
      'fingerprint': fingerprint,
    if (fingerprintConfidence != null && fingerprintConfidence!.isNotEmpty)
      'fingerprintConfidence': fingerprintConfidence,
    if (tagFingerprint != null && tagFingerprint!.isNotEmpty)
      'tagFingerprint': tagFingerprint,
    if (fingerprintParts.isNotEmpty) 'fingerprintParts': fingerprintParts,
    if (canonicalPath != null && canonicalPath!.isNotEmpty)
      'canonicalPath': canonicalPath,
    if (relativePosition != null) 'relativePosition': relativePosition,
    if (enabled != null) 'enabled': enabled,
    if (actions.isNotEmpty) 'actions': actions,
  };

  factory PmkitTargetAnchor.fromJson(Map<String, dynamic> json) =>
      PmkitTargetAnchor(
        schemaVersion: json['schemaVersion'] as int? ?? 1,
        widgetType: json['widgetType'] as String?,
        role: json['role'] as String?,
        fingerprint: json['fingerprint'] as String?,
        fingerprintConfidence: json['fingerprintConfidence'] as String?,
        tagFingerprint: json['tagFingerprint'] as String?,
        fingerprintParts: json['fingerprintParts'] == null
            ? const {}
            : Map<String, String>.from(json['fingerprintParts'] as Map),
        canonicalPath: json['canonicalPath'] as String?,
        relativePosition: json['relativePosition'] as String?,
        enabled: json['enabled'] as bool?,
        actions: (json['actions'] as List<dynamic>? ?? [])
            .cast<String>()
            .toList(),
      );

  @override
  bool operator ==(Object other) =>
      other is PmkitTargetAnchor &&
      schemaVersion == other.schemaVersion &&
      widgetType == other.widgetType &&
      role == other.role &&
      fingerprint == other.fingerprint &&
      fingerprintConfidence == other.fingerprintConfidence &&
      tagFingerprint == other.tagFingerprint &&
      _mapEquals(fingerprintParts, other.fingerprintParts) &&
      canonicalPath == other.canonicalPath &&
      relativePosition == other.relativePosition &&
      enabled == other.enabled &&
      _listEquals(actions, other.actions);

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    widgetType,
    role,
    fingerprint,
    fingerprintConfidence,
    tagFingerprint,
    _stringMapHash(fingerprintParts),
    canonicalPath,
    relativePosition,
    enabled,
    Object.hashAll(actions),
  );
}

/// Compact canonical signature of the current screen state.
class PmkitStateAnchor {
  const PmkitStateAnchor({
    this.schemaVersion = 1,
    this.actionableSummary = const {},
    this.keyboardOpen = false,
    this.modalOpen = false,
    this.subLabel,
    this.signature = '',
    this.signatureConfidence,
    this.signatureParts = const {},
  });

  final int schemaVersion;

  /// Aggregate role counts (for example `button: 3`) used as compact state
  /// signature metadata. This is not a per-control inventory and must not be
  /// used to discover individual tap targets; use screenshots for that instead.
  final Map<String, int> actionableSummary;
  final bool keyboardOpen;
  final bool modalOpen;
  final String? subLabel;
  final String signature;
  final String? signatureConfidence;

  /// Stable fields used to derive [signature]. Dynamic labels are excluded.
  final Map<String, String> signatureParts;

  Map<String, Object?> toJson() => {
    if (schemaVersion != 1) 'schemaVersion': schemaVersion,
    if (actionableSummary.isNotEmpty) 'actionableSummary': actionableSummary,
    if (keyboardOpen) 'keyboardOpen': keyboardOpen,
    if (modalOpen) 'modalOpen': modalOpen,
    if (subLabel != null && subLabel!.isNotEmpty) 'subLabel': subLabel,
    if (signature.isNotEmpty) 'signature': signature,
    if (signatureConfidence != null && signatureConfidence!.isNotEmpty)
      'signatureConfidence': signatureConfidence,
    if (signatureParts.isNotEmpty) 'signatureParts': signatureParts,
  };

  factory PmkitStateAnchor.fromJson(Map<String, dynamic> json) =>
      PmkitStateAnchor(
        schemaVersion: json['schemaVersion'] as int? ?? 1,
        actionableSummary: json['actionableSummary'] == null
            ? _summaryFromRoles(json['actionableRoles'] as List<dynamic>?)
            : Map<String, int>.from(json['actionableSummary'] as Map),
        keyboardOpen: json['keyboardOpen'] as bool? ?? false,
        modalOpen: json['modalOpen'] as bool? ?? false,
        subLabel: json['subLabel'] as String?,
        signature: json['signature'] as String? ?? '',
        signatureConfidence: json['signatureConfidence'] as String?,
        signatureParts: json['signatureParts'] == null
            ? const {}
            : Map<String, String>.from(json['signatureParts'] as Map),
      );

  @override
  bool operator ==(Object other) =>
      other is PmkitStateAnchor &&
      schemaVersion == other.schemaVersion &&
      keyboardOpen == other.keyboardOpen &&
      modalOpen == other.modalOpen &&
      subLabel == other.subLabel &&
      signature == other.signature &&
      signatureConfidence == other.signatureConfidence &&
      _mapEquals(signatureParts, other.signatureParts) &&
      _mapEquals(actionableSummary, other.actionableSummary);

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    keyboardOpen,
    modalOpen,
    subLabel,
    signature,
    signatureConfidence,
    _stringMapHash(signatureParts),
    Object.hashAll(
      actionableSummary.entries.map((entry) => '${entry.key}:${entry.value}'),
    ),
  );
}

/// One salient element in a screen's structural inventory.
class PmkitSceneInventoryEntry {
  const PmkitSceneInventoryEntry({
    required this.fingerprint,
    required this.canonicalPath,
    this.widgetType,
    this.role,
    this.actions = const [],
    this.enabled,
    required this.boundsNorm,
    required this.tier,
    this.aliases = const [],
  });

  final String fingerprint;
  final String canonicalPath;
  final String? widgetType;
  final String? role;
  final List<String> actions;
  final bool? enabled;
  final PmkitNormalizedBounds boundsNorm;
  final String tier;

  /// Alternate structural fingerprints for the same control (wrapper layers).
  final List<String> aliases;

  Map<String, Object?> toJson() => {
    'fingerprint': fingerprint,
    'canonicalPath': canonicalPath,
    if (widgetType != null) 'widgetType': widgetType,
    if (role != null) 'role': role,
    if (actions.isNotEmpty) 'actions': actions,
    if (enabled != null) 'enabled': enabled,
    'boundsNorm': boundsNorm.toJson(),
    'tier': tier,
    if (aliases.isNotEmpty) 'aliases': aliases,
  };

  PmkitSceneInventoryEntry copyWith({
    List<String>? aliases,
  }) {
    return PmkitSceneInventoryEntry(
      fingerprint: fingerprint,
      canonicalPath: canonicalPath,
      widgetType: widgetType,
      role: role,
      actions: actions,
      enabled: enabled,
      boundsNorm: boundsNorm,
      tier: tier,
      aliases: aliases ?? this.aliases,
    );
  }
}

/// Structural inventory of salient elements on a settled screen state.
class PmkitSceneInventory {
  const PmkitSceneInventory({
    required this.stateAnchor,
    required this.stateSignature,
    required this.inventoryHash,
    required this.routeKey,
    required this.elements,
  });

  /// Anchor the inventory was computed against; not serialized into [toJson].
  final PmkitStateAnchor stateAnchor;
  final String stateSignature;
  final String inventoryHash;
  final String routeKey;
  final List<PmkitSceneInventoryEntry> elements;

  Map<String, Object?> toJson() => {
    'stateSignature': stateSignature,
    'inventoryHash': inventoryHash,
    'routeKey': routeKey,
    'elements': elements.map((entry) => entry.toJson()).toList(),
  };
}
