#if canImport(UIKit)
import QuartzCore
import UIKit
import XCTest

@testable import Tugboat

/// The fail-closed rules of the mask walk on UIKit content: animations,
/// zero-size containers, the depth limit, opaque renderers, and windows
/// that need no SwiftUI allowlist.
final class WindowMaskFailClosedTests: XCTestCase {
  private var hosted: HostedWindow?

  override func tearDown() {
    hosted?.close()
    hosted = nil
    super.tearDown()
  }

  private final class MetalBackedView: UIView {
    override class var layerClass: AnyClass {
      CAMetalLayer.self
    }
  }

  /// A window whose root view holds `subviews`, with nothing animating.
  private func host(_ subviews: [UIView]) -> HostedWindow {
    let controller = UIViewController()
    subviews.forEach(controller.view.addSubview)
    let window = HostedWindow(controller: controller)
    hosted = window
    _ = window.settledMasks(allowlist: nil)
    return window
  }

  func testAUIKitOnlyWindowNeedsNoAllowlist() {
    let label = UILabel(frame: CGRect(x: 20, y: 100, width: 200, height: 30))
    label.text = "Secret"
    let image = UIImageView(frame: CGRect(x: 20, y: 200, width: 50, height: 50))
    let hidden = UILabel(frame: CGRect(x: 20, y: 300, width: 200, height: 30))
    hidden.isHidden = true
    let window = host([label, image, hidden])

    let result = window.settledMasks(allowlist: nil)
    XCTAssertNil(result.fallback)
    XCTAssertEqual(result.stats.uiKitText, 1, "hidden views are skipped")
    XCTAssertEqual(result.stats.uiKitImages, 1)
    XCTAssertEqual(result.coverage(of: window.frame(of: label), in: window.window), 1)
    XCTAssertEqual(result.coverage(of: window.frame(of: hidden), in: window.window), 0)
  }

  func testAnAnimationAnywhereMasksTheWholeFrame() {
    let moving = UIView(frame: CGRect(x: 20, y: 100, width: 100, height: 100))
    let label = UILabel(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
    label.text = "Moving"
    moving.addSubview(label)
    let window = host([moving])

    let slide = CABasicAnimation(keyPath: "position.x")
    slide.fromValue = 20
    slide.toValue = 300
    slide.duration = 60
    moving.layer.add(slide, forKey: "slide")
    let animating = WindowMasks.compute(window.window, allowlist: nil)
    XCTAssertEqual(animating.fallback, .animating)
    XCTAssertEqual(animating.rects, [.fullFrame])

    moving.layer.removeAllAnimations()
    let sublayer = CALayer()
    moving.layer.addSublayer(sublayer)
    sublayer.add(slide, forKey: "slide")
    XCTAssertEqual(WindowMasks.compute(window.window, allowlist: nil).fallback, .animating, "a sublayer animating counts too")
  }

  func testAZeroSizeContainerStillShowsItsSubviewsUnlessItClips() {
    let container = UIView(frame: CGRect(x: 20, y: 100, width: 0, height: 0))
    let label = UILabel(frame: CGRect(x: 0, y: 0, width: 150, height: 30))
    label.text = "Overflowing"
    container.addSubview(label)
    let window = host([container])

    var result = window.settledMasks(allowlist: nil)
    XCTAssertEqual(result.coverage(of: window.frame(of: label), in: window.window), 1, "drawn outside its zero-size parent")

    container.clipsToBounds = true
    result = window.settledMasks(allowlist: nil)
    XCTAssertEqual(result.coverage(of: window.frame(of: label), in: window.window), 0, "clipped away, so not visible")
  }

  func testLayersDeeperThanTheLimitMaskTheWholeFrame() {
    let deep = UIView(frame: CGRect(x: 20, y: 100, width: 100, height: 100))
    var parent = deep.layer
    for _ in 0...(LayerWalk.maxDepth + 1) {
      let child = CALayer()
      parent.addSublayer(child)
      parent = child
    }
    let window = host([deep])
    let result = window.settledMasks(allowlist: nil)
    XCTAssertEqual(result.fallback, .walkLimitExceeded)
    XCTAssertEqual(result.rects, [.fullFrame])
  }

  func testOpaqueRenderersAreBoxes() {
    let metalView = MetalBackedView(frame: CGRect(x: 20, y: 100, width: 80, height: 80))
    let player = UIView(frame: CGRect(x: 20, y: 300, width: 120, height: 80))
    let metalLayer = CAMetalLayer()
    metalLayer.frame = player.bounds
    player.layer.addSublayer(metalLayer)
    let window = host([metalView, player])

    let result = window.settledMasks(allowlist: nil)
    XCTAssertNil(result.fallback)
    XCTAssertEqual(result.stats.failClosedViews, 1, "a view backed by a renderer layer")
    XCTAssertEqual(result.stats.rendererLayers, 1, "a renderer sublayer of a plain view")
    XCTAssertEqual(result.coverage(of: window.frame(of: metalView), in: window.window), 1)
    XCTAssertEqual(result.coverage(of: window.frame(of: player), in: window.window), 1)
  }

  func testAWindowWithoutSizeIsMaskedInFull() {
    XCTAssertEqual(WindowMasks.compute(UIWindow(frame: .zero)), .wholeFrame(.noWindow))
  }
}
#endif
