import XCTest

/// `.tugboatTag(_:accessibility:)` as UI tests see it, on the sample's
/// accessibility fixture screen (`-TugboatAccessibilityFixture YES`).
///
/// - With `accessibility: true`, a tagged `Button`, `Toggle`, `TextField`
///   and `NavigationLink` are found by their role query and the tag, and
///   report the same type, label, value and state as an untagged twin.
///   XCUITest exposes no traits; the element type, `isEnabled` and
///   `isSelected` are derived from them.
/// - Without it (the default) the tag is not an identifier.
/// - A tagged container: every element inside gets the identifier.
/// - An app-set identifier wins in both orders.
final class TagAccessibilityUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = true
    app = XCUIApplication()
    app.launchArguments += ["-TugboatAccessibilityFixture", "YES"]
    app.launch()
    XCTAssertTrue(app.navigationBars["Accessibility"].waitForExistence(timeout: 30), "the fixture screen is shown")
  }

  override func tearDown() {
    app.terminate()
    app = nil
    super.tearDown()
  }

  /// Prints what the accessibility tree reports, so a changed outcome on a
  /// new iOS is readable from the CI log.
  func testRecordTheObservedTree() {
    for (name, query) in [("buttons", app.buttons), ("switches", app.switches), ("textFields", app.textFields)] {
      for element in query.allElementsBoundByIndex {
        print("TBA11Y \(name) label=\(element.label) id=\(element.identifier) value=\(String(describing: element.value))")
      }
    }
  }

  func testATaggedButtonIsFoundByItsTagAndMatchesItsTwin() {
    assertTagged(app.buttons, "a11y.pay", label: "Pay")
  }

  func testATaggedToggleIsFoundByItsTagAndMatchesItsTwin() {
    assertTagged(app.switches, "a11y.alerts", label: "Alerts")
  }

  func testATaggedTextFieldIsFoundByItsTagAndMatchesItsTwin() {
    assertTagged(app.textFields, "a11y.name", label: nil)
    let tagged = app.textFields["a11y.name"].firstMatch
    let twin = twin(in: app.textFields, of: tagged, excluding: "a11y.name")
    XCTAssertEqual(tagged.placeholderValue, twin.placeholderValue)
  }

  func testATaggedNavigationLinkIsFoundByItsTagAndMatchesItsTwin() {
    assertTagged(app.buttons, "a11y.details", label: "Details")
  }

  func testTheIdentifierIsOffByDefault() {
    XCTAssertTrue(app.buttons["Plain"].exists)
    XCTAssertFalse(app.buttons["a11y.plain"].exists, "no identifier without accessibility: true")
    XCTAssertEqual(app.buttons["Plain"].identifier, "")
  }

  /// SwiftUI gives every accessibility element inside the tagged container
  /// the container's identifier; the container itself is not an element.
  func testATaggedContainerPushesItsIdentifierOntoEachChild() {
    let matches = app.descendants(matching: .any).matching(identifier: "a11y.group")
    let labels = matches.allElementsBoundByIndex.map { "\($0.elementType.rawValue):\($0.label)" }
    print("TBA11Y container matches: \(labels)")
    XCTAssertEqual(app.buttons.matching(identifier: "a11y.group").count, 2, "\(labels)")
    XCTAssertEqual(app.buttons["First"].identifier, "a11y.group")
    XCTAssertEqual(app.buttons["Second"].identifier, "a11y.group")
    XCTAssertEqual(matches.count, 2, "only the two buttons carry it: \(labels)")
  }

  /// `.accessibilityIdentifier` applied inside `.tugboatTag` (before it).
  func testAnAppIdentifierAppliedBeforeTheTagWins() {
    let button = app.buttons["Before"]
    XCTAssertTrue(button.exists)
    print("TBA11Y before: \(button.identifier)")
    XCTAssertEqual(button.identifier, "app.before")
    XCTAssertFalse(app.buttons["a11y.before"].exists)
  }

  /// `.accessibilityIdentifier` applied outside `.tugboatTag` (after it).
  func testAnAppIdentifierAppliedAfterTheTagWins() {
    let button = app.buttons["After"]
    XCTAssertTrue(button.exists)
    print("TBA11Y after: \(button.identifier)")
    XCTAssertEqual(button.identifier, "app.after")
    XCTAssertFalse(app.buttons["a11y.after"].exists)
  }

  /// The tagged element is found by `query[tag]`, is unique, and reports
  /// what its untagged twin reports. `label` nil: compare labels only.
  private func assertTagged(
    _ query: XCUIElementQuery, _ tag: String, label: String?, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(query[tag].firstMatch.waitForExistence(timeout: 5), "\(tag) by its role query", file: file, line: line)
    XCTAssertEqual(query.matching(identifier: tag).count, 1, "\(tag) is unique", file: file, line: line)
    let tagged = query[tag].firstMatch
    let twin = twin(in: query, of: tagged, excluding: tag)
    XCTAssertTrue(twin.exists, "\(tag) has an untagged twin", file: file, line: line)
    if let label {
      XCTAssertEqual(tagged.label, label, file: file, line: line)
    }
    XCTAssertEqual(tagged.label, twin.label, "label", file: file, line: line)
    XCTAssertEqual(tagged.elementType, twin.elementType, "type", file: file, line: line)
    XCTAssertEqual(tagged.value as? String, twin.value as? String, "value", file: file, line: line)
    XCTAssertEqual(tagged.isEnabled, twin.isEnabled, "enabled", file: file, line: line)
    XCTAssertEqual(tagged.isSelected, twin.isSelected, "selected", file: file, line: line)
    XCTAssertEqual(tagged.isHittable, twin.isHittable, "hittable", file: file, line: line)
    XCTAssertEqual(tagged.frame.size, twin.frame.size, "size", file: file, line: line)
  }

  private func twin(in query: XCUIElementQuery, of tagged: XCUIElement, excluding tag: String) -> XCUIElement {
    query.matching(NSPredicate(format: "label == %@ AND identifier != %@", tagged.label, tag)).firstMatch
  }
}
