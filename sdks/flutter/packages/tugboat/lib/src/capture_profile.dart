/// Controls how much instrumentation the SDK installs in a host app.
enum TugboatCaptureProfile {
  /// No capture machinery until [TugboatReplay.activate] is called.
  dormant,

  /// Full capture for graphing and deep diagnostics.
  exploration,

  /// Fingerprints plus sampled screenshots for real user sessions.
  productionLean,
}
