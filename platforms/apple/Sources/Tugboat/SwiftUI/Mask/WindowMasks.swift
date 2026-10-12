#if canImport(UIKit)
import UIKit

/// Mask geometry for a window under `allTextAndMedia` (native SDK note 2.1,
/// SwiftUI row, and 6.3). Runs on the main thread when the host handles
/// `capture.request`, just before the pixel capture.
///
/// The mask is the union of:
/// - text: `UILabel`, `UITextField`, `UITextView` (secure fields included);
/// - media: `UIImageView`;
/// - fail-closed bounds, not looked inside: `WKWebView`, representable
///   hosts (`UIViewRepresentable`, and any app-defined view inside a
///   hosting view);
/// - inside hosting views, the SwiftUI layers `HostingLayerWalk` masks.
///
/// Fail closed: a window without size, a walk over budget, or an iOS major
/// version without a verified layer allowlist while the window contains a
/// hosting view masks the whole frame. Hidden, transparent and zero-size
/// views are skipped with their subtrees. Rectangles are clipped to the
/// window only, so a partly clipped view is over-masked, never
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
    guard let allowlist = allowlist else {
      return containsHostingView(window) ? .wholeFrame(.unverifiedLayerAllowlist(iOSMajor: iOSMajor)) : uiKitOnly(window)
    }
    visit(window, insideHosting: false, layers: HostingLayerWalk(allowlist: allowlist), into: &acc)
    return acc.result()
  }

  /// A window without SwiftUI needs no layer allowlist.
  private static func uiKitOnly(_ window: UIWindow) -> MaskResult {
    var acc = MaskAccumulator(window: window)
    let noLayers = HostingLayerWalk(allowlist: LayerAllowlist(textClasses: [], imageClasses: []))
    visit(window, insideHosting: false, layers: noLayers, into: &acc)
    return acc.result()
  }

  private static func visit(_ view: UIView, insideHosting: Bool, layers: HostingLayerWalk, into acc: inout MaskAccumulator) {
    guard acc.spend() else { return }
    if view !== acc.window, ViewKind.isExcluded(view) {
      return
    }
    let kind = ViewKind.of(view, insideHosting: insideHosting)
    switch kind {
    case .webView, .representable:
      acc.stats.failClosedViews += 1
      acc.add(view: view)
      return
    case .textInput, .label:
      acc.stats.uiKitText += 1
      acc.add(view: view)
      return
    case .image:
      acc.stats.uiKitImages += 1
      acc.add(view: view)
      return
    case .hosting:
      acc.stats.hostingViews += 1
      layers.walk(view, into: &acc)
    case .cell, .scrollView, .other:
      if insideHosting {
        layers.walk(view, into: &acc)
      }
    }
    let childrenInsideHosting = insideHosting || kind == .hosting
    for child in view.subviews {
      visit(child, insideHosting: childrenInsideHosting, layers: layers, into: &acc)
    }
  }

  private static func containsHostingView(_ root: UIView) -> Bool {
    var stack: [UIView] = [root]
    var visited = 0
    while let view = stack.popLast(), visited < MaskAccumulator.defaultBudget {
      visited += 1
      if ViewKind.of(view, insideHosting: false) == .hosting {
        return true
      }
      stack.append(contentsOf: view.subviews)
    }
    // Not enumerable within the budget: assume SwiftUI is there.
    return !stack.isEmpty
  }
}
#endif
