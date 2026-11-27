#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

@testable import Tugboat

/// Prints SwiftUI's layer classes and the IoU of each class's layer frames
/// against the view's `.global` frame (`TBDUMP` lines), to verify the layer
/// allowlist for a new iOS major (design note 6.3). Re-run it on each new
/// major (simulator or device) and read the `TBDUMP` lines. It also asserts
/// that the verified classes cover text and images; an unverified major has
/// no allowlist to check, so it only prints.
final class LayerProbeTests: XCTestCase {
  private var hosted: HostedWindow?

  override func tearDown() {
    hosted?.close()
    hosted = nil
    super.tearDown()
  }

  private func layers(in window: UIWindow) -> [(name: String, frame: CGRect, contents: Bool, path: Bool)] {
    var out: [(String, CGRect, Bool, Bool)] = []
    func visit(_ layer: CALayer) {
      if layer.isHidden || layer.opacity < 0.01 { return }
      let frame = layer.convert(layer.bounds, to: window.layer)
      let path = ((layer as? CAShapeLayer)?.path).map { !$0.boundingBoxOfPath.isEmpty } ?? false
      out.append((NSStringFromClass(type(of: layer)), frame, layer.contents != nil, path))
      for sub in layer.sublayers ?? [] { visit(sub) }
    }
    visit(window.layer)
    return out
  }

  private func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let i = a.intersection(b)
    if i.isNull || i.isEmpty { return 0 }
    let inter = Double(i.width * i.height)
    return inter / (Double(a.width * a.height) + Double(b.width * b.height) - inter)
  }

  func testDumpLayerClasses() {
    let truth = TruthFrames()
    let window = HostedWindow(
      VStack(spacing: 24) {
        Text("Account balance").font(.title).truth("text", in: truth)
        Text("A longer line of body text to measure the text layer").truth("body", in: truth)
        Image(uiImage: TestImages.swatch).resizable().frame(width: 80, height: 80).truth("photo", in: truth)
        Image(systemName: "star.fill").resizable().frame(width: 40, height: 40).truth("symbolResizable", in: truth)
        Image(systemName: "star.fill").font(.largeTitle).truth("symbolFont", in: truth)
        Label("Settings", systemImage: "gear").truth("label", in: truth)
        Color.red.frame(width: 44, height: 44).truth("fill", in: truth)
        Circle().fill(Color.blue).frame(width: 44, height: 44).truth("circle", in: truth)
        Spacer()
      }
    )
    hosted = window
    window.wait { truth.frames.count >= 8 }
    window.settle(0.8)
    let all = layers(in: window.window)
    print("TBDUMP iOS \(ProcessInfo.processInfo.operatingSystemVersionString) major \(LayerAllowlist.runningMajor)")
    for layer in all where layer.contents || layer.path || layer.name.contains("SwiftUI") {
      print("TBDUMP layer \(layer.name) frame=\(layer.frame) contents=\(layer.contents) path=\(layer.path)")
    }
    for (name, frame) in truth.frames.sorted(by: { $0.key < $1.key }) {
      let hits = all.filter { ($0.contents || $0.path) && $0.frame.intersects(frame) }
      let desc = hits.map { "\($0.name.suffix(28)) iou=\(String(format: "%.2f", iou($0.frame, frame)))" }
      print("TBDUMP truth \(name) \(frame): \(desc)")
    }

    guard let allowlist = LayerAllowlist.forMajor(LayerAllowlist.runningMajor) else { return }
    func best(_ name: String, classes: Set<String>) -> Double {
      let frame = truth.frames[name] ?? .zero
      return all.filter { classes.contains($0.name) }.map { iou($0.frame, frame) }.max() ?? 0
    }
    XCTAssertGreaterThan(best("text", classes: allowlist.textClasses), 0.95)
    XCTAssertGreaterThan(best("body", classes: allowlist.textClasses), 0.95)
    XCTAssertGreaterThan(best("photo", classes: allowlist.imageClasses), 0.7)
    XCTAssertGreaterThan(best("symbolResizable", classes: allowlist.shapeClasses.union(allowlist.imageClasses)), 0.7)
    // Everything drawn with contents or a path is classified: no layer the allowlist misses.
    let known = allowlist.textClasses.union(allowlist.imageClasses).union(allowlist.shapeClasses)
    let unknown = all.filter { ($0.contents || $0.path) && !known.contains($0.name) }
    XCTAssertTrue(unknown.isEmpty, "unclassified layers on iOS \(allowlist.major): \(unknown.map { $0.name })")
  }
}
#endif
