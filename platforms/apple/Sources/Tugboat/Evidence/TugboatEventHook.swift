/// Records the app's own coded events (for example analytics events) as
/// `external_event` evidence. Get one from
/// `Tugboat.eventHook(source:parameterPolicy:)`.
///
/// A hook holds no session: each `record` goes to the session running at
/// that moment, and does nothing while Tugboat is not started, stopped, or
/// disabled. Safe to share and to call from any thread; it never throws or
/// traps into the app.
public final class TugboatEventHook: @unchecked Sendable {
  // Immutable after init; the channel is thread-safe.
  private let source: String?
  private let policy: TugboatParameterPolicy
  private let channel: EvidenceChannel

  init(source: String?, policy: TugboatParameterPolicy, channel: EvidenceChannel) {
    self.source = source
    self.policy = policy
    self.channel = channel
  }

  /// Records one event named `name` (for example `USER_LOGIN`).
  ///
  /// `parameters` holds JSON-like values: strings, numbers, booleans,
  /// `NSNull`, and arrays and string-keyed dictionaries of them. Other
  /// values are dropped and reported. The time is taken, and a `transform`
  /// policy runs, on the calling thread; the values are read before this
  /// returns.
  public func record(_ name: String, parameters: [String: Any]? = nil) {
    let at = channel.now()
    guard let generation = channel.admit() else { return }
    let input = EvidenceMessages.externalEventInput(
      name: name, source: source, policy: policy, parameters: parameters)
    channel.submit(type: EvidenceMessages.externalEvent, inputJSON: input, at: at, generation: generation)
  }
}
