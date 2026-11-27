/// Stable opaque ids for objects, one per instance for its lifetime
/// (`scrollableId`, hosting-controller route instances). Keys are weak: an
/// entry whose object is gone is pruned, and a reused address gets a new id
/// because the entry no longer points at the same object. Thread-safe.
final class ObjectIds {
  private struct Entry {
    weak var object: AnyObject?
    let id: String
  }

  private let prefix: String
  private let sequence = IdSequence()
  private let entries = Locked([ObjectIdentifier: Entry]())

  init(prefix: String) {
    self.prefix = prefix
  }

  /// The id of `object`, minted on first use.
  func id(of object: AnyObject) -> String {
    let key = ObjectIdentifier(object)
    return entries.withLock { entries -> String in
      if let entry = entries[key], entry.object === object {
        return entry.id
      }
      entries = entries.filter { $0.value.object != nil }
      let id = sequence.nextId(prefix: prefix)
      entries[key] = Entry(object: object, id: id)
      return id
    }
  }

  /// The id of `object` if one was minted, without minting one.
  func existingId(of object: AnyObject) -> String? {
    entries.withLock { entries -> String? in
      guard let entry = entries[ObjectIdentifier(object)], entry.object === object else { return nil }
      return entry.id
    }
  }
}
