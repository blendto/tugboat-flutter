#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

// TEMPORARY: dumps layer trees on CI to verify the allowlist. Removed before review.
struct DumpRep: UIViewRepresentable {
  func makeUIView(context: Context) -> UIView { UIView() }
  func updateUIView(_ uiView: UIView, context: Context) {}
}

final class LayerDumpDebugTests: XCTestCase {
  private func dump(_ view: UIView, window: UIWindow, depth: Int, into lines: inout [String]) {
    let indent = String(repeating: " ", count: depth)
    lines.append("\(indent)V \(String(describing: type(of: view)).prefix(160)) \(view.convert(view.bounds, to: window))")
    dumpLayer(view.layer, owner: view, window: window, depth: depth + 1, into: &lines)
    for sub in view.subviews { dump(sub, window: window, depth: depth + 1, into: &lines) }
  }

  private func dumpLayer(_ layer: CALayer, owner: UIView, window: UIWindow, depth: Int, into lines: inout [String]) {
    for sub in layer.sublayers ?? [] {
      if let v = sub.delegate as? UIView, v !== owner { continue }
      let indent = String(repeating: " ", count: depth)
      lines.append("\(indent)L \(NSStringFromClass(type(of: sub))) \(sub.convert(sub.bounds, to: window.layer)) contents=\(sub.contents.map { String(describing: type(of: $0)) } ?? "nil") super=\(sub.superclass.map { NSStringFromClass($0) } ?? "-") shape=\(sub is CAShapeLayer) path=\((sub as? CAShapeLayer)?.path?.boundingBox ?? .null) mask=\(sub.mask.map { NSStringFromClass(type(of: $0)) + " c=" + String(sub.mask?.contents != nil) } ?? "nil") bg=\(sub.backgroundColor != nil) subs=\(sub.sublayers?.count ?? 0)")
      dumpLayer(sub, owner: owner, window: window, depth: depth + 1, into: &lines)
    }
  }

  func testDumpLayers() {
    let variants: [(String, AnyView)] = [
      ("plain", AnyView(VStack { Image(systemName: "star.fill"); Text("Hello") })),
      ("resizable", AnyView(Image(systemName: "star.fill").resizable().frame(width: 40, height: 40))),
      ("shapes", AnyView(VStack { Color.red.frame(width: 50, height: 50); Rectangle().fill(Color.blue).frame(width: 60, height: 20); Image(systemName: "heart").font(.largeTitle); Image(systemName: "star.fill").resizable().foregroundColor(.orange).frame(width: 30, height: 30); Image(uiImage: UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }).resizable().frame(width: 30, height: 30) })),
      ("hosts", AnyView(VStack { TextField("x", text: .constant("y")); DumpRep().frame(width: 40, height: 40) })),
    ]
    for (name, view) in variants {
      let window = HostedWindow(view)
      window.settle(0.6)
      var lines: [String] = []
      dump(window.window, window: window.window, depth: 0, into: &lines)
      print("LAYERDUMP \(name)\n" + lines.joined(separator: "\n"))
      XCTFail("LAYERDUMP \(name): " + lines.joined(separator: " || "))
      window.close()
    }
  }
}
#endif
