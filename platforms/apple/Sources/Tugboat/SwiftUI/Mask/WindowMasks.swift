#if canImport(UIKit)
import UIKit

/// Mask geometry for a window under `allTextAndMedia` (native SDK note 2.1,
/// SwiftUI row, and 6.3). Runs on the main thread when the host handles
/// `capture.request`, just before the pixel capture. One walk over the
/// views (`ViewTree`), each view's own layers walked by `LayerWalk`.
///
/// The mask is the union of:
/// - text: `UILabel`, `UITextField`, `UITextView` (secure fields included);
/// - media: `UIImageView`;
/// - boxes, never looked inside: `WKWebView`, opaque renderers, app
///   representables and app-defined views inside hosting views, and any
///   SwiftUI platform view not verified for this iOS major;
/// - inside hosting views, the SwiftUI layers `LayerWalk` classifies.
///
/// The whole frame is masked (`MaskResult.fallback`) when the window has no
/// size, when it contains a hosting view and the iOS major has no verified
/// allowlist, when anything is animating, or when the walk runs over its
/// budget. Hidden and transparent views are skipped with their subtrees; a
/// zero-size view only when it clips its subviews. Rectangles are clipped
/// to the window only, so a partly clipped view is over-masked, never
/// under-masked.
enum WindowMasks {
  static func compute(
    _ window: UIWindow,
    allowlist: LayerAllowlist? = LayerAllowlist.forMajor(LayerAllowlist.runningMajor),
    iOSMajor: Int = LayerAllowlist.runningMajor
  ) -> MaskResult {
    guard window.bounds.width > 0, window.bounds.height > 0 else {
      return .wholeFrame(.noWindow)
    }
    var acc = MaskAccumulator(window: window)
    visit(ViewTree.node(window), allowlist: allowlist, iOSMajor: iOSMajor, into: &acc)
    return acc.result()
  }

  private static func visit(_ node: ViewNode, allowlist: LayerAllowlist?, iOSMajor: Int, into acc: inout MaskAccumulator) {
    guard acc.spend() else { return }
    let view = node.view
    if node.kind == .sdkOwned || (view !== acc.window && ViewTree.isInvisibleForMasks(view)) {
      return
    }
    if let keys = view.layer.animationKeys(), !keys.isEmpty {
      acc.fail(.animating)
      return
    }
    guard maskOrWalk(node, allowlist: allowlist, iOSMajor: iOSMajor, into: &acc) else { return }
    for child in ViewTree.children(of: node) {
      visit(child, allowlist: allowlist, iOSMajor: iOSMajor, into: &acc)
    }
  }

  /// Masks `node` as a box, or walks its own layers; true when its subviews
  /// still need visiting.
  private static func maskOrWalk(_ node: ViewNode, allowlist: LayerAllowlist?, iOSMajor: Int, into acc: inout MaskAccumulator) -> Bool {
    let view = node.view
    switch node.kind {
    case .webView, .representable, .renderer:
      return box(view, node.kind, into: &acc)
    case .textInput, .label:
      acc.stats.uiKitText += 1
      acc.add(view: view)
      return false
    case .image:
      acc.stats.uiKitImages += 1
      acc.add(view: view)
      return false
    case .hosting:
      guard let allowlist = allowlist else {
        acc.fail(.unverifiedLayerAllowlist(iOSMajor: iOSMajor))
        return false
      }
      acc.stats.hostingViews += 1
      LayerWalk(classify: allowlist).walk(view, into: &acc)
      return true
    case .internalPlatformView:
      guard let allowlist = allowlist, allowlist.walksPlatformView(String(reflecting: type(of: view))) else {
        return box(view, .representable, into: &acc)
      }
      LayerWalk(classify: allowlist).walk(view, into: &acc)
      return true
    case .cell, .scrollView, .other, .sdkOwned:
      LayerWalk(classify: node.insideHosting ? allowlist : nil).walk(view, into: &acc)
      return true
    }
  }

  private static func box(_ view: UIView, _ kind: ViewKind, into acc: inout MaskAccumulator) -> Bool {
    acc.stats.failClosedViews += 1
    switch kind {
    case .webView: acc.stats.webViewBoxes += 1
    case .renderer: acc.stats.rendererBoxes += 1
    default:
      acc.stats.representableBoxes += 1
      // A representable that wraps a web view is reported as one too.
      if view.subviews.contains(where: { ViewKind.of($0, insideHosting: true) == .webView }) {
        acc.stats.webViewBoxes += 1
      }
    }
    acc.addBox(view: view)
    return false
  }
}
#endif
