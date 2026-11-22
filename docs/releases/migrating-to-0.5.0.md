# Migrating to 0.5.0

This is a breaking release. Session JSON written by 0.5.0 uses schema version
`9` and no longer includes `controlValue`, `controlValueTransition`, or
`semanticAnnotation` in event `data`. Consumers reading historical schemas
`6`–`8` should treat those fields as optional historic data; new captures do
not provide them.

The public `package:tugboat/tugboat.dart` barrel no longer exports:

- `TugboatEncodedControlScalar`, `TugboatVisibleControlValue`,
  `TugboatControlValueScope`, `TugboatControlValue`, and
  `TugboatSemanticAnnotation`;
- `tugboatControlValueSchemaVersion`,
  `tugboatControlValueTransitionSchemaVersion`, and
  `tugboatSemanticAnnotationSchemaVersion`;
- `tugboatControlValueForWidget`,
  `tugboatControlValueFromSemanticsProperties`,
  `tugboatControlValueFromSemanticsNode`,
  `tugboatSemanticAnnotationFromProperties`,
  `tugboatSemanticAnnotationFromNode`,
  `tugboatMergeSemanticAnnotations`, and `tugboatMergeControlValues`.
