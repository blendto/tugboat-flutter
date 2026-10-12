/// `capture.result` vocabulary the engine is gaining (PR #96, branch
/// `engine/mask-coverage`): `frame.maskCoverage {mode, reasons}`. The
/// engine rejects unknown frame keys, and a rejected `capture.result`
/// loses its frame, so it stays off until that engine change is on this
/// branch. iOS never sends the other addition, `failure: secureWindow`.
///
/// TODO(ADR 0009, engine/mask-coverage): set to true when it merges.
enum EngineVocabulary {
  /// Off: the SwiftUI mask coverage is computed but not sent.
  static let frameMaskCoverage = false
}
