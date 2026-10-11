import UIKit

/// Second question for native SDK note section 6.3: does SwiftUI draw text
/// and images into separate, classifiable CALayers inside its hosting views?
/// If it does, masks can be the union of those layer frames (fail-closed for
/// anything unclassified) instead of the whole frame.
///
/// Read-only: it walks public `CALayer` properties and records class names.
@MainActor
enum LayerProbe {
  private struct LayerInfo {
    let className: String
    let path: String
    let frame: CGRect
    let hasContents: Bool
  }

  private static let maxDepth = 40
  private static let maxLayers = 4000

  static func run(window: UIWindow, label: String) -> (lines: [String], summary: String) {
    var lines: [String] = []
    var layers: [LayerInfo] = []

    let hosts = hostingViews(in: window)
    for (index, host) in hosts.enumerated() {
      let frame = host.convert(host.bounds, to: window)
      lines.append("A11YPROBE \(label) L host[\(index)] \(typeName(host)) frame=\(rect(frame))")
      walk(
        host.layer, owner: host, window: window, depth: 0, path: "h\(index)",
        label: label, lines: &lines, layers: &layers)
    }

    lines.append(contentsOf: histogramLines(label: label, layers: layers))
    let matches = groundTruthMatches(layers: layers)
    for match in matches {
      lines.append("A11YPROBE \(label) MATCH \(match.line)")
    }

    let text = matches.filter { $0.name.hasPrefix("text.") }
    let images = matches.filter { $0.name.hasPrefix("image.") }
    let textSeparable = !text.isEmpty && text.allSatisfy { $0.iou >= 0.5 }
    let imageSeparable = !images.isEmpty && images.allSatisfy { $0.iou >= 0.5 }
    let textClasses = Set(text.compactMap { $0.className }).sorted()
    let imageClasses = Set(images.compactMap { $0.className }).sorted()
    lines.append(
      "A11YPROBE \(label) LAYER-VERDICT textSeparable=\(textSeparable) imageSeparable=\(imageSeparable) "
        + "textClasses=\(textClasses) imageClasses=\(imageClasses) "
        + "truthsMissing=\(missingTruths().joined(separator: ","))"
    )
    let summary =
      "layers=\(layers.count) textSeparable=\(textSeparable) imageSeparable=\(imageSeparable)"
    return (lines, summary)
  }

  // MARK: Walk

  private static func hostingViews(in root: UIView) -> [UIView] {
    var found: [UIView] = []
    func visit(_ view: UIView) {
      if typeName(view).contains("HostingView") { found.append(view) }
      view.subviews.forEach(visit)
    }
    visit(root)
    return found
  }

  private static func walk(
    _ layer: CALayer,
    owner: UIView,
    window: UIWindow,
    depth: Int,
    path: String,
    label: String,
    lines: inout [String],
    layers: inout [LayerInfo]
  ) {
    guard depth <= maxDepth, layers.count < maxLayers else { return }
    let indent = String(repeating: " ", count: depth)
    // Layers that back another UIView belong to the view walk (or to another
    // hosting view's own pass); stop there.
    if depth > 0, let view = layer.delegate as? UIView, view !== owner {
      lines.append("A11YPROBE \(label) L \(indent)[view \(typeName(view))]")
      return
    }
    let frame = layer.convert(layer.bounds, to: window.layer)
    let className = NSStringFromClass(type(of: layer))
    let contentsType = layer.contents.map { String(describing: type(of: $0)) }
    let info = LayerInfo(
      className: className, path: path, frame: frame, hasContents: layer.contents != nil)
    if depth > 0 { layers.append(info) }
    lines.append(
      "A11YPROBE \(label) L \(indent)\(className) frame=\(rect(frame)) "
        + "contents=\(contentsType ?? "nil") sublayers=\(layer.sublayers?.count ?? 0) "
        + "opacity=\(layer.opacity) hidden=\(layer.isHidden) name=\(layer.name ?? "nil") "
        + "text=\(layer is CATextLayer) shape=\(layer is CAShapeLayer)"
    )
    for (index, sublayer) in (layer.sublayers ?? []).enumerated() {
      walk(
        sublayer, owner: owner, window: window, depth: depth + 1, path: "\(path)/\(index)",
        label: label, lines: &lines, layers: &layers)
    }
  }

  // MARK: Analysis

  private static func histogramLines(label: String, layers: [LayerInfo]) -> [String] {
    var counts: [String: (all: Int, withContents: Int)] = [:]
    for layer in layers {
      let current = counts[layer.className] ?? (0, 0)
      counts[layer.className] = (current.all + 1, current.withContents + (layer.hasContents ? 1 : 0))
    }
    return counts.sorted { $0.key < $1.key }.map {
      "A11YPROBE \(label) L-CLASS \($0.key) count=\($0.value.all) withContents=\($0.value.withContents)"
    }
  }

  private struct Match {
    let name: String
    let className: String?
    let iou: Double
    let line: String
  }

  /// For each ground-truth element, the layer with the best overlap (IoU).
  /// A layer far larger than the element (a container) scores low.
  private static func groundTruthMatches(layers: [LayerInfo]) -> [Match] {
    let truths = ProbeFrames.frames
      .filter { !$0.key.hasPrefix("text.row") || ["text.row0", "text.row1", "text.row2"].contains($0.key) }
      .sorted { $0.key < $1.key }
    return truths.map { name, truth in
      let best = layers
        .map { (layer: $0, iou: iou($0.frame, truth)) }
        .max { $0.iou < $1.iou }
      guard let best = best, best.iou > 0 else {
        return Match(name: name, className: nil, iou: 0, line: "\(name) truth=\(rect(truth)) -> none")
      }
      let line =
        "\(name) truth=\(rect(truth)) -> \(best.layer.className) \(best.layer.path) "
        + "frame=\(rect(best.layer.frame)) contents=\(best.layer.hasContents) "
        + "iou=\(String(format: "%.2f", best.iou))"
      return Match(name: name, className: best.layer.className, iou: best.iou, line: line)
    }
  }

  private static func missingTruths() -> [String] {
    ["text.heading", "text.button", "image.star", "field", "text.row0"]
      .filter { ProbeFrames.frames[$0] == nil }
  }

  private static func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let intersection = a.intersection(b)
    guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
    let inter = Double(intersection.width * intersection.height)
    let union = Double(a.width * a.height + b.width * b.height) - inter
    return union > 0 ? inter / union : 0
  }

  // MARK: Formatting

  private static func typeName(_ object: AnyObject) -> String {
    String(describing: type(of: object))
  }

  private static func rect(_ frame: CGRect) -> String {
    "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))"
  }
}
