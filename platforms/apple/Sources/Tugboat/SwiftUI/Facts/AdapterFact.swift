/// One fact the SwiftUI adapter observed: an engine message `type`, its
/// `input` object, and the time the fact happened (not when it is posted).
struct AdapterFact: Equatable {
  let type: String
  let input: JSONObject
  let at: HostTime

  var message: EngineMessage {
    EngineMessage(type: type, inputJSON: input.json, at: at)
  }
}

/// The engine message types the adapter produces (stateful-engine.md
/// sections 8.1 and 9.1).
enum FactTypes {
  static let pointer = "input.pointer"
  static let scroll = "scroll"
  static let focus = "focus"
  /// Phase 3d: the engine on this branch rejects this type until navigation
  /// lands (decisions log).
  static let navigation = "navigation"
}

/// Where per-frame batches go: `EngineHost.postBatch` in the SDK.
protocol FactSink: AnyObject {
  func postBatch(_ messages: [EngineMessage])
}

extension EngineHost: FactSink {}
