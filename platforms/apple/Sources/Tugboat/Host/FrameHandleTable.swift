import Foundation

/// Host-side store of encoded frames. The engine only ever sees the opaque
/// handle; JPEG bytes stay here until a `frame.release` effect frees them, or
/// the host releases a handle whose message the engine did not accept.
/// Thread-safe: adapters put from the capture path, the IO queue reads at
/// send time, and the engine queue releases.
final class FrameHandleTable {
  private struct State {
    var frames: [String: Data] = [:]
    var lastId: UInt64 = 0
    var closed = false
  }

  private let state = Locked(State())

  var count: Int {
    state.withLock { $0.frames.count }
  }

  /// Stores `jpeg` and returns its new, never reused handle. After `close`
  /// the handle is still returned but the bytes are not kept.
  func put(_ jpeg: Data) -> String {
    state.withLock { (state: inout State) -> String in
      state.lastId &+= 1
      let handle = "frame-\(state.lastId)"
      if !state.closed {
        state.frames[handle] = jpeg
      }
      return handle
    }
  }

  /// The bytes for `handle`, or nil once released (or never stored).
  func get(_ handle: String) -> Data? {
    state.withLock { $0.frames[handle] }
  }

  /// Frees `handle`; false if it was not present.
  @discardableResult
  func release(_ handle: String) -> Bool {
    state.withLock { $0.frames.removeValue(forKey: handle) != nil }
  }

  /// Frees everything and stops keeping new frames.
  func close() {
    state.withLock { (state: inout State) in
      state.closed = true
      state.frames.removeAll()
    }
  }
}
