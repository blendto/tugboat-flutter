/// Converts the app's typed values to the engine's input value encoding.
///
/// CONTRACT PENDING: the value encoding and the host obligations come with
/// the engine's `evidence.*` contract. Until then nothing is encoded, so the
/// inputs carry no `parameters` and no `errorResponseBody`.
enum EvidenceEncoder {
  /// The `parameters` input value, or nil to omit it.
  static func parameters(_ parameters: [HostParameter]) -> String? {
    nil
  }

  /// The `errorResponseBody` input value, or nil for no body.
  static func errorResponseBody(_ body: Any) -> String? {
    nil
  }
}
