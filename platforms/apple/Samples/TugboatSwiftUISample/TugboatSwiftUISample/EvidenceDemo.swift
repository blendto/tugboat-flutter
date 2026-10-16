import Foundation
import SwiftUI
import Tugboat

/// One coded event and one manual network call, as an app forwards its own
/// analytics events and observes its own requests.
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

      Button(orderStatus) { loadOrder() }
        .tugboatTag("load-order")
    }
    .buttonStyle(.bordered)
  }

  /// A stand-in request: begins on the main thread, finishes on a background
  /// queue with a 404 and a JSON error body (kept because the status is 400
  /// or more).
  private func loadOrder() {
    let call = Tugboat.beginNetworkCall(method: "GET", route: "/orders/42")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      call.complete(statusCode: 404, errorResponseBody: ["error": "order_not_found"])
      DispatchQueue.main.async { orderStatus = "Order: 404" }
    }
  }
}
