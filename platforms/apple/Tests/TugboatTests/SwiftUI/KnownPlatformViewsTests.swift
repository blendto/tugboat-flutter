import XCTest

@testable import Tugboat

/// A platform-view host is SwiftUI's own only when the type it wraps is
/// declared in SwiftUI and listed; app representables stay boxes.
final class KnownPlatformViewsTests: XCTestCase {
  private let navigationStack =
    "SwiftUI.UIKitPlatformViewHost<SwiftUI.PlatformViewControllerRepresentableAdaptor<SwiftUI.NavigationStackRepresentable>>"
  private let textField =
    "SwiftUI.UIKitPlatformViewHost<SwiftUI.PlatformViewRepresentableAdaptor<SwiftUI.PlatformTextFieldAdaptor>>"
  private let list =
    "SwiftUI.UIKitPlatformViewHost<SwiftUI.ListRepresentable<SwiftUI.SelectionManagerBox<Swift.Never>, SwiftUI.ModifiedContent<SwiftUI.ForEach<Swift.Range<Swift.Int>, Swift.Int, SwiftUI.Text>>>>"

  func testSwiftUIOwnedContainersAreRecognized() {
    let navigationView =
      "SwiftUI.UIKitPlatformViewHost<SwiftUI.PlatformViewControllerRepresentableAdaptor<SwiftUI.(unknown context at $1d3752bac).BridgedNavigationView>>"
    let tabView =
      "SwiftUI.UIKitPlatformViewHost<SwiftUI.PlatformViewControllerRepresentableAdaptor<SwiftUI.(unknown context at $1d372bd40).UIKitAdaptableTabView>>"
    for host in [navigationStack, textField, list, navigationView, tabView] {
      XCTAssertTrue(KnownPlatformViews.isInternal(host), host)
      XCTAssertTrue(KnownPlatformViews.isVerified(host, major: 26), host)
      XCTAssertFalse(KnownPlatformViews.isVerified(host, major: 17), "only verified majors walk \(host)")
    }
    XCTAssertEqual(KnownPlatformViews.representedType(ofHost: navigationStack)?.name, "NavigationStackRepresentable")
    XCTAssertEqual(KnownPlatformViews.representedType(ofHost: list)?.name, "ListRepresentable")
  }

  func testAppRepresentablesWithTheSameNameStayBoxes() {
    let app = "SwiftUI.UIKitPlatformViewHost<SwiftUI.PlatformViewControllerRepresentableAdaptor<MyApp.NavigationStackRepresentable>>"
    let appView = "SwiftUI.UIKitPlatformViewHost<SwiftUI.PlatformViewRepresentableAdaptor<MyApp.MapView>>"
    let wrappedInApp = "SwiftUI.UIKitPlatformViewHost<SwiftUI.PlatformViewRepresentableAdaptor<MyApp.Wrapper<SwiftUI.ListRepresentable>>>"
    for host in [app, appView, wrappedInApp] {
      XCTAssertFalse(KnownPlatformViews.isInternal(host), host)
      XCTAssertFalse(KnownPlatformViews.isVerified(host, major: 26), host)
    }
  }

  func testPrivateContextsAndUnparseableNamesAreHandled() {
    let privateContext =
      "SwiftUI.UIKitPlatformViewHost<SwiftUI.PlatformViewControllerRepresentableAdaptor<SwiftUI.(unknown context at $1d2c3b4a).NavigationStackRepresentable>>"
    XCTAssertTrue(KnownPlatformViews.isInternal(privateContext))
    XCTAssertFalse(KnownPlatformViews.isInternal("UIKitPlatformViewHost<ListRepresentable<X>>"), "no module: box")
    XCTAssertFalse(KnownPlatformViews.isInternal("SwiftUI._UIHostingView<SwiftUI.AnyView>"))
    XCTAssertNil(KnownPlatformViews.representedType(ofHost: "UIView"))
  }

  func testABoxOverNearlyTheWholeWindowIsAWholeFrame() {
    var stats = MaskStats(representableBoxes: 1)
    stats.largestBoxFraction = 0.95
    let near = MaskResult(rects: [.fullFrame], fallback: nil, stats: stats)
    XCTAssertEqual(near.coverage, MaskCoverage(mode: .wholeFrame, reasons: [.representable]))
    stats.largestBoxFraction = 0.4
    let small = MaskResult(rects: [MaskRect(x: 0, y: 0, width: 0.5, height: 0.8)], fallback: nil, stats: stats)
    XCTAssertEqual(small.coverage, MaskCoverage(mode: .precise, reasons: [.representable]))
  }
}
