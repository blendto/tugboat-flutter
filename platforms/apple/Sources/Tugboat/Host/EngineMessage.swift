/// One message for the engine: `{"type", "at"?, "input"}`.
///
/// `inputJSON` is the caller's encoded `input` object; the envelope is built
/// around it by concatenation, never re-encoded. `at` is the time the fact
/// happened; it is nil only for messages the engine takes without one
/// (`engine.configure`, queries, stateless messages). `frameHandles` are the
/// frame-table handles the message hands to the engine: the host releases
/// them if the engine does not accept the message.
struct EngineMessage {
  let type: String
  let inputJSON: String
  let at: HostTime?
  var frameHandles: [String] = []

  var json: String {
    var out = "{\"type\":" + JSONText.quoted(type)
    if let at = at {
      out += ",\"at\":" + at.json
    }
    out += ",\"input\":" + inputJSON + "}"
    return out
  }

  /// One `batch` message applying `messages` in order, all or nothing.
  static func batchJSON(_ messages: [EngineMessage]) -> String {
    "{\"type\":\"batch\",\"messages\":[" + messages.map { $0.json }.joined(separator: ",") + "]}"
  }
}
