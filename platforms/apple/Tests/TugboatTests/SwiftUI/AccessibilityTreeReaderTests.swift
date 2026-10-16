#if canImport(UIKit)
import UIKit
import XCTest

@testable import Tugboat

/// `AccessibilityTreeReader` (ADR 0010, "Reading") against scripted trees:
/// the descent, the budget, ordinals and the role mapping.
final class AccessibilityTreeReaderTests: XCTestCase {
  private func read(_ root: NSObject, at point: CGPoint, budget: Int = AccessibilityTreeReader.visitBudget) -> AccessibilityLeaf? {
    var reader = AccessibilityTreeReader()
    reader.budget = budget
    return reader.leaf(at: point, under: root) { $0 }
  }

  func testTheSmallestElementContainingThePointWins() {
    let card = axElement(CGRect(x: 0, y: 0, width: 300, height: 300), .button)
    let inner = axElement(CGRect(x: 10, y: 10, width: 50, height: 50), .link)
    let root = FakeAXContainer(.zero, [card, FakeAXContainer(CGRect(x: 0, y: 0, width: 200, height: 200), [inner])])

    XCTAssertEqual(read(root, at: CGPoint(x: 20, y: 20)), AccessibilityLeaf(token: "AXLink", ordinal: 0, role: "link"))
    XCTAssertEqual(read(root, at: CGPoint(x: 250, y: 250)), AccessibilityLeaf(token: "AXButton", ordinal: 0, role: "button"))
  }

  func testOnATieTheDeeperElementWins() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let outer = FakeAXContainer(frame, [axElement(frame, .image)])
    let root = FakeAXContainer(.zero, [axElement(frame, .button), outer])

