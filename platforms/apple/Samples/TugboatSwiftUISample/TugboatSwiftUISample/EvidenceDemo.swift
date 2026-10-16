import Foundation
import SwiftUI
import Tugboat

/// One coded event and one network call through an instrumented
/// `URLSession`, as an app forwards its own analytics events and observes
/// its own requests.
struct EvidenceDemo: View {
  /// Kept for the app's lifetime: each `record` goes to the running session.
  private static let analytics = Tugboat.eventHook(source: "analytics", parameterPolicy: .allowList(["method"]))

  @State private var orderStatus = "Load order"

  var body: some View {
    HStack {
      Button("Log in (event)") {
        // `method` is kept; `email` is reported as a key without its value.
        Self.analytics.record("USER_LOGIN", parameters: ["method": "email", "email": "user@example.com"])
      }
      .tugboatTag("log-in-event")

      Button(orderStatus) {
        OrderClient.shared.loadOrder { status in orderStatus = status }
      }
      .tugboatTag("load-order")
    }
    .buttonStyle(.bordered)
  }
}

/// The sample's API client: a delegate-based `URLSession` made by
/// `Tugboat.instrumentedSession`, so each request is a `network_call` and an
/// error response keeps its body. `GET <collector>/orders/42` is a path the
/// local collector does not serve: it answers 404 with a short text body.
final class OrderClient: NSObject, URLSessionDataDelegate {
  static let shared = OrderClient()

  private lazy var session = Tugboat.instrumentedSession(
    configuration: .ephemeral, delegate: self, delegateQueue: .main
  ) { request in
    // The app's own route for the request: its path, never the full URL.
    request.url?.path
  }
  private var received = Data()
  private var onFinish: ((String) -> Void)?

  /// Main thread.
  func loadOrder(onFinish: @escaping (String) -> Void) {
    guard let base = SampleConfiguration.tugboat()?.collector.baseURL else { return }
    self.onFinish = onFinish
    received = Data()
    session.dataTask(with: base.appendingPathComponent("orders/42")).resume()
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    received.append(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let status = (task.response as? HTTPURLResponse).map { "Order: \($0.statusCode)" } ?? "Order: failed"
    onFinish?(status)
    onFinish = nil
  }
}
