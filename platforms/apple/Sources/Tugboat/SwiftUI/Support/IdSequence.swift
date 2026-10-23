/// A thread-safe sequence of positive ids, for opaque ids that must never
/// repeat within the process (pointer contacts, screen and tag instances).
/// It wraps to 1 instead of overflowing.
final class IdSequence {
  private let next = Locked<Int64>(1)

  func nextValue() -> Int64 {
    next.withLock { (value: inout Int64) -> Int64 in
      defer { value = value == Int64.max ? 1 : value + 1 }
      return value
    }
  }

  /// `"<prefix>-<n>"`.
  func nextId(prefix: String) -> String {
    "\(prefix)-\(nextValue())"
  }
}
