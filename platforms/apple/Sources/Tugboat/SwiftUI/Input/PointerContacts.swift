#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// One finger (or pencil, or pointer button) from its began to its ended or
/// cancelled.
final class Contact {
  let contactId: Int64
  let down: CGPoint
  let device: PointerDevice
  private(set) var last: CGPoint
  /// Largest distance from the down point so far, in points.
  private(set) var maxTravel: Double = 0

  init(contactId: Int64, down: CGPoint, device: PointerDevice) {
    self.contactId = contactId
    self.down = down
    self.device = device
    self.last = down
  }

  func move(to point: CGPoint) {
    last = point
    let travel = Double(hypot(point.x - down.x, point.y - down.y))
    if travel.isFinite, travel > maxTravel {
      maxTravel = travel
    }
  }
}

/// Maps live touches to engine `pointerId`s. The engine requires a unique
/// id per contact (it cancels a released tap when an id is reused), so each
/// began gets the next id of one process-wide, increasing counter, and
/// windows tracked by separate recognizers never share an id.
struct PointerContacts {
  private static let contactIds = IdSequence()

  private var active: [ObjectIdentifier: Contact] = [:]

  var isEmpty: Bool {
    active.isEmpty
  }

  mutating func begin(_ key: ObjectIdentifier, at point: CGPoint, device: PointerDevice) -> Contact {
    let contact = Contact(contactId: PointerContacts.contactIds.nextValue(), down: point, device: device)
    active[key] = contact
    return contact
  }

  subscript(key: ObjectIdentifier) -> Contact? {
    active[key]
  }

  mutating func end(_ key: ObjectIdentifier) -> Contact? {
    active.removeValue(forKey: key)
  }

  /// Removes and returns every active contact, oldest id first.
  mutating func endAll() -> [Contact] {
    let all = active.values.sorted { $0.contactId < $1.contactId }
    active.removeAll()
    return all
  }
}
