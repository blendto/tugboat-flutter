#if canImport(UIKit)
import UIKit

/// Walks the layers one view owns (its own layer and every sublayer that
/// does not back another `UIView`; the view walk handles those), reusing the
/// probe's approach: public `CALayer` properties only.
///
/// For every visible layer, in every view:
/// - an animation (`animationKeys()`) masks the whole frame (`animating`);
/// - an opaque renderer (Metal, video, portal) is masked over its frame and
///   not descended.
///
/// With `classify` (layers inside hosting views), each visible layer is also:
/// - masked over its frame when its class is an allowlisted text or shape
///   class, or padded by 4 pt for an image class;
/// - masked fail-closed (unclassified) when it has `contents` or is a
///   `CAShapeLayer` with a path;
/// - left visible otherwise (a container, a colour fill).
///
/// Hidden and transparent layers are skipped with their sublayers. Deeper
/// than `maxDepth` masks the whole frame (`walkLimitExceeded`).
struct LayerWalk {
  static let maxDepth = 64

  /// The allowlist to classify layers with, or nil outside hosting views.
  let classify: LayerAllowlist?

  func walk(_ owner: UIView, into acc: inout MaskAccumulator) {
    walk(owner.layer, owner: owner, depth: 0, into: &acc)
  }

  private func walk(_ layer: CALayer, owner: UIView, depth: Int, into acc: inout MaskAccumulator) {
    guard depth <= LayerWalk.maxDepth else {
      acc.fail(.walkLimitExceeded)
      return
    }
    guard acc.spend() else { return }
    if depth > 0, let view = layer.delegate as? UIView, view !== owner {
      return
    }
    guard !layer.isHidden, layer.opacity > 0.01 else { return }
    if let keys = layer.animationKeys(), !keys.isEmpty {
      acc.fail(.animating)
      return
    }
    if OpaqueRenderers.isRenderer(layer) {
      acc.stats.rendererLayers += 1
      acc.add(layer: layer)
      return
    }
    if let allowlist = classify {
      LayerWalk.classify(layer, allowlist, into: &acc)
    }
    for sublayer in layer.sublayers ?? [] {
      walk(sublayer, owner: owner, depth: depth + 1, into: &acc)
    }
  }

  private static func classify(_ layer: CALayer, _ allowlist: LayerAllowlist, into acc: inout MaskAccumulator) {
    let name = NSStringFromClass(type(of: layer))
    if allowlist.textClasses.contains(name) {
      acc.stats.textLayers += 1
      acc.add(layer: layer)
    } else if allowlist.imageClasses.contains(name) {
      acc.stats.imageLayers += 1
      acc.add(layer: layer, padding: LayerAllowlist.imagePadding)
    } else if allowlist.shapeClasses.contains(name) {
      acc.stats.shapeLayers += 1
      acc.add(layer: layer)
    } else if layer.contents != nil || hasPath(layer) {
      acc.stats.unclassifiedLayers += 1
      acc.stats.unclassifiedClasses[name, default: 0] += 1
      acc.add(layer: layer)
    }
  }

  private static func hasPath(_ layer: CALayer) -> Bool {
    guard let shape = layer as? CAShapeLayer, let path = shape.path else { return false }
    return !path.boundingBoxOfPath.isEmpty
  }
}
#endif
