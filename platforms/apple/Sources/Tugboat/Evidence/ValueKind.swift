import Foundation

/// What a Swift value is in the engine's value encoding
/// (evidence-messages.md section 4.1).
///
/// Numbers and booleans are matched by their exact type, never by a
/// bridging cast (`as? Int` on an `NSNumber` or `as? Bool` on `1` would
/// change their kind). An `NSNumber` is told apart by its own type.
enum ValueKind {
  enum Collection {
    case list([Any])
    case iterable([Any])
    /// String-keyed entries sorted by `String <`, and how many keys are not strings.
    case map([(key: String, value: Any)], nonStringKeys: Int)
  }

  case null
  case bool(Bool)
  case integer(Int64)
  case double(Double)
  case string(String)
  /// `identity` is the instance of a reference type, for cycles.
  case collection(Collection, identity: ObjectIdentifier?)
  case unsupported

  static let unsupportedJSON = "{\"unsupported\":true}"

  static func of(_ value: Any?) -> ValueKind {
    guard let value = unwrap(value) else { return .null }
    let type = Swift.type(of: value)
    if let scalar = scalars[ObjectIdentifier(type)] {
      return scalar(value)
    }
    if type is AnyObject.Type {
      return ofObject(value as AnyObject)
    }
    if let string = value as? String {
      return .string(string)
    }
    return ofSwiftCollection(value)
  }

  /// True for an instance of a class. Such a value is only ever cast to a
  /// class: casting an `NSArray` to a Swift type (`String`, `Data`, a
  /// protocol) can bridge it, and its nested collections, whole.
  static func isObject(_ value: Any) -> Bool {
    Swift.type(of: value) is AnyObject.Type
  }

  /// The value inside any number of `Optional`s; nil for none.
  static func unwrap(_ value: Any?) -> Any? {
    guard let value = value else { return nil }
    if !isObject(value), let optional = value as? AnyOptional {
      return unwrap(optional.wrappedAny)
    }
    return value
  }

  /// A Swift `String` or an `NSString`.
  static func string(_ value: Any) -> String? {
    if isObject(value) {
      return (value as AnyObject as? NSString)?.description
    }
    return value as? String
  }

  /// True for `TugboatParameterPolicy.drop`.
  static func isDrop(_ value: Any?) -> Bool {
    guard let value = unwrap(value), !isObject(value) else { return false }
    return value is TugboatParameterDrop
  }

  /// True for a value that gives no error body: `NSNull` and `Data`.
  static func isNoBody(_ value: Any) -> Bool {
    if isObject(value) {
      let object = value as AnyObject
      return object is NSNull || object is NSData
    }
    return value is Data
  }

  /// `{"double": n}`; non-finite values and negative zero as strings.
  static func doubleJSON(_ value: Double) -> String {
    let number: String
    if value.isNaN {
      number = "\"NaN\""
    } else if value.isInfinite {
      number = value < 0 ? "\"-Infinity\"" : "\"Infinity\""
    } else if value == 0 && value.sign == .minus {
      number = "\"-0.0\""
    } else {
      // Swift's shortest round-trip form: `1.0`, `1e-05`, `1.5e+300`.
      number = value.description
    }
    return "{\"double\":" + number + "}"
  }

  private static let scalars: [ObjectIdentifier: (Any) -> ValueKind] = [
    ObjectIdentifier(Bool.self): { .bool($0 as? Bool ?? false) },
    ObjectIdentifier(Int.self): { int64($0 as? Int) },
    ObjectIdentifier(Int8.self): { int64($0 as? Int8) },
    ObjectIdentifier(Int16.self): { int64($0 as? Int16) },
    ObjectIdentifier(Int32.self): { int64($0 as? Int32) },
    ObjectIdentifier(Int64.self): { int64($0 as? Int64) },
    ObjectIdentifier(UInt.self): { int64($0 as? UInt) },
    ObjectIdentifier(UInt8.self): { int64($0 as? UInt8) },
    ObjectIdentifier(UInt16.self): { int64($0 as? UInt16) },
    ObjectIdentifier(UInt32.self): { int64($0 as? UInt32) },
    ObjectIdentifier(UInt64.self): { int64($0 as? UInt64) },
    ObjectIdentifier(Double.self): { ($0 as? Double).map { .double($0) } ?? .unsupported },
    ObjectIdentifier(Float.self): { ($0 as? Float).map { .double(Double($0)) } ?? .unsupported },
    ObjectIdentifier(CGFloat.self): { ($0 as? CGFloat).map { .double(Double($0)) } ?? .unsupported },
  ]

