import XCTest

/// `.tugboatTag(_:accessibility:)` as UI tests see it, on the sample's
/// accessibility fixture screen (`-TugboatAccessibilityFixture YES`).
///
/// - With `accessibility: true`, a tagged `Button`, `Toggle`, `TextField`
///   and `NavigationLink` are found by their role query and the tag, and
///   report the same type, label, value, state and size as an untagged
///   twin. XCUITest exposes no traits; the element type, `isEnabled` and
///   `isSelected` are derived from them.
/// - Without it (the default) the tag is not an identifier.
/// - A tagged container: every element inside gets the identifier.
/// - Two `.accessibilityIdentifier`s on one view: the outermost wins. An
///   app identifier applied after `.tugboatTag` wins; one applied before it
///   is replaced by the tag.
///
/// The tests only read the tree, so the app is launched once for all of
/// them (a cold simulator launch is slow on CI).
final class TagAccessibilityUITests: XCTestCase {
  private static var launched = false
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = true
    app = XCUIApplication()
    if !Self.launched {
      app.launchArguments += ["-TugboatAccessibilityFixture", "YES"]
      app.launch()
      Self.launched = true
    }
    XCTAssertTrue(app.navigationBars["Accessibility"].waitForExistence(timeout: 60), "the fixture screen is shown")
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

  /// `.accessibilityIdentifier("app.before").tugboatTag(…, accessibility:
  /// true)`: the tag's identifier is outermost, so it replaces the app's.
  func testAnAppIdentifierAppliedBeforeTheTagIsReplacedByTheTag() {
    let button = app.buttons["Before"]
    XCTAssertTrue(button.exists)
    print("TBA11Y before: \(button.identifier)")
    XCTAssertEqual(button.identifier, "a11y.before")
    XCTAssertFalse(app.buttons["app.before"].exists)
  }

  /// `.tugboatTag(…, accessibility: true).accessibilityIdentifier("app.after")`:
  /// the app's identifier is outermost and wins.
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
    // A text field's placeholder value can lag its first appearance.
    let sameValue = NSPredicate { _, _ in tagged.value as? String == twin.value as? String }
    _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: sameValue, object: nil)], timeout: 5)
    XCTAssertEqual(tagged.value as? String, twin.value as? String, "value", file: file, line: line)
    XCTAssertEqual(tagged.isEnabled, twin.isEnabled, "enabled", file: file, line: line)
    XCTAssertEqual(tagged.isSelected, twin.isSelected, "selected", file: file, line: line)
    XCTAssertEqual(tagged.isHittable, twin.isHittable, "hittable", file: file, line: line)
    XCTAssertEqual(tagged.frame.width, twin.frame.width, accuracy: 0.5, "width", file: file, line: line)
    XCTAssertEqual(tagged.frame.height, twin.frame.height, accuracy: 0.5, "height", file: file, line: line)
  }

  private func twin(in query: XCUIElementQuery, of tagged: XCUIElement, excluding tag: String) -> XCUIElement {
    query.matching(NSPredicate(format: "label == %@ AND identifier != %@", tagged.label, tag)).firstMatch
  }
}
