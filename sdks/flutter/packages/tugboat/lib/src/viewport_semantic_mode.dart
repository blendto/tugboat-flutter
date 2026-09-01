/// How aggressively the SDK builds and emits viewport semantic maps.
enum TugboatViewportSemanticMode {
  /// No semantic engine.
  off,

  /// Build maps on-device for tap verdicts only; do not emit map events.
  tapResolutionOnly,

  /// Build and emit full semantic map / scroll snapshot events in exploration.
  /// Production uses this as tap-resolution-only to avoid uploading maps.
  full,

  /// Same as [full], plus debugPrint diagnostics in exploration.
  fullWithDebugLogs,
}
