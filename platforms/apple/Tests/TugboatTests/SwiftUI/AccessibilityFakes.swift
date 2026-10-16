#if canImport(UIKit)
import UIKit

@testable import Tugboat

/// An accessibility container that is not an element, with its child reads
/// counted (a container the descent must not enter keeps 0).
final class FakeAXContainer: NSObject {
  let frame: CGRect
  var children: [NSObject]
  private(set) var childReads = 0

  init(_ frame: CGRect, _ children: [NSObject] = []) {
    self.frame = frame
    self.children = children
  }

  override var accessibilityElements: [Any]? {
    get {
      childReads += 1
      return children
    }
    set {}
  }

  override var accessibilityFrame: CGRect {
    get { frame }
    set {}
  }

  override var isAccessibilityElement: Bool {
    get { false }
    set {}
  }
}

/// A container that exposes its children only through
/// `accessibilityElementCount()` and `accessibilityElement(at:)`.
final class FakeAXCountedContainer: NSObject {
  let frame: CGRect
  let children: [NSObject]

  init(_ frame: CGRect, _ children: [NSObject]) {
    self.frame = frame
    self.children = children
  }

  override var accessibilityElements: [Any]? {
    get { nil }
    set {}
  }

  override func accessibilityElementCount() -> Int {
    children.count
  }

  override func accessibilityElement(at index: Int) -> Any? {
    children.indices.contains(index) ? children[index] : nil
  }

  override var accessibilityFrame: CGRect {
    get { frame }
    set {}
  }
}

/// A UIKit view the adapter classifies as a SwiftUI hosting view (its class
/// name contains `HostingView`), with a scripted accessibility tree whose
/// frames are in window points (test windows sit at the screen origin).
final class FakeAXHostingView: UIView {
  var elements: [NSObject] = []
  private(set) var reads = 0

  override var accessibilityElements: [Any]? {
    get {
      reads += 1
      return elements
    }
    set {}
  }
}

/// An element shaped like SwiftUI's `AccessibilityNode`: it answers the
/// `accessibilityIdentifier` getter without declaring
/// `UIAccessibilityIdentification`.
final class FakeAXNode: NSObject {
  @objc var accessibilityIdentifier: String?

  init(_ frame: CGRect, identifier: String?) {
    accessibilityIdentifier = identifier
    super.init()
    isAccessibilityElement = true
    accessibilityFrame = frame
    accessibilityTraits = .button
  }
}

/// An accessibility element (never a container).
func axElement(_ frame: CGRect, _ traits: UIAccessibilityTraits = [], identifier: String? = nil) -> UIAccessibilityElement {
  let element = UIAccessibilityElement(accessibilityContainer: NSObject())
  element.isAccessibilityElement = true
  element.accessibilityFrame = frame
  element.accessibilityTraits = traits
  element.accessibilityIdentifier = identifier
  return element
}

/// The OS, the main queue and activation as a test drives them, with every
/// question the source asks counted.
final class AccessibilitySpy {
  var osMajor = 18
  var assistiveClientRunning = false
  var draw = 0.5
  private(set) var osReads = 0
  private(set) var assistiveReads = 0
  private(set) var draws = 0
  private(set) var activated: [UIView] = []
  private(set) var pending: [() -> Void] = []

  var environment: AccessibilityEnvironment {
    AccessibilityEnvironment(
      osMajor: { [unowned self] in
        self.osReads += 1
        return self.osMajor
      },
      assistiveClientRunning: { [unowned self] in
        self.assistiveReads += 1
        return self.assistiveClientRunning
      },
      draw: { [unowned self] in
        self.draws += 1
        return self.draw
      },
      nextTurn: { [unowned self] in self.pending.append($0) },
      activate: { [unowned self] in self.activated.append($0) }
    )
  }

  /// Runs the work queued for the main queue's next turn.
  func runNextTurn() {
    let due = pending
    pending.removeAll()
    due.forEach { $0() }
  }
}

/// A leaf source that always answers, with its questions counted.
final class AlwaysAnsweringLeafSource: AccessibilityLeafSource {
  private(set) var asked = 0

  func leaf(at point: CGPoint, in window: UIWindow, root: UIView) -> AccessibilityLeaf? {
    asked += 1
    return AccessibilityLeaf(token: "AXButton", ordinal: 0, role: "button")
  }
}
#endif
