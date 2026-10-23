#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

@testable import Tugboat

/// `.tugboatSensitive`: masked in every mask mode, one rect per marker, and
/// no change to tap targets, canonical paths or fingerprints.
final class SwiftUISensitiveTests: XCTestCase {
  private var hosted: HostedWindow?

  override func tearDown() {
    hosted?.close()
    hosted = nil
    super.tearDown()
  }

  /// Applies `.tugboatSensitive()` only when `on`, so one screen is built
  /// with and without the marker.
  private struct Marked: ViewModifier {
    let on: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
      if on {
        content.tugboatSensitive()
      } else {
        content
      }
    }
  }

  /// An app-defined view: its SwiftUI host is a `Representable` tap target,
  /// so a marker host counted as one would shift the ordinals.
  private final class AppBoxView: UIView {}

  private struct AppBox: UIViewRepresentable {
    func makeUIView(context: Context) -> AppBoxView {
      let view = AppBoxView(frame: .zero)
      view.backgroundColor = .systemTeal
      return view
    }

    func updateUIView(_ uiView: AppBoxView, context: Context) {}
  }

  /// A plain fill beside a marked one: plain colour fills are contents-less
  /// layers that the verified allowlist leaves visible.
  private func hostFills(_ truth: TruthFrames) -> HostedWindow {
    let window = HostedWindow(
      HStack(spacing: 16) {
        Color.red.frame(width: 44, height: 44).truth("plain", in: truth)
        Color.blue.frame(width: 44, height: 44).tugboatSensitive().truth("sensitive", in: truth)
      }
    )
    hosted = window
    XCTAssertTrue(window.wait { truth.frames["sensitive"] != nil && truth.frames["plain"] != nil && !window.views(SensitiveMarkerView.self).isEmpty })
    return window
  }

  func testTheSensitiveFrameIsMaskedOnTheVerifiedLayerAllowlistPath() throws {
    let truth = TruthFrames()
    let window = hostFills(truth)
    let allowlist = try XCTUnwrap(LayerAllowlist.forMajor(LayerAllowlist.runningMajor) ?? LayerAllowlist.forMajor(26))
    let result = window.settledMasks(allowlist: allowlist)
    XCTAssertNil(result.fallback, "\(result.stats)")
    let sensitive = try XCTUnwrap(truth.frames["sensitive"])
    let plain = try XCTUnwrap(truth.frames["plain"])
    XCTAssertEqual(result.fractionMasked(of: sensitive, in: window.window), 1, "\(result.rects)")
    XCTAssertLessThan(result.fractionMasked(of: plain, in: window.window), 0.2, "the same fill unmarked stays visible")
    XCTAssertEqual(result.stats.sensitiveViews, 1)
  }

  func testTheSensitiveFrameIsMaskedOnTheWholeFrameFallback() throws {
    let truth = TruthFrames()
    let window = hostFills(truth)
    let result = window.settledMasks(allowlist: nil)
    XCTAssertEqual(result.fallback, .unverifiedLayerAllowlist(iOSMajor: LayerAllowlist.runningMajor))
    let sensitive = try XCTUnwrap(truth.frames["sensitive"])
    XCTAssertEqual(result.fractionMasked(of: sensitive, in: window.window), 1)
  }

  func testMarkingMaskedTextAddsOneRectAndRemovesNone() throws {
    let allowlist = try XCTUnwrap(LayerAllowlist.forMajor(LayerAllowlist.runningMajor) ?? LayerAllowlist.forMajor(26))
    let before = masks(of: Text("Account 1234").padding(8).modifier(Marked(on: false)), allowlist: allowlist)
    let after = masks(of: Text("Account 1234").padding(8).modifier(Marked(on: true)), allowlist: allowlist)
    XCTAssertNil(after.fallback, "\(after.stats)")
    XCTAssertTrue(before.rects.allSatisfy { after.rects.contains($0) }, "no rect removed: \(before.rects) vs \(after.rects)")
    XCTAssertEqual(after.rects.count, before.rects.count + 1, "only the marked frame is added: \(after.rects)")
    XCTAssertEqual(after.stats.sensitiveViews, 1)
  }

  func testMarkingChangesNoTapTargetPathOrFingerprint() throws {
    let plain = try taps(marked: false)
    let marked = try taps(marked: true)
    XCTAssertEqual(plain.count, 6)
    XCTAssertEqual(plain, marked)
    for (unmarked, sensitive) in zip(plain, marked) {
      guard case let .anchor(a) = unmarked, case let .anchor(b) = sensitive else { continue }
      XCTAssertEqual(a.canonicalPath, b.canonicalPath)
      XCTAssertEqual(a.fingerprint, b.fingerprint)
      XCTAssertEqual(a.widgetType, b.widgetType)
    }
    let paths = [0, 1, 3, 4, 5].compactMap { index -> String? in
      guard case let .anchor(anchor) = plain[index] else { return nil }
      return anchor.canonicalPath
    }
    XCTAssertEqual(paths.count, 5, "A, B, C and both boxes resolve: \(plain)")
    XCTAssertEqual(Set(paths).count, 5, "five distinct targets: \(paths)")
  }

  func testTheSensitiveMarkerNeverTakesPartInHitTesting() throws {
    let window = HostedWindow(Text("Secret").padding(30).tugboatSensitive())
    hosted = window
    XCTAssertTrue(window.wait { !window.views(SensitiveMarkerView.self).isEmpty })
    let marker = try XCTUnwrap(window.views(SensitiveMarkerView.self).first)
    let frame = window.frame(of: marker)
    let hit = window.window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
    XCTAssertFalse(hit is SensitiveMarkerView)
    XCTAssertFalse(hit === marker.superview, "the marker's SwiftUI host does not take touches")
    XCTAssertFalse(marker.isUserInteractionEnabled)
    XCTAssertTrue(marker.accessibilityElementsHidden)
  }

  private func masks<Content: View>(of content: Content, allowlist: LayerAllowlist) -> MaskResult {
    let window = HostedWindow(content)
    defer { window.close() }
    window.settle(0.3)
    return window.settledMasks(allowlist: allowlist)
  }

  /// Taps on A, B, the blank padding left of B, C, R1 and R2, on
  /// `A; VStack { B }.padding(12) (marked); C (marked); R1; R2 (marked)`,
  /// where R1 and R2 are app representables.
  private func taps(marked: Bool) throws -> [TapEvidence] {
    let screens = ScreenTracker(clock: ManualClock())
    let window = HostedWindow(
      VStack(spacing: 24) {
        TextField("A", text: .constant("")).textFieldStyle(.roundedBorder)
        VStack {
          TextField("B", text: .constant("")).textFieldStyle(.roundedBorder)
        }
        .padding(12)
        .modifier(Marked(on: marked))
        TextField("C", text: .constant("")).textFieldStyle(.roundedBorder).modifier(Marked(on: marked))
        AppBox().frame(height: 44)
        AppBox().frame(height: 44).modifier(Marked(on: marked))
        Spacer()
      }
      .padding()
      .modifier(TugboatScreenModifier(name: "Form", tracker: screens))
    )
    defer { window.close() }
    XCTAssertTrue(window.wait { window.views(UITextField.self).count == 3 && window.views(AppBoxView.self).count == 2 })
    if marked {
      XCTAssertTrue(window.wait { window.views(SensitiveMarkerView.self).count == 3 })
    }
    window.settle()
    let resolver = AnchorResolver(tags: TagRegistry(), screens: screens)
    let fields = window.views(UITextField.self).map { window.frame(of: $0) }.sorted { $0.minY < $1.minY }
    XCTAssertEqual(fields.count, 3)
    let b = try XCTUnwrap(fields.dropFirst().first)
    let points = fields.map { CGPoint(x: $0.midX, y: $0.midY) }
    let padding = CGPoint(x: b.minX - 6, y: b.midY)
    let boxes = window.views(AppBoxView.self).map { window.frame(of: $0) }.sorted { $0.minY < $1.minY }
    let boxPoints = boxes.map { CGPoint(x: $0.midX, y: $0.midY) }
    return ([points[0], points[1], padding, points[2]] + boxPoints).map { resolver.tapEvidence(in: window.window, at: $0) }
  }
}
#endif
