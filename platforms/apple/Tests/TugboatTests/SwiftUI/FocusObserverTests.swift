#if canImport(UIKit)
import UIKit
import XCTest

@testable import Tugboat

/// `focus {kind}` from text editing notifications.
final class FocusObserverTests: XCTestCase {
  private let center = NotificationCenter()
  private let clock = ManualClock()
  private var facts: [AdapterFact] = []
  private var frameRequests = 0
  private lazy var observer = FocusObserver(
    clock: FactClock(clock: clock),
    emit: { [unowned self] in self.facts.append($0) },
    requestFrame: { [unowned self] in self.frameRequests += 1 }
  )

  override func setUp() {
    super.setUp()
    observer.start(center: center)
  }

  override func tearDown() {
    observer.stop(center: center)
    super.tearDown()
  }

  private var kinds: [String?] {
    facts.map { $0.decodedInput["kind"] as? String }
  }

  func testBeginAndEndEditingSendTextInputThenNone() {
    let field = UITextField()
    center.post(name: UITextField.textDidBeginEditingNotification, object: field)
    XCTAssertEqual(kinds, ["text_input"])
    XCTAssertEqual(facts.first?.type, "focus")

    clock.advance(ms: 40)
    let endedAt = clock.now()
    center.post(name: UITextField.textDidEndEditingNotification, object: field)
    XCTAssertEqual(kinds, ["text_input"], "none waits for the frame")
    XCTAssertEqual(frameRequests, 1)
    clock.advance(ms: 16)
    observer.onFrame()
    XCTAssertEqual(kinds, ["text_input", "none"])
    XCTAssertEqual(facts.last?.at, endedAt, "stamped when editing ended")
  }

  func testMovingBetweenFieldsIsOneTextInput() {
    center.post(name: UITextField.textDidBeginEditingNotification, object: UITextField())
    center.post(name: UITextField.textDidEndEditingNotification, object: nil)
    center.post(name: UITextView.textDidBeginEditingNotification, object: UITextView())
    observer.onFrame()
    XCTAssertEqual(kinds, ["text_input"])
  }

  func testStopRemovesTheObservers() {
    observer.stop(center: center)
    center.post(name: UITextField.textDidBeginEditingNotification, object: UITextField())
    XCTAssertTrue(facts.isEmpty)
  }
}
#endif
