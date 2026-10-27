#if canImport(UIKit)
import UIKit
import XCTest

@testable import Tugboat

/// `SurfaceObserver` follows the key window's size between captures, and
/// `StructureProbe` reads the control state the structure signature needs.
final class SurfaceAndStructureTests: XCTestCase {
  func testWindowResizesAreReportedAsNewSurfaceGenerations() {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    var posted: [[String: Any]] = []
    let observer = SurfaceObserver(
      reporter: SurfaceReporter { posted.append(jsonObject($0)) }, center: NotificationCenter(), window: { window })
    observer.start()
    window.frame = CGRect(x: 0, y: 0, width: 600, height: 844)  // split view or Stage Manager resize
    spin(until: { posted.count >= 2 })
    observer.stop()
    window.frame = CGRect(x: 0, y: 0, width: 700, height: 844)
    spin(until: { false }, timeout: 0.1)

    XCTAssertEqual(posted.count, 2, "nothing after stop")
    XCTAssertEqual(posted.map { $0["generation"] as? Int64 }, [0, 1])
    XCTAssertEqual((posted.last?["boundaryRect"] as? [String: Any])?["width"] as? Double, 600)
  }

  func testControlStateEntersTheStructure() {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.isHidden = false
    defer { window.isHidden = true }
    let toggle = UISwitch()
    let tab = UIView()
    let hidden = UIButton()
    hidden.isHidden = true
    [toggle, tab, hidden].forEach(window.addSubview)

    let off = StructureProbe.controls(in: window)
    toggle.isOn = true
    let on = StructureProbe.controls(in: window)
    tab.accessibilityTraits.insert(.selected)
    let selected = StructureProbe.controls(in: window)
    hidden.isSelected = true
    let hiddenChanged = StructureProbe.controls(in: window)

    XCTAssertFalse(off.isEmpty)
    XCTAssertNotEqual(off, on, "a switch turned on changes it")
    XCTAssertEqual(selected.count, on.count + 1, "a view with the selected trait enters it")
    XCTAssertEqual(selected, hiddenChanged, "hidden controls do not")
  }

  /// The default timeout is a progress wait, not a speed bound: CI runners stall for seconds.
  private func spin(until condition: () -> Bool, timeout: TimeInterval = 30) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }
}
#endif
