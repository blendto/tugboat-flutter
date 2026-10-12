import Foundation

/// One finger (or pencil, or pointer button) from its began to its ended or
/// cancelled.
final class Contact {
  let contactId: Int64
  let down: CGPoint
  private(set) var last: CGPoint
  /// Largest distance from the down point so far, in points.
  private(set) var maxTravel: Double = 0

  init(contactId: Int64, down: CGPoint) {
    self.contactId = contactId
    self.down = down
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
  private static let nextContactId = Locked<Int64>(1)

  private var active: [ObjectIdentifier: Contact] = [:]

  var isEmpty: Bool {
    active.isEmpty
  }

  mutating func begin(_ key: ObjectIdentifier, at point: CGPoint) -> Contact {
    let id = PointerContacts.nextContactId.withLock { (next: inout Int64) -> Int64 in
      let current = next
      next = next == Int64.max ? 1 : next + 1
      return current
    }
    let contact = Contact(contactId: id, down: point)
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
