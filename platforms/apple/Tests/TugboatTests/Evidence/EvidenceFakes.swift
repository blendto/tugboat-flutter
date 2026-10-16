import Foundation

@testable import Tugboat

/// An engine host stand-in that records evidence posts.
final class RecordingEvidenceSink: EvidenceSink {
  struct Post {
    let type: String
    let inputJSON: String
    let at: HostTime

    var input: [String: Any] { jsonObject(inputJSON) }
  }

  private let state = Locked<(running: Bool, posts: [Post])>((true, []))

  var posts: [Post] { state.current.posts }

  var isRunning: Bool {
    get { state.current.running }
    set { state.withLock { $0.running = newValue } }
  }

  func postEvidence(type: String, inputJSON: String, at: HostTime) {
    state.withLock { $0.posts.append(Post(type: type, inputJSON: inputJSON, at: at)) }
  }
}

/// A channel on a fake clock whose main-thread hop is a serial test queue.
struct EvidenceFixture {
  let clock = FakeClock(monoUs: 1_000_000, wallUs: 2_000_000)
  let hop = DispatchQueue(label: "test.tugboat.evidence-hop")
  let sink = RecordingEvidenceSink()
  let channel: EvidenceChannel

  init(open: Bool = true) {
    let hop = self.hop
    channel = EvidenceChannel(clock: clock, schedule: { hop.async(execute: $0) })
    if open {
      channel.open(sink)
    }
  }

  /// Waits until every hop queued so far has run.
  func drain() {
    hop.sync {}
  }

  func hook(source: String? = "analytics", policy: TugboatParameterPolicy = .allowAll) -> TugboatEventHook {
    TugboatEventHook(source: source, policy: policy, channel: channel)
  }

  func begin(method: String = "GET", route: String? = "/orders/123") -> TugboatNetworkCall {
    TugboatNetworkCall.begin(method: method, route: route, channel: channel)
  }
}

struct TransformFailure: Error {}
