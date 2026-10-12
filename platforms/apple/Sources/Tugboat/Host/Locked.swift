import Foundation

/// A value guarded by a lock, for state read and written from several queues.
final class Locked<Value> {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  /// Runs `body` with exclusive access to the value.
  func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }

  var current: Value {
    withLock { $0 }
  }
}
