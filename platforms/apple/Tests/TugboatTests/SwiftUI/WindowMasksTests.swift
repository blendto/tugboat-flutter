#if canImport(UIKit)
import SwiftUI
import UIKit
import WebKit
import XCTest

@testable import Tugboat

/// Masks per native SDK note 2.1 (SwiftUI row) and 6.3, on a screen with
/// Text, images, a TextField, a List, a WKWebView, and a representable; and
/// the layer-allowlist regression guard.
final class WindowMasksTests: XCTestCase {
  private var hosted: HostedWindow?

  override func tearDown() {
    hosted?.close()
    hosted = nil
    super.tearDown()
  }

  private final class AppView: UIView {}

  private struct WebViewHost: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
      let web = WKWebView()
      web.loadHTMLString("<p>secret</p>", baseURL: nil)
      return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
  }

  private struct AppViewHost: UIViewRepresentable {
    func makeUIView(context: Context) -> AppView {
      let view = AppView()
      view.backgroundColor = .systemTeal
      return view
    }

    func updateUIView(_ uiView: AppView, context: Context) {}
  }

  private func hostMixedScreen(_ truth: TruthFrames) -> HostedWindow {
    let window = HostedWindow(
      VStack(spacing: 8) {
        Text("Account balance").font(.title).truth("text", in: truth)
        HStack {
          Image(systemName: "star.fill").resizable().frame(width: 40, height: 40).truth("symbol", in: truth)
          Image(uiImage: TestImages.swatch).resizable().frame(width: 40, height: 40).truth("photo", in: truth)
        }
        TextField("Email", text: .constant("someone@example.com")).textFieldStyle(.roundedBorder).padding(.horizontal)
        List(0..<5, id: \.self) { Text("Row \($0)").truth("row\($0)", in: truth) }.frame(height: 220)
        WebViewHost().frame(height: 80).truth("web", in: truth)
        AppViewHost().frame(width: 60, height: 30).truth("representable", in: truth)
        Spacer()
      }
    )
    hosted = window
    window.wait { truth.frames.count >= 5 && !window.views(UITextField.self).isEmpty }
    window.settle(0.5)
    return window
  }

  func testLayerAllowlistRegressionGuard() throws {
    let truth = TruthFrames()
    let window = hostMixedScreen(truth)
    let major = LayerAllowlist.runningMajor
    guard let allowlist = LayerAllowlist.forMajor(major) else {
      let result = window.settledMasks()
      XCTAssertEqual(result.fallback, .unverifiedLayerAllowlist(iOSMajor: major))
      XCTAssertEqual(result.rects, [.fullFrame])
      return
    }
    let result = window.settledMasks(allowlist: allowlist)
    let found = "found \(result.stats); verify iOS \(major) with the probe (spike/swiftui-a11y-probe)"
    XCTAssertNil(result.fallback, found)
    XCTAssertGreaterThan(result.stats.textLayers, 0, "REGRESSION: no CGDrawingLayer on a screen with text; \(found)")
    XCTAssertGreaterThan(result.stats.imageLayers, 0, "REGRESSION: no SwiftUI.ImageLayer on a screen with a bitmap image; \(found)")
  }

  func testEveryMaskSourceIsCovered() throws {
    let truth = TruthFrames()
    let window = hostMixedScreen(truth)
    let result = window.settledMasks()
    try XCTSkipIf(result.fallback == .unverifiedLayerAllowlist(iOSMajor: LayerAllowlist.runningMajor), "unverified iOS major")
    XCTAssertNil(result.fallback)

    for name in ["text", "symbol", "photo", "row0", "row1", "web", "representable"] {
      let frame = try XCTUnwrap(truth.frames[name], "no truth frame for \(name)")
      XCTAssertGreaterThanOrEqual(result.fractionMasked(of: frame, in: window.window), 0.9, "\(name) at \(frame) not masked; \(result.stats)")
    }
    let field = try XCTUnwrap(window.views(UITextField.self).first)
    XCTAssertEqual(result.fractionMasked(of: window.frame(of: field), in: window.window), 1, "text field")
    let web = try XCTUnwrap(window.views(WKWebView.self).first)
    XCTAssertEqual(result.fractionMasked(of: window.frame(of: web), in: window.window), 1, "web view, fail-closed")
    XCTAssertEqual(result.stats.failClosedViews, 2, "the web view and the app representable are boxes; List and TextField are walked")
    XCTAssertEqual(result.coverage.mode, .precise)
    XCTAssertTrue(result.coverage.reasons.contains(.webView), "\(result.coverage)")
    XCTAssertTrue(result.coverage.reasons.contains(.representable), "\(result.coverage)")

    let row = try XCTUnwrap(truth.frames["row0"])
    let rowEnd = CGRect(x: window.window.bounds.width - 70, y: row.minY, width: 30, height: row.height)
    XCTAssertLessThan(result.fractionMasked(of: rowEnd, in: window.window), 1, "rows are masked per text, not as one list box")
    let blank = CGRect(x: 0, y: window.window.bounds.height - 60, width: window.window.bounds.width, height: 40)
    XCTAssertLessThan(result.fractionMasked(of: blank, in: window.window), 1, "empty space stays visible: masks are per region")
  }

  func testBitmapImagesArePaddedAndShapesAreNot() throws {
    let truth = TruthFrames()
    let window = HostedWindow(
      VStack(spacing: 60) {
        Image(uiImage: TestImages.swatch).resizable().frame(width: 40, height: 40).truth("photo", in: truth)
        Image(systemName: "star.fill").resizable().frame(width: 40, height: 40).truth("symbol", in: truth)
      }
    )
    hosted = window
    window.wait { truth.frames.count == 2 }
    window.settle(0.3)
    let result = window.settledMasks()
    try XCTSkipIf(result.fallback == .unverifiedLayerAllowlist(iOSMajor: LayerAllowlist.runningMajor), "unverified iOS major")
    let photo = try XCTUnwrap(truth.frames["photo"])
    let symbol = try XCTUnwrap(truth.frames["symbol"])
    XCTAssertEqual(result.stats.imageLayers, 1, "\(result.stats)")
    XCTAssertEqual(result.stats.shapeLayers, 1, "\(result.stats)")
    XCTAssertEqual(result.fractionMasked(of: photo.insetBy(dx: -3, dy: -3), in: window.window), 1, "image layers are padded by 4 pt")
    XCTAssertEqual(result.fractionMasked(of: symbol, in: window.window), 1, "the symbol's shape layer")
    XCTAssertLessThan(result.fractionMasked(of: symbol.insetBy(dx: -3, dy: -3), in: window.window), 1, "shape layers are not padded")
  }

  func testTagMarkersAreNotMaskedAsRepresentables() throws {
    let registry = TagRegistry()
    let window = HostedWindow(Text("Tagged").padding(20).modifier(TugboatTagModifier(tag: "t", registry: registry)))
    hosted = window
    XCTAssertTrue(window.wait { registry.all.contains { $0.window != nil } })
    let result = window.settledMasks()
    try XCTSkipIf(result.fallback == .unverifiedLayerAllowlist(iOSMajor: LayerAllowlist.runningMajor), "unverified iOS major")
    XCTAssertEqual(result.stats.failClosedViews, 0)
  }

  func testAnUnverifiedMajorMasksAWindowWithSwiftUIInFull() {
    let window = HostedWindow(Text("Hello"))
    hosted = window
    let unverified = window.settledMasks(allowlist: nil)
    XCTAssertEqual(unverified.fallback, .unverifiedLayerAllowlist(iOSMajor: LayerAllowlist.runningMajor))
    XCTAssertEqual(unverified.coverage, MaskCoverage(mode: .wholeFrame, reasons: [.unverifiedLayerAllowlist]))
    XCTAssertEqual(WindowMasks.compute(window.window, allowlist: nil, iOSMajor: 18).rects, [.fullFrame])
  }

  func testAnUnverifiedSwiftUIPlatformViewIsABox() throws {
    let window = HostedWindow(List(0..<3, id: \.self) { Text("Row \($0)") })
    hosted = window
    let verified = try XCTUnwrap(LayerAllowlist.forMajor(26))
    let other = LayerAllowlist(
      major: 99, textClasses: verified.textClasses, imageClasses: verified.imageClasses, shapeClasses: verified.shapeClasses
    )
    let result = window.settledMasks(allowlist: other)
    XCTAssertNil(result.fallback)
    XCTAssertEqual(result.stats.failClosedViews, 1, "the List host is not verified for this major: \(result.stats)")
  }

  func testMaskRectsAreClippedAndNormalized() {
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 400)
    XCTAssertEqual(MaskRect(CGRect(x: -10, y: 50, width: 110, height: 50), in: bounds), MaskRect(x: 0, y: 0.125, width: 0.5, height: 0.125))
    XCTAssertNil(MaskRect(CGRect(x: 300, y: 0, width: 10, height: 10), in: bounds))
  }
}
#endif
