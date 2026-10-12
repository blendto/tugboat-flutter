import Foundation

/// Turns touch samples into `input.pointer` facts (stateful-engine.md 9.1).
///
/// - One fact per touch per delivery: `down`, `move`, `up`, `cancel`.
///   Coalesced intermediate samples are not sent.
/// - `x`, `y` are points in window coordinates; `at.monoUs` is the touch's
///   own timestamp.
/// - On `up`, when the contact never travelled `touchSlop` or more (the
///   engine's swipe test is `distance >= touchSlop`), `resolveTap` resolves
///   the target at the **down** position against the current tree, and the
///   fact carries `tap`.
///
/// Free of UIKit so it can be tested with injected samples. Main thread only.
final class PointerFactBuilder {
  private let clock: FactClock
  private let gesture: GestureConfig
  private let resolveTap: (CGPoint) -> TapEvidence
  private var contacts = PointerContacts()

  init(clock: FactClock, gesture: GestureConfig, resolveTap: @escaping (CGPoint) -> TapEvidence) {
    self.clock = clock
    self.gesture = gesture
    self.resolveTap = resolveTap
  }

  var hasActiveContacts: Bool {
    !contacts.isEmpty
  }

  /// The facts for `sample`: none for a touch the builder never saw begin.
  func facts(for sample: TouchSample) -> [AdapterFact] {
    let at = clock.at(uptime: sample.uptime)
    switch sample.phase {
    case .began:
      return begin(sample, at: at)
    case .moved:
      guard let contact = contacts[sample.key] else { return [] }
      contact.move(to: sample.location)
      return [fact(contact.contactId, "move", sample.location, sample.device, at: at)]
    case .ended:
      guard let contact = contacts.end(sample.key) else { return [] }
      contact.move(to: sample.location)
      var input = PointerFactBuilder.input(contact.contactId, "up", sample.location, sample.device)
      if contact.maxTravel < gesture.touchSlop {
        input.set("tap", resolveTap(contact.down).json)
      }
      return [AdapterFact(type: FactTypes.pointer, input: input, at: at)]
    case .cancelled:
      guard let contact = contacts.end(sample.key) else { return [] }
      return [fact(contact.contactId, "cancel", sample.location, sample.device, at: at)]
    }
  }

  /// Cancels every open contact, at its last position: the recognizer was
  /// reset or detached before their ended arrived.
  func cancelAll() -> [AdapterFact] {
    let at = clock.now()
    return contacts.endAll().map { fact($0.contactId, "cancel", $0.last, .touch, at: at) }
  }

  private func begin(_ sample: TouchSample, at: HostTime) -> [AdapterFact] {
    var out: [AdapterFact] = []
    // A began for a touch still open means its end was never delivered.
    if let stale = contacts.end(sample.key) {
      out.append(fact(stale.contactId, "cancel", stale.last, sample.device, at: at))
    }
    let contact = contacts.begin(sample.key, at: sample.location)
    out.append(fact(contact.contactId, "down", sample.location, sample.device, at: at))
    return out
  }

  private func fact(
    _ id: Int64, _ phase: String, _ point: CGPoint, _ device: PointerDevice, at: HostTime
  ) -> AdapterFact {
    AdapterFact(type: FactTypes.pointer, input: PointerFactBuilder.input(id, phase, point, device), at: at)
  }

  private static func input(_ id: Int64, _ phase: String, _ point: CGPoint, _ device: PointerDevice) -> JSONObject {
    var input = JSONObject()
    input.set("pointerId", id)
    input.set("phase", phase)
    input.set("x", Double(point.x))
    input.set("y", Double(point.y))
    input.set("device", device.rawValue)
    return input
  }
}
