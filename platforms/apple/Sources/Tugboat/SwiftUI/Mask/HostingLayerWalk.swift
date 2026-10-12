#if canImport(UIKit)
import UIKit

/// Masks what SwiftUI draws into CALayers inside a hosting view (native SDK
/// note section 6.3), reusing the probe's walk: public `CALayer`
/// properties only, and a stop at any layer that backs another `UIView`
/// (the view walk handles that view).
///
/// Each visible layer, the owner's own included:
/// - an allowlisted text layer is masked over its frame;
/// - an allowlisted image layer is masked over its frame padded by 4 pt;
/// - any other layer with `contents` is masked over its frame fail-closed
///   (unclassified);
/// - a layer without contents (a container, a colour fill) is not masked.
///
/// Sublayers are always walked. Hidden and transparent layers are skipped
/// with their sublayers.
struct HostingLayerWalk {
  private static let maxDepth = 64

  let allowlist: LayerAllowlist

  func walk(_ owner: UIView, into acc: inout MaskAccumulator) {
    walk(owner.layer, owner: owner, depth: 0, into: &acc)
  }

  private func walk(_ layer: CALayer, owner: UIView, depth: Int, into acc: inout MaskAccumulator) {
    guard depth <= HostingLayerWalk.maxDepth, acc.spend() else { return }
    if depth > 0, let view = layer.delegate as? UIView, view !== owner {
      return
    }
    guard !layer.isHidden, layer.opacity > 0.01 else { return }
    classify(layer, into: &acc)
    for sublayer in layer.sublayers ?? [] {
      walk(sublayer, owner: owner, depth: depth + 1, into: &acc)
    }
  }

  private func classify(_ layer: CALayer, into acc: inout MaskAccumulator) {
    let name = NSStringFromClass(type(of: layer))
    if allowlist.textClasses.contains(name) {
      acc.stats.textLayers += 1
      acc.add(layer: layer)
    } else if allowlist.imageClasses.contains(name) {
      acc.stats.imageLayers += 1
      acc.add(layer: layer, padding: LayerAllowlist.imagePadding)
    } else if layer.contents != nil {
      acc.stats.unclassifiedLayers += 1
      acc.stats.unclassifiedClasses[name, default: 0] += 1
      acc.add(layer: layer)
    }
  }
}
#endif
