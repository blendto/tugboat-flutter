import Foundation

@testable import Tugboat

/// A host clock tests move by hand.
final class ManualClock: HostClock {
  var monoUs: Int64
  var wallOffsetUs: Int64 = 1_700_000_000_000_000

  init(monoUs: Int64 = 10_000_000) {
    self.monoUs = monoUs
  }

  func now() -> HostTime {
    HostTime(monoUs: monoUs, wallUs: monoUs + wallOffsetUs)
  }

  func advance(ms: Int64) {
    monoUs += ms * 1000
  }
}

/// Frames that run only when the test says so.
final class ManualFrames: FrameScheduler {
  private var callbacks: [() -> Void] = []
  private(set) var scheduled = 0
  private(set) var invalidated = false

  var pending: Int {
    callbacks.count
  }

  func scheduleFrame(_ callback: @escaping () -> Void) {
    scheduled += 1
    callbacks.append(callback)
  }

  func invalidate() {
    invalidated = true
    callbacks.removeAll()
  }

  /// Runs the callbacks armed so far.
  func runFrame() {
    let due = callbacks
    callbacks.removeAll()
    due.forEach { $0() }
  }
}

/// Records every batch posted to it, decoded.
final class RecordingSink: FactSink {
  private(set) var batches: [[EngineMessage]] = []

  func postBatch(_ messages: [EngineMessage]) {
    batches.append(messages)
  }

  var messages: [EngineMessage] {
    batches.flatMap { $0 }
  }

  /// Each message as decoded JSON, in post order.
  var decoded: [[String: Any]] {
    messages.compactMap { decodeObject($0.json) }
  }
}

func decodeObject(_ json: String) -> [String: Any]? {
  guard let data = json.data(using: .utf8) else { return nil }
  return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

extension AdapterFact {
  /// The input, decoded.
  var decodedInput: [String: Any] {
    decodeObject(input.json) ?? [:]
  }
}
