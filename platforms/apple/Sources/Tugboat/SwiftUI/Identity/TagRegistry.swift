#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// The frames of views marked `.tugboatTag`, as their modifiers report them
/// through anchor preferences (native SDK note section 6.3). Tags are the
/// first identity source for a tap: SwiftUI drawing has no UIKit view and
/// the in-process accessibility tree is empty.
///
/// - Frames are in SwiftUI's `.global` space: the root hosting view of the
///   tagged view's hierarchy (`AnchorResolver` converts the tap point into
///   it).
/// - Each entry records the `.tugboatScreen` instance it is inside, if any,
///   so a screen covered by a sheet cannot win a tap meant for the sheet.
/// - Entries leave when their view disappears.
///
/// Thread-safe; SwiftUI writes from the main thread.
final class TagRegistry {
  static let shared = TagRegistry()
  private static let nextId = Locked<Int64>(1)

  struct Entry: Equatable {
    let tag: String
    /// The `.tugboatScreen` instance id around the tagged view.
    let screen: String?
    let frame: CGRect
  }

  private let entries = Locked([Int64: Entry]())

  static func newId() -> Int64 {
    nextId.withLock { (next: inout Int64) -> Int64 in
      defer { next = next == Int64.max ? 1 : next + 1 }
      return next
    }
  }

  func update(id: Int64, entry: Entry) {
    entries.withLock { $0[id] = entry }
  }

  func remove(id: Int64) {
    entries.withLock { $0[id] = nil }
  }

  func removeAll() {
    entries.withLock { $0.removeAll() }
  }

  /// Every entry, in registration order.
  var all: [Entry] {
    entries.withLock { $0.sorted { $0.key < $1.key }.map { $0.value } }
  }

  /// The tag at `point` (in the `.global` space): the smallest tagged frame
  /// containing it. With a `screen` (the top `.tugboatScreen`), frames
  /// inside that screen win, then frames outside any screen; frames inside
  /// other screens never match.
  func entry(at point: CGPoint, screen: String?) -> Entry? {
    let hits = all.filter { !$0.frame.isEmpty && $0.frame.contains(point) }
    let candidates: [Entry]
    if let screen = screen {
      let own = hits.filter { $0.screen == screen }
      candidates = own.isEmpty ? hits.filter { $0.screen == nil } : own
    } else {
      candidates = hits
    }
    return candidates.min { area($0.frame) < area($1.frame) }
  }

  private func area(_ frame: CGRect) -> Double {
    Double(frame.width * frame.height)
  }
}
