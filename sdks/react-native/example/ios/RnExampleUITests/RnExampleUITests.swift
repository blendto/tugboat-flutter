import XCTest

/// Drives the sample app along the same path as the Android device run, so a
/// capture collector sees a comparable session. A script, not a test suite: it
/// only fails when an element it needs never appears.
///
/// - `testFullFlow`: cold launch, Catalog (tabs, a chip, grid toggle), Home,
///   Browse (scroll), Cart, Shipping (type), Payment (type a card number),
///   Profile, Scroll playground (every section), Network (all 10 buttons).
/// - `testSevenTaps`: a second launch with the first seven taps of the flow,
///   for fingerprint stability.
final class RnExampleUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUp() {
    continueAfterFailure = false
  }

  func testFullFlow() {
    app.launch()
    sevenTaps()

    // Browse: scroll the feed.
    tap("home-browse")
    scroll("browse-list", up: 4)
    back()

    // Cart: add a product first, or "Continue to shipping" stays disabled.
    tap("tab-catalog")
    tap("product-add-canvas-weekender")
    tap("tab-home")
    tap("home-cart")
    tap("cart-continue-shipping")
    type("shipping-name", "Ada Lovelace")
    type("shipping-email", "ada@example.com")
    dismissKeyboard()
    tap("shipping-continue")
    type("payment-card-number", "4111111111111111")
    back()  // Shipping
    back()  // Cart
    back()  // Home

    tap("tab-profile")
    tap("profile-push")
    tap("profile-density-compact")
    tap("tab-home")

    // Scroll playground: each section.
    tap("home-scroll")
    scroll("scroll-vertical", up: 3)
    swipe("scroll-carousel", left: 3)
    swipe("scroll-nested", left: 2)
    back()

    // Network: all ten calls, then give the last responses time to land.
    tap("home-network")
    for id in [
      "fetch-get", "fetch-post", "fetch-404", "fetch-500", "fetch-fail",
      "xhr-get", "xhr-post", "xhr-404", "xhr-500", "xhr-fail",
    ] {
      tap("network-\(id)")
      Thread.sleep(forTimeInterval: 0.6)
    }
    Thread.sleep(forTimeInterval: 8)
    back()
    Thread.sleep(forTimeInterval: 3)
  }

  func testSevenTaps() {
    app.launch()
    sevenTaps()
    Thread.sleep(forTimeInterval: 3)
  }

  /// Memory and time while scrolling the Browse feed, on a running app.
  func testScrollPerformance() {
    app.launch()
    tap("home-browse")
    let options = XCTMeasureOptions()
    options.iterationCount = 3
    measure(metrics: [XCTMemoryMetric(application: app), XCTClockMetric()], options: options) {
      scroll("browse-list", up: 4)
      scroll("browse-list", down: 4)
    }
  }

  // MARK: Steps

  private func sevenTaps() {
    tap("tab-catalog")
    tap("catalog-tab-new")
    tap("catalog-chip-bags")
    tap("catalog-toggle-view")
    tap("catalog-tab-popular")
    tap("catalog-tab-featured")
    tap("tab-home")
  }

  // MARK: Helpers

  private func element(_ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func tap(_ id: String, timeout: TimeInterval = 30) {
    let target = element(id)
    XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(id) never appeared")
    target.tap()
    Thread.sleep(forTimeInterval: 0.4)
  }

  private func type(_ id: String, _ text: String) {
    let field = app.textFields[id].exists ? app.textFields[id] : element(id)
    XCTAssertTrue(field.waitForExistence(timeout: 30), "\(id) never appeared")
    field.tap()
    field.typeText(text)
    Thread.sleep(forTimeInterval: 0.4)
  }

  private func dismissKeyboard() {
    let key = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] 'return'")).firstMatch
    if key.exists { key.tap() }
    Thread.sleep(forTimeInterval: 0.4)
  }

  private func scroll(_ id: String, up count: Int) {
    let target = element(id)
    XCTAssertTrue(target.waitForExistence(timeout: 30), "\(id) never appeared")
    for _ in 0..<count { target.swipeUp() }
  }

  private func scroll(_ id: String, down count: Int) {
    let target = element(id)
    XCTAssertTrue(target.waitForExistence(timeout: 30), "\(id) never appeared")
    for _ in 0..<count { target.swipeDown() }
  }

  private func swipe(_ id: String, left count: Int) {
    let target = element(id)
    XCTAssertTrue(target.waitForExistence(timeout: 30), "\(id) never appeared")
    for _ in 0..<count { target.swipeLeft() }
  }

  private func back() {
    let button = app.navigationBars.buttons.element(boundBy: 0)
    XCTAssertTrue(button.waitForExistence(timeout: 30), "no back button")
    button.tap()
    Thread.sleep(forTimeInterval: 0.6)
  }
}
