#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

@testable import Tugboat

/// `.tugboatTag` identity: markers, neutral tagged anchors, matching only
/// within the hit hierarchy, and route keys.
final class SwiftUITagTests: XCTestCase {
  private var hosted: HostedWindow?
  private let registry = TagRegistry()
  private let screens = ScreenTracker(clock: ManualClock())

  override func tearDown() {
    hosted?.close()
    hosted = nil
    super.tearDown()
  }

  private var resolver: AnchorResolver {
    AnchorResolver(tags: registry, screens: screens)
  }

  private func anchor(_ evidence: TapEvidence, file: StaticString = #filePath, line: UInt = #line) -> TargetAnchor? {
    guard case let .anchor(anchor) = evidence else {
      XCTFail("expected an anchor, got \(evidence)", file: file, line: line)
      return nil
    }
    return anchor
  }

  private func marker(_ tag: String) -> TagMarkerView? {
    registry.all.first { $0.tugboatTag == tag && $0.window != nil }
  }

  private func centre(of view: UIView, in window: UIWindow) -> CGPoint {
    let frame = view.convert(view.bounds, to: window)
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  func testATaggedButtonResolvesToItsTagWithANeutralAnchor() throws {
    let window = HostedWindow(
      VStack(spacing: 40) {
        Button("Pay now") {}.modifier(TugboatTagModifier(tag: "checkout", registry: registry))
        Button("Untagged") {}
      }
      .modifier(TugboatScreenModifier(name: "Checkout", tracker: screens))
    )
    hosted = window
    XCTAssertTrue(window.wait { self.marker("checkout") != nil })
    let tagged = try XCTUnwrap(marker("checkout"))
    let point = centre(of: tagged, in: window.window)

    let resolved = try XCTUnwrap(anchor(resolver.tapEvidence(in: window.window, at: point)))
    XCTAssertEqual(resolved.tag, "checkout")
    XCTAssertEqual(resolved.routeKey, "Checkout")
    XCTAssertEqual(resolved.confidence, .high)
    XCTAssertEqual(resolved.widgetType, "SwiftUIView")
    XCTAssertNil(resolved.role)
    XCTAssertNil(resolved.enabled)
    XCTAssertEqual(resolved.actions, [])
    XCTAssertEqual(resolved.tagFingerprint, IdentityHash.fingerprint([(key: "routeKey", value: "Checkout"), (key: "tag", value: "checkout")]))
    XCTAssertEqual(resolved.fingerprint, IdentityHash.fingerprint([(key: "routeKey", value: "Checkout"), (key: "path", value: resolved.canonicalPath)]))
    XCTAssertFalse(resolved.canonicalPath.contains("checkout"), "the tag is not part of the structural path")
    let json = try XCTUnwrap(decodeObject(resolved.json.json))
    XCTAssertEqual(json["toolkit"] as? String, "swiftui")
    XCTAssertEqual((json["fingerprintParts"] as? [String: String])?["tag"], "checkout")

    let below = CGPoint(x: point.x, y: tagged.convert(tagged.bounds, to: window.window).maxY + 50)
    XCTAssertEqual(resolver.tapEvidence(in: window.window, at: below), .failed(.noActionableCandidate), "bare SwiftUI drawing")
  }

  func testTheMarkerNeverTakesPartInHitTesting() throws {
    let window = HostedWindow(Text("Tagged").padding(30).modifier(TugboatTagModifier(tag: "hero", registry: registry)))
    hosted = window
    XCTAssertTrue(window.wait { self.marker("hero") != nil })
    let tagged = try XCTUnwrap(marker("hero"))
    let hit = window.window.hitTest(centre(of: tagged, in: window.window), with: nil)
    XCTAssertFalse(hit is TagMarkerView)
    XCTAssertFalse(hit === tagged.superview, "the marker's SwiftUI host does not take touches")
    XCTAssertFalse(tagged.isUserInteractionEnabled)
    XCTAssertTrue(tagged.accessibilityElementsHidden)
  }

  func testATaggedButtonInAScrollViewDoesNotInheritTheScrollRole() throws {
    let window = HostedWindow(
      ScrollView {
        VStack {
          Button("Buy") {}.modifier(TugboatTagModifier(tag: "buy", registry: registry))
          ForEach(0..<40, id: \.self) { Text("Item \($0)").frame(height: 30) }
        }
      }
    )
    hosted = window
    XCTAssertTrue(window.wait { self.marker("buy") != nil })
    let tagged = try XCTUnwrap(marker("buy"))
    let resolved = try XCTUnwrap(anchor(resolver.tapEvidence(in: window.window, at: centre(of: tagged, in: window.window))))
    XCTAssertEqual(resolved.tag, "buy")
    XCTAssertNil(resolved.role, "not scrollable")
    XCTAssertEqual(resolved.actions, [])
    XCTAssertEqual(resolved.widgetType, "SwiftUIView")
    XCTAssertTrue(resolved.canonicalPath.hasSuffix("Scrollable#0"), "the structure is still the scroll view: \(resolved.canonicalPath)")
  }

  func testATagUnderASheetNeverWinsATapOnTheSheet() throws {
    let presenter = HostedWindow(
      Color.white.frame(width: 40, height: 40).modifier(TugboatTagModifier(tag: "behind", registry: registry))
    )
    hosted = presenter
    XCTAssertTrue(presenter.wait { self.marker("behind") != nil })
    let behind = try XCTUnwrap(marker("behind"))
    let point = centre(of: behind, in: presenter.window)

    let sheet = UIHostingController(rootView: Color.blue.ignoresSafeArea())
    sheet.modalPresentationStyle = .overFullScreen
    presenter.window.rootViewController?.present(sheet, animated: false)
    XCTAssertTrue(presenter.wait { sheet.view.window != nil })
    presenter.settle()
    XCTAssertEqual(resolver.tapEvidence(in: presenter.window, at: point), .failed(.noActionableCandidate),
                   "the covered presenter's smaller tag is in another hosting root")

    let front = UIHostingController(rootView: AnyView(Color.green.frame(width: 300, height: 300).modifier(TugboatTagModifier(tag: "front", registry: registry))))
    front.modalPresentationStyle = .overFullScreen
    sheet.present(front, animated: false)
    XCTAssertTrue(presenter.wait { self.marker("front") != nil })
    presenter.settle()
    let resolved = try XCTUnwrap(anchor(resolver.tapEvidence(in: presenter.window, at: point)))
    XCTAssertEqual(resolved.tag, "front", "the larger tag of the sheet that was hit")
    front.dismiss(animated: false)
    sheet.dismiss(animated: false)
  }

  func testRouteKeysFromTheHostingTypeScoreByHowSpecificTheTypeIs() throws {
    let erased = HostedWindow(Text("Erased").padding(30).modifier(TugboatTagModifier(tag: "erased", registry: registry)))
    hosted = erased
    XCTAssertTrue(erased.wait { self.marker("erased") != nil })
    let erasedMarker = try XCTUnwrap(marker("erased"))
    let fromAnyView = try XCTUnwrap(anchor(resolver.tapEvidence(in: erased.window, at: centre(of: erasedMarker, in: erased.window))))
    XCTAssertTrue(fromAnyView.routeKey.hasPrefix("host:"), fromAnyView.routeKey)
    XCTAssertEqual(fromAnyView.routeKey.count, "host:".count + 16)
    XCTAssertEqual(fromAnyView.confidence, .low, "UIHostingController<AnyView> names no screen")
    erased.close()

    let concrete = HostedWindow(controller: UIHostingController(rootView: ConcreteScreen(registry: registry)))
    hosted = concrete
    XCTAssertTrue(concrete.wait { self.marker("concrete") != nil })
    let concreteMarker = try XCTUnwrap(marker("concrete"))
    let typed = try XCTUnwrap(anchor(resolver.tapEvidence(in: concrete.window, at: centre(of: concreteMarker, in: concrete.window))))
    XCTAssertEqual(typed.confidence, .medium, "a concrete root type scores medium")
    XCTAssertNotEqual(typed.routeKey, fromAnyView.routeKey)
  }

  private struct ConcreteScreen: View {
    let registry: TagRegistry

    var body: some View {
      Text("Concrete").padding(30).modifier(TugboatTagModifier(tag: "concrete", registry: registry))
    }
  }
}
#endif
