import XCTest

@testable import Tugboat

/// `input.pointer` fact sequences from injected touch samples (UIKit gives
/// no public way to make a `UITouch`).
final class PointerFactBuilderTests: XCTestCase {
  private let clock = ManualClock(monoUs: 50_000_000)
  private var resolvedAt: [CGPoint] = []
  private var touches: [NSObject] = []

  private func makeBuilder() -> PointerFactBuilder {
    PointerFactBuilder(clock: FactClock(clock: clock), gesture: .uiKitDefault) { [unowned self] point in
      self.resolvedAt.append(point)
      return .failed(.noActionableCandidate)
    }
  }

  private func newTouch() -> ObjectIdentifier {
    let touch = NSObject()
    touches.append(touch)
    return ObjectIdentifier(touch)
  }

  private func sample(_ key: ObjectIdentifier, _ phase: TouchPhase, _ x: CGFloat, _ y: CGFloat, at uptime: TimeInterval) -> TouchSample {
    TouchSample(key: key, phase: phase, location: CGPoint(x: x, y: y), uptime: uptime, device: .touch)
  }

  func testATapUnderSlopCarriesEvidenceResolvedAtTheDownPosition() {
    let builder = makeBuilder()
    let touch = newTouch()
    var facts = builder.facts(for: sample(touch, .began, 100, 200, at: 49.0))
    facts += builder.facts(for: sample(touch, .moved, 104, 203, at: 49.05))
    facts += builder.facts(for: sample(touch, .ended, 105, 204, at: 49.1))

    XCTAssertEqual(facts.map { $0.decodedInput["phase"] as? String }, ["down", "move", "up"])
    XCTAssertEqual(facts.map { $0.type }, Array(repeating: "input.pointer", count: 3))
    XCTAssertEqual(facts.map { $0.at.monoUs }, [49_000_000, 49_050_000, 49_100_000], "touch timestamps, not post time")
    XCTAssertEqual(facts[0].at.wallUs, clock.now().wallUs - 1_000_000, "wall time back-dated by the touch's age")
    let up = facts[2].decodedInput
    XCTAssertEqual(up["x"] as? Double, 105)
    XCTAssertEqual(up["y"] as? Double, 204)
    XCTAssertEqual(up["device"] as? String, "touch")
    XCTAssertEqual((up["tap"] as? [String: Any])?["failureReason"] as? String, "no_actionable_candidate")
    XCTAssertEqual(resolvedAt, [CGPoint(x: 100, y: 200)])
    XCTAssertNil(facts[0].decodedInput["tap"])
  }

  func testAContactThatTravelledTheSlopHasNoTapEvidence() {
    let builder = makeBuilder()
    let touch = newTouch()
    _ = builder.facts(for: sample(touch, .began, 0, 0, at: 1))
    _ = builder.facts(for: sample(touch, .moved, 0, 10, at: 1.01))
    let up = builder.facts(for: sample(touch, .ended, 0, 2, at: 1.02))
    XCTAssertNil(up.first?.decodedInput["tap"], "max travel, not the final distance, decides")
    XCTAssertTrue(resolvedAt.isEmpty)
  }

  func testEveryContactGetsANewPointerId() {
    let builder = makeBuilder()
    let first = newTouch()
    let second = newTouch()
    let a = builder.facts(for: sample(first, .began, 0, 0, at: 1))
    let b = builder.facts(for: sample(second, .began, 50, 50, at: 1))
    _ = builder.facts(for: sample(first, .ended, 0, 0, at: 1.1))
    let again = builder.facts(for: sample(first, .began, 0, 0, at: 1.2))
    let ids = [a, b, again].compactMap { $0.first?.decodedInput["pointerId"] as? Int }
    XCTAssertEqual(ids.count, 3)
    XCTAssertEqual(Set(ids).count, 3, "ids are never reused")
    XCTAssertTrue(builder.hasActiveContacts)
  }

  func testCancelAndUnknownTouches() {
    let builder = makeBuilder()
    let touch = newTouch()
    XCTAssertTrue(builder.facts(for: sample(touch, .moved, 1, 1, at: 1)).isEmpty, "never began")
    _ = builder.facts(for: sample(touch, .began, 1, 1, at: 1))
    let cancel = builder.facts(for: sample(touch, .cancelled, 3, 3, at: 1.1))
    XCTAssertEqual(cancel.first?.decodedInput["phase"] as? String, "cancel")
    XCTAssertNil(cancel.first?.decodedInput["tap"])
    XCTAssertTrue(builder.facts(for: sample(touch, .ended, 3, 3, at: 1.2)).isEmpty, "already finished")
    XCTAssertFalse(builder.hasActiveContacts)
  }

  func testAStaleContactIsCancelledByItsNextBeganAndByReset() {
    let builder = makeBuilder()
    let touch = newTouch()
    _ = builder.facts(for: sample(touch, .began, 1, 1, at: 1))
    let restarted = builder.facts(for: sample(touch, .began, 5, 5, at: 2))
    XCTAssertEqual(restarted.map { $0.decodedInput["phase"] as? String }, ["cancel", "down"])

    let other = newTouch()
    _ = builder.facts(for: sample(other, .began, 9, 9, at: 2))
    _ = builder.facts(for: sample(other, .moved, 12, 9, at: 2.1))
    let cancelled = builder.cancelAll()
    XCTAssertEqual(cancelled.count, 2)
    XCTAssertEqual(cancelled.map { $0.decodedInput["phase"] as? String }, ["cancel", "cancel"])
    XCTAssertEqual(cancelled.last?.decodedInput["x"] as? Double, 12, "at the last known position")
    XCTAssertFalse(builder.hasActiveContacts)
  }

  func testGestureConfigIsWhatTheEngineIsConfiguredWith() {
    let json = decodeObject(GestureConfig.uiKitDefault.engineJSON.json)
    XCTAssertEqual(json?["touchSlop"] as? Double, 10)
    XCTAssertEqual(json?["panSlop"] as? Double, 20)
    XCTAssertEqual(json?["scaleSlop"] as? Double, 20)
    XCTAssertEqual(json?["trackpadScaleThreshold"] as? Double, 1.08)
  }
}
