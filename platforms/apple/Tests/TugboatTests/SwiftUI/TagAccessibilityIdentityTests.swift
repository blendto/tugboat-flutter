#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

@testable import Tugboat

/// `.tugboatTag(_:accessibility:)`: the accessibility identifier is not
/// identity. The same screen tagged through the one-argument overload, with
/// `accessibility: false`, and with `accessibility: true` gives identical
/// anchors (target fingerprint, canonical path, tag alias) and an identical
/// structure signature. Whether the identifier reaches the accessibility tree
/// is measured by the sample's UI tests; the in-process tree is empty here.
final class TagAccessibilityIdentityTests: XCTestCase {
  private enum Variant: CaseIterable {
    case overload
    case off
    case on
  }

  /// What identity reads from one hosted variant.
  private struct Reading {
    let anchors: [String: TargetAnchor]
    let signature: String
  }

  private static let tags = ["checkout", "alerts", "name"]

  private var hosted: HostedWindow?
  private let screens = ScreenTracker(clock: ManualClock())

  override func tearDown() {
    hosted?.close()
    hosted = nil
    super.tearDown()
  }

  func testTheAccessibilityOptionLeavesIdentityAndTheStructureSignatureUnchanged() throws {
    var readings: [Variant: Reading] = [:]
    for variant in Variant.allCases {
      readings[variant] = try read(variant)
    }
    let baseline = try XCTUnwrap(readings[.overload])
    for variant in [Variant.off, .on] {
      let reading = try XCTUnwrap(readings[variant])
      for tag in Self.tags {
        let expected = try XCTUnwrap(baseline.anchors[tag])
        let actual = try XCTUnwrap(reading.anchors[tag])
        XCTAssertEqual(actual.tag, tag, "\(variant)")
        XCTAssertEqual(actual.fingerprint, expected.fingerprint, "\(variant) \(tag): target fingerprint")
        XCTAssertEqual(actual.canonicalPath, expected.canonicalPath, "\(variant) \(tag): canonical path")
        XCTAssertEqual(actual.tagFingerprint, expected.tagFingerprint, "\(variant) \(tag): tag alias")
        XCTAssertEqual(actual, expected, "\(variant) \(tag): the whole anchor")
      }
      XCTAssertEqual(reading.signature, baseline.signature, "\(variant): structure signature")
    }
    let checkout = try XCTUnwrap(baseline.anchors["checkout"])
    XCTAssertEqual(checkout.tagFingerprint, IdentityHash.fingerprint([(key: "routeKey", value: "Checkout"), (key: "tag", value: "checkout")]))
    XCTAssertEqual(checkout.confidence, .high)
  }

  func testTheMarkerStaysHiddenFromAccessibilityWithTheOptionOn() throws {
    let window = host(.on)
    let marker = try XCTUnwrap(self.marker("checkout", in: window))
    XCTAssertTrue(marker.accessibilityElementsHidden)
    XCTAssertFalse(marker.isAccessibilityElement)
    XCTAssertNil(marker.accessibilityIdentifier, "the identifier goes on the content, not the marker")
  }

  private func read(_ variant: Variant, file: StaticString = #filePath, line: UInt = #line) throws -> Reading {
    let window = host(variant)
    defer {
      window.close()
      hosted = nil
    }
    let resolver = AnchorResolver(tags: .shared, screens: screens)
    var anchors: [String: TargetAnchor] = [:]
    for tag in Self.tags {
      let marker = try XCTUnwrap(self.marker(tag, in: window), "\(variant) \(tag)", file: file, line: line)
      let frame = marker.convert(marker.bounds, to: window.window)
      guard case let .anchor(anchor) = resolver.tapEvidence(in: window.window, at: CGPoint(x: frame.midX, y: frame.midY)) else {
        XCTFail("\(variant) \(tag) resolves to an anchor", file: file, line: line)
        continue
      }
      anchors[tag] = anchor
    }
    let masks = FrameMasks(compute: { WindowMasks.compute($0) }, screen: { "Checkout" })
    return Reading(anchors: anchors, signature: masks.snapshot(for: window.window).structureSignature)
  }

  /// Hosts `variant` through the public modifier (shared registry), as an
  /// app would.
  private func host(_ variant: Variant) -> HostedWindow {
    let window = HostedWindow(
      Fixture(variant: variant).modifier(TugboatScreenModifier(name: "Checkout", tracker: screens))
    )
    hosted = window
    XCTAssertTrue(window.wait { Self.tags.allSatisfy { self.marker($0, in: window) != nil } })
    window.settle(0.5)
    return window
  }

  private func marker(_ tag: String, in window: HostedWindow) -> TagMarkerView? {
    TagRegistry.shared.all.first { $0.tugboatTag == tag && $0.window === window.window }
  }

  private struct Fixture: View {
    let variant: Variant
    @State private var alerts = true
    @State private var name = "Ada"

    var body: some View {
      VStack(spacing: 40) {
        tagged(Button("Pay now") {}, "checkout")
        tagged(Toggle("Alerts", isOn: $alerts), "alerts")
        tagged(TextField("Name", text: $name), "name")
        Button("Untagged") {}
      }
      .padding()
    }

    @ViewBuilder
    private func tagged<Content: View>(_ content: Content, _ tag: String) -> some View {
      switch variant {
      case .overload:
        content.tugboatTag(tag)
      case .off:
        content.tugboatTag(tag, accessibility: false)
      case .on:
        content.tugboatTag(tag, accessibility: true)
      }
    }
  }
}
#endif
