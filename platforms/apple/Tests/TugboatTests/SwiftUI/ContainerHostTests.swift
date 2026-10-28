#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

@testable import Tugboat

/// SwiftUI's own container hosts are walked and an app's view-controller
/// representable is a box. Prints every host (lines start with `TBDUMP`),
/// so `KnownPlatformViews` entries can be verified from CI logs on a new
/// iOS major.
final class ContainerHostTests: XCTestCase {
  private final class AppController: UIViewController {}

  private struct AppControllerHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AppController { AppController() }
    func updateUIViewController(_ controller: AppController, context: Context) {}
  }

  private struct Screen: View {
    var body: some View {
      VStack {
        Text("Container screen")
        ScrollView { Text("Scrolled text") }
      }
    }
  }

  func testContainerHostsAreWalkedAndAppHostsAreBoxes() {
    var roots: [(String, AnyView)] = [
      ("NavigationView", AnyView(NavigationView { Screen() }.navigationViewStyle(.stack))),
      ("TabView", AnyView(TabView { Screen().tabItem { Text("One") }; Screen().tabItem { Text("Two") } })),
      ("AppController", AnyView(AppControllerHost())),
    ]
    if #available(iOS 16.0, *) {
      roots.insert(("NavigationStack", AnyView(NavigationStack { Screen() })), at: 0)
    }
    let verified = LayerAllowlist.forMajor(LayerAllowlist.runningMajor) != nil
    for (name, root) in roots {
      let hosted = HostedWindow(root)
      hosted.settle(0.5)
      let kinds = dump(name, hosted.window)
      hosted.close()
      guard verified else { continue }
      if name == "AppController" {
        XCTAssertTrue(kinds.contains(.representable), "an app view-controller representable is a box")
      } else {
        XCTAssertTrue(kinds.contains(.internalPlatformView), "\(name): its host is walked")
        XCTAssertFalse(kinds.contains(.representable), "\(name): no box")
      }
    }
    let sheet = HostedWindow(Text("Base").sheet(isPresented: .constant(true)) { Screen() })
    sheet.settle(1.0)
    _ = dump("sheet", sheet.window)
    sheet.close()
  }

  /// Prints the hosts under `window` and returns the kinds of its
  /// platform-view hosts.
  private func dump(_ root: String, _ window: UIWindow) -> [ViewKind] {
    var hostKinds: [ViewKind] = []
    var stack: [(UIView, Int)] = [(window, 0)]
    while let (view, depth) = stack.popLast() {
      let cls: AnyClass = type(of: view)
      let described = String(describing: cls)
      let interesting = described.contains("PlatformViewHost") || described.contains("HostingView")
        || described.contains("Hosting") || depth < 8
      if let keys = view.layer.animationKeys(), !keys.isEmpty {
        print("TBANIM \(root) depth=\(depth) described=\(described) keys=\(keys)")
      }
      if interesting {
        let kind = ViewKind.of(view, insideHosting: depth > 1)
        if described.contains("PlatformViewHost") {
          hostKinds.append(kind)
        }
        print(
          "TBDUMP \(root) depth=\(depth) kind=\(kind) frame=\(view.frame) described=\(described) "
            + "reflecting=\(String(reflecting: cls)) objc=\(NSStringFromClass(cls))")
      }
      stack.append(contentsOf: view.subviews.reversed().map { ($0, depth + 1) })
    }
    return hostKinds
  }
}
#endif
