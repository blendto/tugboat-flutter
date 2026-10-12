#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

// TEMPORARY: dumps layer trees on CI to verify the allowlist. Removed before review.
final class LayerDumpDebugTests: XCTestCase {
  private func dump(_ view: UIView, window: UIWindow, depth: Int, into lines: inout [String]) {
    let indent = String(repeating: " ", count: depth)
    lines.append("\(indent)V \(String(describing: type(of: view)).prefix(80)) \(view.convert(view.bounds, to: window))")
    dumpLayer(view.layer, owner: view, window: window, depth: depth + 1, into: &lines)
    for sub in view.subviews { dump(sub, window: window, depth: depth + 1, into: &lines) }
  }

  private func dumpLayer(_ layer: CALayer, owner: UIView, window: UIWindow, depth: Int, into lines: inout [String]) {
    for sub in layer.sublayers ?? [] {
      if let v = sub.delegate as? UIView, v !== owner { continue }
      let indent = String(repeating: " ", count: depth)
      lines.append("\(indent)L \(NSStringFromClass(type(of: sub))) \(sub.convert(sub.bounds, to: window.layer)) contents=\(sub.contents.map { String(describing: type(of: $0)) } ?? "nil") hidden=\(sub.isHidden) opacity=\(sub.opacity)")
      dumpLayer(sub, owner: owner, window: window, depth: depth + 1, into: &lines)
    }
  }

  func testDumpLayers() {
    let variants: [(String, AnyView)] = [
      ("plain", AnyView(VStack { Image(systemName: "star.fill"); Text("Hello") })),
      ("resizable", AnyView(Image(systemName: "star.fill").resizable().frame(width: 40, height: 40))),
      ("list", AnyView(List(0..<2, id: \.self) { Text("Row \($0)") })),
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
