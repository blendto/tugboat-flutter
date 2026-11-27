#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

@testable import Tugboat

/// Screens rooted in SwiftUI's own containers (`NavigationStack`,
/// `NavigationView`, `TabView`): their platform-view hosts are walked, so
/// text inside is masked per layer (not one box over the window), taps
/// resolve to real targets, and scroll views inside are found. App
/// representables stay fail-closed boxes with `low` confidence.
final class NavigationContainerTests: XCTestCase {
  private var hosted: HostedWindow?
  private let registry = TagRegistry()
  private let screens = ScreenTracker(clock: ManualClock())

  override func tearDown() {
    hosted?.close()
    hosted = nil
    super.tearDown()
  }

  private final class AppView: UIView {}

  private struct AppViewHost: UIViewRepresentable {
    func makeUIView(context: Context) -> AppView {
      let view = AppView()
      view.backgroundColor = .systemTeal
      return view
    }

    func updateUIView(_ uiView: AppView, context: Context) {}
  }

  private struct Content: View {
    let truth: TruthFrames
    let screens: ScreenTracker

    var body: some View {
      VStack(spacing: 24) {
        Text("Account balance").font(.title).truth("text", in: truth)
        AppViewHost().frame(width: 80, height: 40).truth("app", in: truth)
        List(0..<20, id: \.self) { Text("Row \($0)") }.frame(height: 300)
        Spacer()
      }
      .navigationTitle("Home")
      .modifier(TugboatScreenModifier(name: "Home", tracker: screens))
    }
  }

  private func host(_ root: AnyView, truth: TruthFrames) -> HostedWindow {
    let window = HostedWindow(root)
    hosted = window
    XCTAssertTrue(window.wait { truth.frames.count >= 2 && !window.views(UICollectionViewCell.self).isEmpty })
    window.settle(0.5)
    return window
  }

