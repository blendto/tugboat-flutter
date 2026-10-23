#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

@testable import Tugboat

/// `.tugboatSensitive` masks and tap evidence.
final class SwiftUISensitiveTests: XCTestCase {
  private var hosted: HostedWindow?
  private let registry = SensitiveRegistry()
  private let screens = ScreenTracker(clock: ManualClock())

  override func tearDown() {
    hosted?.close()
    hosted = nil
    super.tearDown()
  }

  private var resolver: AnchorResolver {
    AnchorResolver(tags: .shared, screens: screens)
  }

  func testSensitiveFrameIsMaskedAtPermissiveLevel() throws {
    let truth = TruthFrames()
    let window = HostedWindow(
      HStack(spacing: 16) {
        Color.red.frame(width: 44, height: 44).truth("plain", in: truth)
        Color.blue.frame(width: 44, height: 44)
          .modifier(TugboatSensitiveModifier(registry: registry))
          .truth("sensitive", in: truth)
      }
    )
    hosted = window
    XCTAssertTrue(window.wait { truth.frames["sensitive"] != nil && truth.frames["plain"] != nil })
    let result = window.settledMasks()
    let sensitive = try XCTUnwrap(truth.frames["sensitive"])
    let plain = try XCTUnwrap(truth.frames["plain"])
    XCTAssertGreaterThan(result.fractionMasked(of: sensitive, in: window.window), 0.9)
    XCTAssertLessThan(result.fractionMasked(of: plain, in: window.window), 0.2)
  }

  func testTapOnSensitiveViewStillCarriesAnchor() throws {
    let window = HostedWindow(
      Button("Secret") {}
        .modifier(TugboatSensitiveModifier(registry: registry))
        .modifier(TugboatScreenModifier(name: "Form", tracker: screens))
    )
    hosted = window
    XCTAssertTrue(window.wait { !registry.all.isEmpty })
    let marker = try XCTUnwrap(registry.all.first { $0.window != nil })
    let frame = marker.convert(marker.bounds, to: window.window)
    let point = CGPoint(x: frame.midX, y: frame.midY)
    let evidence = resolver.tapEvidence(in: window.window, at: point)
    guard case let .anchor(anchor) = evidence else {
      return XCTFail("expected anchor, got \(evidence)")
    }
    XCTAssertEqual(anchor.routeKey, "Form")
    XCTAssertEqual(anchor.toolkit, "swiftui")
  }

  func testSensitiveInsideMaskedTextDoesNotRemoveCoverage() throws {
    let truth = TruthFrames()
    let window = HostedWindow(
      Text("Account 1234")
        .modifier(TugboatSensitiveModifier(registry: registry))
        .truth("label", in: truth)
    )
    hosted = window
    XCTAssertTrue(window.wait { truth.frames["label"] != nil })
    let result = window.settledMasks()
    let frame = try XCTUnwrap(truth.frames["label"])
    XCTAssertGreaterThan(result.fractionMasked(of: frame, in: window.window), 0.9)
  }
}
#endif
