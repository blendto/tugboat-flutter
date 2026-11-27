/// The `evidence.externalEvent` and `evidence.networkCall` inputs
/// (core/session-engine/docs/evidence-messages.md section 1). The engine
/// validates and bounds every field and applies the parameter policy and
/// the error-body rule, so name, source, method, and route are sent raw. The
/// host runs a `transform` (`HostParameters`) and encodes typed values
/// (`EvidenceEncoder`).
enum EvidenceMessages {
  static let externalEvent = "evidence.externalEvent"
  static let networkCall = "evidence.networkCall"

  /// `{name, source?, policy {mode, allowedKeys?}, parameters?}`; the fact
  /// time is the message's `at`.
  static func externalEventInput(
    name: String, source: String?, policy: TugboatParameterPolicy, parameters: [String: Any]?
  ) -> String {
    var out = "{\"name\":" + JSONText.quoted(name)
    if let source = source {
      out += ",\"source\":" + JSONText.quoted(source)
    }
    out += ",\"policy\":" + policyJSON(policy)
    if let parameters = parameters, !parameters.isEmpty {
      out += ",\"parameters\":" + EvidenceEncoder.parameters(HostParameters.apply(policy, to: parameters))
    }
    return out + "}"
  }

  /// `{mode, allowedKeys?}`; allowed keys sorted by `String <`.
  static func policyJSON(_ policy: TugboatParameterPolicy) -> String {
    var out = "{\"mode\":" + JSONText.quoted(policy.mode)
    if case let .allowList(keys) = policy {
      out += ",\"allowedKeys\":[" + keys.sorted().map(JSONText.quoted).joined(separator: ",") + "]"
    }
    return out + "}"
  }

  /// `{method, route, startMonoUs, endMonoUs, statusCode?, outcome,
  /// attemptCount?, errorResponseBody?}`. The body is read only for a
  /// status of 400 or more (section 4.5).
  static func networkCallInput(_ call: NetworkCallFacts) -> String {
    var out = "{\"method\":" + JSONText.quoted(call.method)
    out += ",\"route\":" + JSONText.quoted(call.route)
    out += ",\"startMonoUs\":\(call.startMonoUs)"
    out += ",\"endMonoUs\":\(call.endMonoUs)"
    if let statusCode = call.statusCode {
      out += ",\"statusCode\":\(statusCode)"
    }
    out += ",\"outcome\":" + JSONText.quoted(call.outcome)
    if let attemptCount = call.attemptCount {
      out += ",\"attemptCount\":\(attemptCount)"
    }
    if let statusCode = call.statusCode, statusCode >= 400, let body = call.errorResponseBody,
      let encoded = EvidenceEncoder.errorResponseBody(body)
    {
      out += ",\"errorResponseBody\":" + encoded
    }
    return out + "}"
  }
}

/// One finished network call as the app reported it.
struct NetworkCallFacts {
  let method: String
  let route: String
  let startMonoUs: Int64
  let endMonoUs: Int64
  let statusCode: Int?
  /// `response`, `network_error`, or `cancelled`.
  let outcome: String
  let attemptCount: Int?
  let errorResponseBody: Any?
}
