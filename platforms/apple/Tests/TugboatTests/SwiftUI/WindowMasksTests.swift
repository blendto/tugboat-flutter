#if canImport(UIKit)
import SwiftUI
import UIKit
import WebKit
import XCTest

@testable import Tugboat

/// Masks per native SDK note 2.1 (SwiftUI row) and 6.3, on a screen with
/// Text, Image, TextField, List, WKWebView, and a representable; and the
/// layer-allowlist regression guard.
final class WindowMasksTests: XCTestCase {
  private var hosted: HostedWindow?

  override func tearDown() {
    hosted?.close()
    hosted = nil
    super.tearDown()
  }

  private final class Marker: UIView {}

  private struct WebViewHost: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
      let web = WKWebView()
      web.loadHTMLString("<p>secret</p>", baseURL: nil)
      return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
  }

  private struct MarkerHost: UIViewRepresentable {
    func makeUIView(context: Context) -> Marker {
      let view = Marker()
      view.backgroundColor = .systemTeal
      return view
    }

    func updateUIView(_ uiView: Marker, context: Context) {}
  }

  private func hostMixedScreen(_ truth: TruthFrames) -> HostedWindow {
    let window = HostedWindow(
      VStack(spacing: 8) {
        Text("Account balance").font(.title).truth("text", in: truth)
        Image(systemName: "star.fill").resizable().frame(width: 40, height: 40).truth("image", in: truth)
        TextField("Email", text: .constant("someone@example.com")).textFieldStyle(.roundedBorder).padding(.horizontal)
        List(0..<5, id: \.self) { Text("Row \($0)").truth("row\($0)", in: truth) }.frame(height: 220)
        WebViewHost().frame(height: 80).truth("web", in: truth)
        MarkerHost().frame(width: 60, height: 30).truth("representable", in: truth)
        Spacer()
      }
    )
    hosted = window
    window.wait { truth.frames.count >= 4 && !window.views(UITextField.self).isEmpty }
    window.settle(0.5)
    return window
  }

  /// The fraction of `frame` (window points) inside the mask, on a grid.
  private func coverage(of frame: CGRect, by result: MaskResult, in window: UIWindow) -> Double {
    let bounds = window.bounds
    let rects = result.rects.map {
      CGRect(x: $0.x * Double(bounds.width), y: $0.y * Double(bounds.height), width: $0.width * Double(bounds.width), height: $0.height * Double(bounds.height))
    }
    let steps = 10
    var inside = 0
    for i in 0..<steps {
      for j in 0..<steps {
        let point = CGPoint(
          x: frame.minX + frame.width * (CGFloat(i) + 0.5) / CGFloat(steps),
          y: frame.minY + frame.height * (CGFloat(j) + 0.5) / CGFloat(steps)
        )
        if rects.contains(where: { $0.contains(point) }) { inside += 1 }
      }
    }
    return Double(inside) / Double(steps * steps)
  }

  func testLayerAllowlistRegressionGuard() throws {
    let truth = TruthFrames()
    let window = hostMixedScreen(truth)
    let major = LayerAllowlist.runningMajor
    guard let allowlist = LayerAllowlist.forMajor(major) else {
      let result = WindowMasks.compute(window.window)
      XCTAssertEqual(result.fallback, .unverifiedLayerAllowlist(iOSMajor: major))
      XCTAssertEqual(result.rects, [.fullFrame])
      let census = WindowMasks.compute(window.window, allowlist: LayerAllowlist.forMajor(26), iOSMajor: major)
      print("TUGBOAT-LAYER-CENSUS iOS \(major): \(census.stats)")
      return
    }
    let result = WindowMasks.compute(window.window, allowlist: allowlist, iOSMajor: major)
    let found = "found \(result.stats); verify iOS \(major) with the probe (spike/swiftui-a11y-probe)"
    XCTAssertNil(result.fallback, found)
    XCTAssertGreaterThan(result.stats.textLayers, 0, "REGRESSION: no allowlisted SwiftUI text layer on a screen with text; \(found)")
    XCTAssertGreaterThan(result.stats.imageLayers, 0, "REGRESSION: no allowlisted SwiftUI image layer on a screen with an image; \(found)")
  }

  func testEveryMaskSourceIsCovered() throws {
    let truth = TruthFrames()
    let window = hostMixedScreen(truth)
    let result = WindowMasks.compute(window.window)
    try XCTSkipIf(result.fallback != nil, "iOS \(LayerAllowlist.runningMajor) has no verified allowlist; the whole frame is masked")

    for name in ["text", "image", "row0", "row1", "web", "representable"] {
      let frame = try XCTUnwrap(truth.frames[name], "no truth frame for \(name)")
      XCTAssertGreaterThanOrEqual(coverage(of: frame, by: result, in: window.window), 0.9, "\(name) at \(frame) not masked; \(result.stats)")
    }
    let field = try XCTUnwrap(window.views(UITextField.self).first)
    XCTAssertEqual(coverage(of: window.frame(of: field), by: result, in: window.window), 1, "text field")
    let web = try XCTUnwrap(window.views(WKWebView.self).first)
    XCTAssertEqual(coverage(of: window.frame(of: web), by: result, in: window.window), 1, "web view, fail-closed")
    XCTAssertGreaterThan(result.stats.failClosedViews, 0)

    let blank = CGRect(x: 0, y: window.window.bounds.height - 60, width: window.window.bounds.width, height: 40)
    XCTAssertLessThan(coverage(of: blank, by: result, in: window.window), 1, "empty space below the content stays visible: masks are per region")
  }

  func testImageMasksArePadded() throws {
    let truth = TruthFrames()
    let window = HostedWindow(Image(systemName: "star.fill").resizable().frame(width: 40, height: 40).truth("image", in: truth))
    hosted = window
    window.wait { truth.frames["image"] != nil }
    window.settle(0.3)
    let result = WindowMasks.compute(window.window)
    try XCTSkipIf(result.fallback != nil, "unverified iOS major")
    let frame = try XCTUnwrap(truth.frames["image"])
    XCTAssertEqual(coverage(of: frame, by: result, in: window.window), 1, "the padded image layer covers the layout frame: \(result.rects)")
  }

  func testAnUnverifiedMajorMasksAWindowWithSwiftUIInFull() {
    let window = HostedWindow(Text("Hello"))
    hosted = window
    let result = WindowMasks.compute(window.window, allowlist: nil, iOSMajor: 18)
    XCTAssertEqual(result, .wholeFrame(.unverifiedLayerAllowlist(iOSMajor: 18)))
  }

  func testAUIKitOnlyWindowNeedsNoAllowlist() throws {
    let controller = UIViewController()
    let label = UILabel(frame: CGRect(x: 20, y: 100, width: 200, height: 30))
    label.text = "Secret"
    let image = UIImageView(frame: CGRect(x: 20, y: 200, width: 50, height: 50))
    let hidden = UILabel(frame: CGRect(x: 20, y: 300, width: 200, height: 30))
    hidden.isHidden = true
    [label, image, hidden].forEach(controller.view.addSubview)
    let window = HostedWindow(controller: controller)
    hosted = window

    let result = WindowMasks.compute(window.window, allowlist: nil, iOSMajor: 18)
    XCTAssertNil(result.fallback)
    XCTAssertEqual(result.stats.uiKitText, 1, "hidden views are skipped")
    XCTAssertEqual(result.stats.uiKitImages, 1)
    XCTAssertEqual(coverage(of: window.frame(of: label), by: result, in: window.window), 1)
    XCTAssertEqual(coverage(of: window.frame(of: hidden), by: result, in: window.window), 0)
  }

  func testAWindowWithoutSizeIsMaskedInFull() {
    let window = UIWindow(frame: .zero)
    XCTAssertEqual(WindowMasks.compute(window), .wholeFrame(.noWindow))
  }

  func testMaskRectsAreClippedAndNormalized() {
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 400)
    XCTAssertEqual(MaskRect(CGRect(x: -10, y: 50, width: 110, height: 50), in: bounds), MaskRect(x: 0, y: 0.125, width: 0.5, height: 0.125))
    XCTAssertNil(MaskRect(CGRect(x: 300, y: 0, width: 10, height: 10), in: bounds))
  }
}
#endif
