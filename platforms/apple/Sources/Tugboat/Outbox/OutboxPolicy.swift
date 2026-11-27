import Foundation

/// When the durable outbox is erased, in one place (W11 design section 3.5,
/// as agreed by Chinmay on 2026-10-27): at a `start` whose configuration has
/// `durableOutbox` false, and through `Tugboat.clearPendingData()`. Never on
/// `enabled` false: that is dormant until `activate`, and wiping then would
/// lose undelivered evidence on every launch of an app that activates later.
enum OutboxPolicy {
  /// Whether `Tugboat.start(config)` deletes every pending entry.
  static func wipeAtStart(_ config: TugboatConfig) -> Bool {
    !config.durableOutbox
  }

  /// The bounds `config` sets, each at least 1.
  static func bounds(_ config: TugboatConfig) -> OutboxBounds {
    OutboxBounds(
      maxBytes: max(1, config.outboxMaxBytes),
      maxEntries: max(1, config.outboxMaxEntries),
      maxAgeMs: max(1, config.outboxMaxAgeMs),
      maxAttempts: max(1, config.outboxMaxAttempts))
  }
}

/// Outbox bounds (W11 design section 3.4); `TugboatConfig` carries them.
struct OutboxBounds: Equatable {
  var maxBytes: Int
  var maxEntries: Int
  var maxAgeMs: Int
  var maxAttempts: Int

  static let `default` = OutboxBounds(
    maxBytes: 20 * 1024 * 1024, maxEntries: 1000, maxAgeMs: 72 * 60 * 60 * 1000, maxAttempts: 8)
}