  /// An integer within Int64; a larger one (only `UInt`/`UInt64`) is unsupported.
  private static func int64<T: BinaryInteger>(_ value: T?) -> ValueKind {
    value.flatMap { Int64(exactly: $0) }.map { .integer($0) } ?? .unsupported
  }

  private static func ofNumber(_ number: NSNumber) -> ValueKind {
    if number is NSDecimalNumber {
      return .unsupported
    }
    if CFGetTypeID(number) == CFBooleanGetTypeID() {
      return .bool(number.boolValue)
    }
    switch String(cString: number.objCType) {
    case "f", "d":
      return .double(number.doubleValue)
    case "Q", "L", "I", "S", "C":
      return int64(number.uint64Value)
    default:
      return .integer(number.int64Value)
    }
  }

  /// Elements are read one by one, as the instances they are: a bulk read
  /// (`allObjects`, `Array(_:)`) can bridge nested collections to Swift
  /// values, which loses their identity and never ends on a cycle.
  private static func ofObject(_ object: AnyObject) -> ValueKind {
    if object is NSNull {
      return .null
    }
    if let number = object as? NSNumber {
      return ofNumber(number)
    }
    if let string = object as? NSString {
      return .string(string.description)
    }
    let identity = ObjectIdentifier(object)
    if let array = object as? NSArray {
      return .collection(.list((0..<array.count).map { array.object(at: $0) }), identity: identity)
    }
    if let dictionary = object as? NSDictionary {
      var entries: [(Any, Any)] = []
      entries.reserveCapacity(dictionary.count)
      let keys = dictionary.keyEnumerator()
      while let key = keys.nextObject() {
        entries.append((key, dictionary.object(forKey: key) ?? NSNull()))
      }
      return .collection(map(entries), identity: identity)
    }
    if let set = object as? NSSet {
      var items: [Any] = []
      let objects = set.objectEnumerator()
      while let item = objects.nextObject() {
        items.append(item)
      }
      return .collection(.iterable(items), identity: identity)
    }
    return .unsupported
  }

  private static func ofSwiftCollection(_ value: Any) -> ValueKind {
    if let array = value as? [Any] {
      return .collection(.list(array), identity: nil)
    }
    if let dictionary = value as? [AnyHashable: Any] {
      return .collection(map(dictionary.map { ($0.key.base, $0.value) }), identity: nil)
    }
    if let set = value as? Set<AnyHashable> {
      return .collection(.iterable(set.map { $0.base }), identity: nil)
    }
    return .unsupported
  }

  /// Sorted string keys and a count of the rest (section 4.2).
  private static func map(_ entries: [(Any, Any)]) -> Collection {
    var strings: [(key: String, value: Any)] = []
    strings.reserveCapacity(entries.count)
    for (key, value) in entries {
      if let key = string(key) {
        strings.append((key, value))
      }
    }
    strings.sort { $0.key < $1.key }
    return .map(strings, nonStringKeys: entries.count - strings.count)
  }
}

/// Lets `ValueKind.unwrap` see through an `Optional` held in an `Any`.
private protocol AnyOptional {
  var wrappedAny: Any? { get }
}

extension Optional: AnyOptional {
  fileprivate var wrappedAny: Any? {
    map { $0 as Any }
  }
}
