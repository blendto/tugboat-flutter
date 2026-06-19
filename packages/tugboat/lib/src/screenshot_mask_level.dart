/// Controls which visible content is redacted from captured screenshots.
enum TugboatScreenshotMaskLevel {
  /// Redact only subtrees wrapped in `TugboatSensitive`.
  explicitOnly,

  /// Redact all text, editable fields, and rendered images.
  allTextAndMedia,

  /// Redact all text and editable fields.
  allText,

  /// Redact non-actionable text while leaving control labels visible.
  allTextExceptActionable,

  /// Redact only inputs likely to contain private values.
  sensitiveInputsOnly,
}