  /// `TabView` is left out of the mask checks: on iOS 26.5 its floating tab
  /// bar keeps a layer animation running, so its frames are masked whole
  /// (`animating`, fail closed; decisions log). Its host is still walked
  /// (`ContainerHostTests`).
  private var containers: [String] {
    if #available(iOS 16.0, *) {
      return ["NavigationStack", "NavigationView"]
    }
    return ["NavigationView"]
  }

  private func root(_ container: String, _ truth: TruthFrames) -> AnyView {
    let content = Content(truth: truth, screens: screens)
    switch container {
    case "NavigationView":
      return AnyView(NavigationView { content }.navigationViewStyle(.stack))
    case "TabView":
      return AnyView(TabView { content.tabItem { Text("Home") } })
    default:
      if #available(iOS 16.0, *) {
        return AnyView(NavigationStack { content })
      }
      return AnyView(content)
    }
  }

  func testContainerScreensAreMaskedPerRegion() throws {
    try XCTSkipIf(LayerAllowlist.forMajor(LayerAllowlist.runningMajor) == nil, "unverified iOS major")
    for name in containers {
      let truth = TruthFrames()
      let window = host(root(name, truth), truth: truth)
      let result = window.settledMasks()
      XCTAssertNil(result.fallback, "\(name): \(result.stats)")
      XCTAssertEqual(result.coverage.mode, .precise, "\(name): \(result.coverage) \(result.stats)")
      XCTAssertLessThan(result.stats.largestBoxFraction, 0.5, "\(name): no box over the screen")
      XCTAssertEqual(result.stats.representableBoxes, 1, "\(name): only the app representable is a box")
      // Below the list, above any bottom bar: nothing there to mask.
      let blank = CGRect(x: 0, y: window.window.bounds.height * 0.76, width: window.window.bounds.width, height: 30)
      XCTAssertLessThan(result.fractionMasked(of: blank, in: window.window), 1, "\(name): empty space stays visible")
      window.close()
      hosted = nil
    }
  }

  @available(iOS 16.0, *)
  private func hostStack(_ truth: TruthFrames) -> HostedWindow {
    host(AnyView(NavigationStack { Content(truth: truth, screens: screens) }), truth: truth)
  }

  func testTextInsideANavigationStackIsMaskedPerLayer() throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("NavigationStack needs iOS 16") }
    try XCTSkipIf(LayerAllowlist.forMajor(LayerAllowlist.runningMajor) == nil, "unverified iOS major")
    let truth = TruthFrames()
    let window = hostStack(truth)
    let result = window.settledMasks()
    let text = try XCTUnwrap(truth.frames["text"])
    let app = try XCTUnwrap(truth.frames["app"])
    XCTAssertGreaterThanOrEqual(result.fractionMasked(of: text, in: window.window), 0.9, "\(result.stats)")
    XCTAssertGreaterThanOrEqual(result.fractionMasked(of: app, in: window.window), 0.99, "the app view is a box")
    XCTAssertGreaterThan(result.stats.textLayers, 0)
    XCTAssertEqual(result.coverage.mode, .precise, "\(result.coverage)")
    XCTAssertTrue(result.coverage.reasons.contains(.representable), "\(result.coverage)")
  }

  func testTapsInsideANavigationStackResolveToTheirTargets() throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("NavigationStack needs iOS 16") }
    let truth = TruthFrames()
    let window = hostStack(truth)
    let resolver = AnchorResolver(tags: registry, screens: screens)
    let cell = try XCTUnwrap(
      window.views(UICollectionViewCell.self).sorted { window.frame(of: $0).minY < window.frame(of: $1).minY }.dropFirst().first)
    let cellCentre = CGPoint(x: window.frame(of: cell).midX, y: window.frame(of: cell).midY)
    guard case let .anchor(row) = resolver.tapEvidence(in: window.window, at: cellCentre) else {
      return XCTFail("a list row resolves")
    }
    XCTAssertFalse(row.canonicalPath.contains(CanonicalPath.boxToken), row.canonicalPath)
    XCTAssertTrue(row.canonicalPath.contains("[item:"), row.canonicalPath)
    XCTAssertEqual(row.confidence, .medium)

    let app = try XCTUnwrap(truth.frames["app"])
    guard case let .anchor(box) = resolver.tapEvidence(in: window.window, at: CGPoint(x: app.midX, y: app.midY)) else {
      return XCTFail("the app representable resolves")
    }
    XCTAssertTrue(box.canonicalPath.contains(CanonicalPath.boxToken), box.canonicalPath)
    XCTAssertEqual(box.confidence, .low, "a fail-closed box is never high or medium without a tag")
    XCTAssertNotEqual(box.fingerprint, row.fingerprint)
  }

  func testScrollViewsInsideANavigationStackAreFoundWithTheirOwnAnchor() throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("NavigationStack needs iOS 16") }
    let truth = TruthFrames()
    let window = hostStack(truth)
    let resolver = AnchorResolver(tags: registry, screens: screens)
    var facts: [AdapterFact] = []
    let observer = ScrollObserver(
      clock: FactClock(clock: ManualClock()),
      anchorFor: { resolver.anchor(for: $0, in: window.window) },
      emit: { facts.append($0) },
      requestFrame: {})
    observer.discover(in: window.window)
    XCTAssertGreaterThanOrEqual(observer.observedCount, 1)
    let list = try XCTUnwrap(window.views(UICollectionView.self).first)
    list.contentOffset = CGPoint(x: 0, y: list.contentOffset.y + 120)
    observer.onFrame()
    observer.stop()
    let start = try XCTUnwrap(facts.first { $0.decodedInput["phase"] as? String == "start" })
    let path = (start.decodedInput["anchor"] as? [String: Any])?["canonicalPath"] as? String
    XCTAssertNotNil(path)
    XCTAssertFalse(path?.contains(CanonicalPath.boxToken) ?? true, path ?? "")
  }
}
#endif
