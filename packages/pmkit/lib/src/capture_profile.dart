/// Controls how much instrumentation the SDK installs in a host app.
enum PmkitCaptureProfile {
  /// No capture machinery until [PmkitReplay.activate] is called.
  dormant,

  /// Full capture for graphing and deep diagnostics.
  exploration,

  /// Fingerprints plus sampled screenshots for real user sessions.
  productionLean,
}
