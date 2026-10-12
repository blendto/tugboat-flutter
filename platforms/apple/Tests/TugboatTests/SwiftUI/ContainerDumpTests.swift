#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

@testable import Tugboat

/// Prints the platform-view hosts SwiftUI containers create (lines start
/// with `TBDUMP`), so `KnownPlatformViews` entries are verified from CI
/// logs per iOS major. Asserts nothing about the names themselves.
final class ContainerDumpTests: XCTestCase {
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

  func testDumpContainerHosts() {
    var roots: [(String, AnyView)] = [
      ("NavigationView", AnyView(NavigationView { Screen() }.navigationViewStyle(.stack))),
      ("TabView", AnyView(TabView { Screen().tabItem { Text("One") }; Screen().tabItem { Text("Two") } })),
      ("AppController", AnyView(AppControllerHost())),
    ]
    if #available(iOS 16.0, *) {
      roots.insert(("NavigationStack", AnyView(NavigationStack { Screen() })), at: 0)
    }
    for (name, root) in roots {
      let hosted = HostedWindow(root)
      hosted.settle(0.5)
      dump(name, hosted.window)
      hosted.close()
    }
    let sheet = HostedWindow(Text("Base").sheet(isPresented: .constant(true)) { Screen() })
    sheet.settle(1.0)
    dump("sheet", sheet.window)
    sheet.close()
  }

  private func dump(_ root: String, _ window: UIWindow) {
    var stack: [(UIView, Int)] = [(window, 0)]
    while let (view, depth) = stack.popLast() {
      let cls: AnyClass = type(of: view)
      let described = String(describing: cls)
      let interesting = described.contains("PlatformViewHost") || described.contains("HostingView")
        || described.contains("Hosting") || depth < 8
      if interesting {
        let kind = ViewKind.of(view, insideHosting: depth > 1)
        print(
          "TBDUMP \(root) depth=\(depth) kind=\(kind) frame=\(view.frame) described=\(described) "
            + "reflecting=\(String(reflecting: cls)) objc=\(NSStringFromClass(cls))")
      }
      stack.append(contentsOf: view.subviews.reversed().map { ($0, depth + 1) })
    }
  }
}
#endif
