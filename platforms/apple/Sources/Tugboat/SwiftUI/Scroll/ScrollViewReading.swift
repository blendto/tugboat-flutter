#if canImport(UIKit)
import UIKit

/// Reads scroll positions and ids from `UIScrollView`s (SwiftUI `ScrollView`
/// is a `HostingScrollView`, `List` a collection or table view). Positions
/// are relative to the resting start of the content: `contentOffset` plus
/// the adjusted top / left inset, so an inset change alone (safe area,
/// keyboard, bars) is not a scroll.
enum ScrollViewReading {
  private static let ids = NSMapTable<UIScrollView, NSString>.weakToStrongObjects()
  private static var nextId: Int64 = 1

  /// A stable opaque `scrollableId`: one per scroll view instance, for its
  /// lifetime. Main thread only.
  static func id(of view: UIScrollView) -> String {
    if let id = ids.object(forKey: view) {
      return id as String
    }
    let id = "swiftui-scroll-\(nextId)"
    nextId = nextId == Int64.max ? 1 : nextId + 1
    ids.setObject(id as NSString, forKey: view)
    return id
  }

  /// The offset on both axes, 0 at the resting start.
  static func relativeOffset(of view: UIScrollView) -> CGPoint {
    let inset = view.adjustedContentInset
    return CGPoint(x: view.contentOffset.x + inset.left, y: view.contentOffset.y + inset.top)
  }

  /// The position at `relative` (default: now) along `axis`.
  static func metrics(of view: UIScrollView, axis: ScrollAxis, at relative: CGPoint? = nil) -> ScrollMetrics {
    let offset = relative ?? relativeOffset(of: view)
    let inset = view.adjustedContentInset
    switch axis {
    case .vertical:
      let extent = view.contentSize.height + inset.top + inset.bottom - view.bounds.height
      return ScrollMetrics(axis: axis, offset: Double(offset.y), maxExtent: Double(max(0, extent)))
    case .horizontal:
      let extent = view.contentSize.width + inset.left + inset.right - view.bounds.width
      return ScrollMetrics(axis: axis, offset: Double(offset.x), maxExtent: Double(max(0, extent)))
    }
  }

  /// The axis a move from `resting` went along: the only scrollable axis,
  /// else the one that moved more (vertical on a tie).
  static func axis(of view: UIScrollView, from resting: CGPoint) -> ScrollAxis {
    let canScrollX = metrics(of: view, axis: .horizontal).maxExtent > 0
    let canScrollY = metrics(of: view, axis: .vertical).maxExtent > 0
    if canScrollX != canScrollY {
      return canScrollX ? .horizontal : .vertical
    }
    let now = relativeOffset(of: view)
    return abs(now.x - resting.x) > abs(now.y - resting.y) ? .horizontal : .vertical
  }

  /// True when the view moved at least half a point from `resting`.
  static func hasMoved(_ view: UIScrollView, from resting: CGPoint) -> Bool {
    let now = relativeOffset(of: view)
    return abs(now.x - resting.x) >= 0.5 || abs(now.y - resting.y) >= 0.5
  }

  /// True while a finger or momentum drives the view.
  static func isUserDriven(_ view: UIScrollView) -> Bool {
    view.isTracking || view.isDragging || view.isDecelerating
  }

  /// True when the offset is past either end (rubber-banding).
  static func isOverscrolled(_ metrics: ScrollMetrics) -> Bool {
    metrics.offset < -0.5 || metrics.offset > metrics.maxExtent + 0.5
  }
}
#endif
