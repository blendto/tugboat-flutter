#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

/// A visible window hosting a SwiftUI view (or a UIKit controller) at the
/// screen origin, so SwiftUI's `.global` space is the window's.
final class HostedWindow {
  let window: UIWindow

  convenience init<Content: View>(_ content: Content, size: CGSize = CGSize(width: 390, height: 844)) {
    self.init(controller: UIHostingController(rootView: AnyView(content)), size: size)
  }

  init(controller: UIViewController, size: CGSize = CGSize(width: 390, height: 844)) {
    let frame = CGRect(origin: .zero, size: size)
    if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
      window = UIWindow(windowScene: scene)
      window.frame = frame
    } else {
      window = UIWindow(frame: frame)
    }
    window.rootViewController = controller
    window.isHidden = false
    settle()
  }

  var hosting: UIHostingController<AnyView>? {
    window.rootViewController as? UIHostingController<AnyView>
  }

  /// Lets SwiftUI lay out, render, and run appear callbacks.
  func settle(_ seconds: TimeInterval = 0.25) {
    window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    window.layoutIfNeeded()
  }

  /// Spins the run loop until `condition` holds or `timeout` passes.
  @discardableResult
  func wait(timeout: TimeInterval = 3, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline { return false }
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      window.layoutIfNeeded()
    }
    return true
  }

  /// Every view of type `T` in the window, in subview order.
  func views<T: UIView>(_ type: T.Type) -> [T] {
    var out: [T] = []
    var stack: [UIView] = [window]
    while let view = stack.popLast() {
      if let match = view as? T {
        out.append(match)
      }
      stack.append(contentsOf: view.subviews.reversed())
    }
    return out
  }

  func frame(of view: UIView) -> CGRect {
    view.convert(view.bounds, to: window)
  }

  func close() {
    window.isHidden = true
    window.rootViewController = nil
  }
}

/// Ground-truth frames (`.global`) recorded by the views under test.
final class TruthFrames {
  private(set) var frames: [String: CGRect] = [:]

  func record(_ name: String, _ frame: CGRect) {
    frames[name] = frame
  }
}

extension View {
  /// Records this view's `.global` frame under `name`.
  func truth(_ name: String, in store: TruthFrames) -> some View {
    background(GeometryReader { proxy in
      Color.clear
        .onAppear { store.record(name, proxy.frame(in: .global)) }
        .onChange(of: proxy.frame(in: .global)) { store.record(name, $0) }
    })
  }
}
#endif
