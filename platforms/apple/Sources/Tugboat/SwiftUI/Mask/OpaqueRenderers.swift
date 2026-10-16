#if canImport(UIKit)
import QuartzCore
import UIKit

/// Layers and views whose pixels do not come from layer `contents`: Metal,
/// OpenGL, video, and remote or portal views (content drawn by another
/// process or mirrored from elsewhere). A mask walk cannot classify them,
/// so they are masked over their whole bounds. Classes are found by name,
/// so AVFoundation and OpenGL ES are not linked.
enum OpaqueRenderers {
  private static let layerClasses: [AnyClass] = [
    CAMetalLayer.self,
    NSClassFromString("AVPlayerLayer"),
    NSClassFromString("AVSampleBufferDisplayLayer"),
    NSClassFromString("CAEAGLLayer"),
  ].compactMap { $0 }

  private static let nameFragments = ["Portal", "RemoteView", "LayerHost"]

  static func isRenderer(_ layer: CALayer) -> Bool {
    isRenderer(layerClass: type(of: layer)) || isRendererLayerName(NSStringFromClass(type(of: layer)))
  }

  static func isRenderer(layerClass: AnyClass) -> Bool {
    layerClasses.contains { layerClass.isSubclass(of: $0) }
  }

  static func isRendererViewName(_ name: String) -> Bool {
    nameFragments.contains { name.contains($0) }
  }

  private static func isRendererLayerName(_ name: String) -> Bool {
    nameFragments.contains { name.contains($0) }
  }
}
#endif