    XCTAssertEqual(read(root, at: CGPoint(x: 50, y: 50))?.role, "image")
  }

  func testContainersNotContainingThePointAreNotEntered() {
    let left = FakeAXContainer(CGRect(x: 0, y: 0, width: 100, height: 100), [axElement(CGRect(x: 0, y: 0, width: 50, height: 50), .button)])
    let right = FakeAXContainer(CGRect(x: 200, y: 0, width: 100, height: 100), [axElement(CGRect(x: 200, y: 0, width: 50, height: 50), .button)])
    let root = FakeAXContainer(.zero, [left, right])

    XCTAssertEqual(read(root, at: CGPoint(x: 220, y: 20))?.segment, "AXButton#0")
    XCTAssertEqual(left.childReads, 0, "the container away from the point is never entered")
    XCTAssertEqual(right.childReads, 1)
  }

  func testCountedContainersAreDescended() {
    let field = axElement(CGRect(x: 0, y: 60, width: 100, height: 40), .searchField)
    let root = FakeAXCountedContainer(.zero, [
      axElement(CGRect(x: 0, y: 0, width: 100, height: 40), .searchField),
      FakeAXCountedContainer(CGRect(x: 0, y: 50, width: 100, height: 100), [field]),
    ])

    XCTAssertEqual(read(root, at: CGPoint(x: 10, y: 70)), AccessibilityLeaf(token: "AXTextField", ordinal: 0, role: "textField"))
  }

  func testOverTheBudgetThereIsNoAnswer() {
    var children: [NSObject] = (0..<300).map { axElement(CGRect(x: 0, y: CGFloat($0) * 10, width: 10, height: 10), .button) }
    children.append(axElement(CGRect(x: 500, y: 500, width: 10, height: 10), .button))
    let root = FakeAXContainer(.zero, children)
    let point = CGPoint(x: 505, y: 505)

    XCTAssertNil(read(root, at: point), "301 visits exceed the default budget of 256: today's result")
    XCTAssertEqual(read(root, at: point, budget: 400)?.segment, "AXButton#300")
  }

  func testTheBudgetCountsVisitsAcrossLevels() {
    let deep = FakeAXContainer(CGRect(x: 0, y: 0, width: 100, height: 100), (0..<10).map { _ in
      axElement(CGRect(x: 0, y: 0, width: 100, height: 100), .button)
    })
    let root = FakeAXContainer(.zero, [deep])

    XCTAssertNil(read(root, at: CGPoint(x: 1, y: 1), budget: 10), "1 container + 10 elements")
    XCTAssertNotNil(read(root, at: CGPoint(x: 1, y: 1), budget: 11))
  }

  func testNothingAtThePointHasNoAnswer() {
    let root = FakeAXContainer(.zero, [axElement(CGRect(x: 0, y: 0, width: 10, height: 10), .button)])
    XCTAssertNil(read(root, at: CGPoint(x: 50, y: 50)))
    XCTAssertNil(read(FakeAXContainer(.zero), at: .zero), "an empty tree (not activated)")
  }

  func testHiddenElementsAreSkippedWithTheirChildren() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let hidden = FakeAXContainer(frame, [axElement(CGRect(x: 0, y: 0, width: 10, height: 10), .link)])
    hidden.accessibilityElementsHidden = true
    let root = FakeAXContainer(.zero, [axElement(frame, .button), hidden])

    XCTAssertEqual(read(root, at: CGPoint(x: 5, y: 5))?.role, "button")
    XCTAssertEqual(hidden.childReads, 0)
  }

  func testRoleOrdinalsCountSiblingsOfTheSameRoleWithoutAnIdentifier() {
    let row = { (x: CGFloat, traits: UIAccessibilityTraits, id: String?) in
      axElement(CGRect(x: x, y: 0, width: 40, height: 40), traits, identifier: id)
    }
    let root = FakeAXContainer(.zero, [
      row(0, .button, nil), row(50, .image, nil), row(100, .button, "pay"), row(150, .button, nil), row(200, .staticText, nil),
    ])

    XCTAssertEqual(read(root, at: CGPoint(x: 160, y: 10)), AccessibilityLeaf(token: "AXButton", ordinal: 1, role: "button"))
    XCTAssertEqual(read(root, at: CGPoint(x: 60, y: 10))?.segment, "AXImage#0")
    XCTAssertEqual(read(root, at: CGPoint(x: 210, y: 10)), AccessibilityLeaf(token: "AXElement", ordinal: 0, role: nil))
  }

  func testIdentifiedOrdinalsCountIdentifiedElementsBeforeItOnTheDescent() {
    let first = axElement(CGRect(x: 0, y: 0, width: 40, height: 40), .button, identifier: "row_1")
    let group = FakeAXContainer(CGRect(x: 0, y: 100, width: 300, height: 100), [
      axElement(CGRect(x: 0, y: 100, width: 40, height: 40), .button, identifier: "row_2"),
      axElement(CGRect(x: 50, y: 100, width: 40, height: 40), .button),
      axElement(CGRect(x: 100, y: 100, width: 40, height: 40), .button, identifier: "user-ada@example.com"),
    ])
    let after = axElement(CGRect(x: 0, y: 300, width: 40, height: 40), .button, identifier: "row_4")
    let root = FakeAXContainer(.zero, [first, group, after])

    let leaf = read(root, at: CGPoint(x: 110, y: 110))
    XCTAssertEqual(leaf, AccessibilityLeaf(token: "AXIdentified", ordinal: 2, role: nil))
    XCTAssertEqual(read(root, at: CGPoint(x: 10, y: 10))?.segment, "AXIdentified#0")
    XCTAssertEqual(read(root, at: CGPoint(x: 10, y: 310))?.segment, "AXIdentified#1", "the group's children are not on this descent")
    XCTAssertEqual(read(root, at: CGPoint(x: 60, y: 110))?.segment, "AXButton#0")
    XCTAssertFalse(String(describing: leaf).contains("ada"), "the identifier's value is never kept")
  }

  func testTraitsMapOntoSharedRoleNames() {
    XCTAssertEqual(AccessibilityRole.role(of: .button), "button")
    XCTAssertEqual(AccessibilityRole.role(of: .link), "link")
    XCTAssertEqual(AccessibilityRole.role(of: .searchField), "textField")
    XCTAssertEqual(AccessibilityRole.role(of: .adjustable), "adjustable")
    XCTAssertEqual(AccessibilityRole.role(of: .image), "image")
    XCTAssertEqual(AccessibilityRole.role(of: .header), "header")
    XCTAssertEqual(AccessibilityRole.role(of: [.button, .image]), "button")
    XCTAssertNil(AccessibilityRole.role(of: .staticText))
    XCTAssertNil(AccessibilityRole.role(of: []))
    if #available(iOS 17.0, *) {
      XCTAssertEqual(AccessibilityRole.role(of: [.button, .toggleButton]), "switch")
    }
    XCTAssertEqual(AccessibilityRole.token(of: "textField"), "AXTextField")
    XCTAssertEqual(AccessibilityRole.token(of: nil), "AXElement")
  }
}
#endif
