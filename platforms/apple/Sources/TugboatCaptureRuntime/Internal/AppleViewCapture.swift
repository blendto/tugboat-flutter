import CoreGraphics
import UIKit

final class NativeBitmap {
  let width: Int
  let height: Int
  let stride: Int
  let pixels: UnsafeMutableRawPointer
  let coverage: CaptureCoverage
  let incomplete: Bool
  /// The supplied masks for exactly this draw; nil without a supplier.
  let maskSnapshot: MaskSnapshot?
  let maskComputeMicros: Int64
  private var context: CGContext?

  init(
    width: Int,
    height: Int,
    stride: Int,
    pixels: UnsafeMutableRawPointer,
    context: CGContext,
    coverage: CaptureCoverage,
    incomplete: Bool,
    maskSnapshot: MaskSnapshot? = nil,
    maskComputeMicros: Int64 = 0
  ) {
    self.width = width
    self.height = height
    self.stride = stride
    self.pixels = pixels
    self.coverage = coverage
    self.context = context
    self.incomplete = incomplete
    self.maskSnapshot = maskSnapshot
    self.maskComputeMicros = maskComputeMicros
  }

  /// Sample both coverage modes for visible, non-near-white content before
  /// publishing. This rejects untouched buffers and blank Flutter Metal frames
  /// with constant work at large capture sizes.
  var hasCapturedContent: Bool {
    let bytes = pixels.assumingMemoryBound(to: UInt8.self)
    let totalPixels = width * height
    let sampleLimit = 4_096
    let step = max(1, (totalPixels + sampleLimit - 1) / sampleLimit)
    var linearIndex = 0
    while linearIndex < totalPixels {
      let y = linearIndex / width
      let x = linearIndex % width
      let pixel = bytes.advanced(by: y * stride + x * 4)
      let isVisible = pixel[3] != 0
      let isNearWhite = pixel[0] >= 250 && pixel[1] >= 250 && pixel[2] >= 250
      if isVisible && !isNearWhite {
        return true
      }
      linearIndex += step
    }
    return false
  }

  func jpegData() -> Data? {
    guard let context else { return nil }
    return JpegEncoder.encode(from: context)
  }

  deinit {
    context = nil
    pixels.deallocate()
  }
}

/// Main thread only.
enum AppleViewCapture {
  /// Supplies the masks for one draw. Called on the main thread immediately
  /// before each draw attempt, so the masks describe the drawn layout.
  typealias MasksBeforeDraw = () -> MaskSnapshot

  static func capture(
    view: UIView,
    sizing: PixelSizing,
    coverage: CaptureCoverage,
    masksBeforeDraw: MasksBeforeDraw? = nil
  ) -> NativeBitmap? {
    switch coverage {
    case .engineSurface:
      guard let bitmap = captureOnce(
        view: view,
        sizing: sizing,
        coverage: .engineSurface,
        afterScreenUpdates: false,
        masksBeforeDraw: masksBeforeDraw
      ), bitmap.hasCapturedContent else { return nil }
      return bitmap
    case .viewHierarchy:
      return captureHierarchy(
        view: view,
        sizing: sizing,
        masksBeforeDraw: masksBeforeDraw
      )
    }
  }

  /// A complete draw wins; an incomplete one is kept as the fallback. Each
  /// draw carries the snapshot taken for it, so the fallback keeps its own.
  private static func captureHierarchy(
    view: UIView,
    sizing: PixelSizing,
    masksBeforeDraw: MasksBeforeDraw?
  ) -> NativeBitmap? {
    var incompleteCapture: NativeBitmap?
    for afterScreenUpdates in [false, true] {
      guard
        let bitmap = captureOnce(
          view: view,
          sizing: sizing,
          coverage: .viewHierarchy,
          afterScreenUpdates: afterScreenUpdates,
          masksBeforeDraw: masksBeforeDraw
        ),
        bitmap.hasCapturedContent
      else {
        continue
      }
      if !bitmap.incomplete {
        return bitmap
      }
      incompleteCapture = bitmap
    }
    return incompleteCapture
  }

  private static func captureOnce(
    view: UIView,
    sizing: PixelSizing,
    coverage: CaptureCoverage,
    afterScreenUpdates: Bool,
    masksBeforeDraw: MasksBeforeDraw?
  ) -> NativeBitmap? {
    if masksBeforeDraw != nil {
      // Settle layout before the one bounds reading this draw, its size,
      // and its masks all use.
      view.layoutIfNeeded()
    }
    let bounds = view.bounds
    if bounds.width <= 0 || bounds.height <= 0 {
      return nil
    }
    guard let (pixelWidth, pixelHeight) = sizing.size(for: bounds.size) else {
      return nil
    }
    let stride = ((pixelWidth * 4 + 15) / 16) * 16
    let byteCount = stride * pixelHeight
    let pixels = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
    pixels.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
      CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    guard
      let context = CGContext(
        data: pixels,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: stride,
        space: colorSpace,
        bitmapInfo: bitmapInfo
      )
    else {
      pixels.deallocate()
      return nil
    }

    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(
      x: CGFloat(pixelWidth) / bounds.width,
      y: -CGFloat(pixelHeight) / bounds.height
    )
    // Same main-thread turn as the draw below: nothing can change the
    // layout in between.
    let maskStart = DispatchTime.now()
    let maskSnapshot = masksBeforeDraw?()
    let maskMicros = maskSnapshot == nil
      ? 0 : Int64((DispatchTime.now().uptimeNanoseconds - maskStart.uptimeNanoseconds) / 1_000)
    let incomplete = render(
      view: view,
      bounds: bounds,
      context: context,
      coverage: coverage,
      afterScreenUpdates: afterScreenUpdates
    )
    return NativeBitmap(
      width: pixelWidth,
      height: pixelHeight,
      stride: stride,
      pixels: pixels,
      context: context,
      coverage: coverage,
      incomplete: incomplete,
      maskSnapshot: maskSnapshot,
      maskComputeMicros: maskMicros
    )
  }

  private static func render(
    view: UIView,
    bounds: CGRect,
    context: CGContext,
    coverage: CaptureCoverage,
    afterScreenUpdates: Bool
  ) -> Bool {
    switch coverage {
    case .engineSurface:
      // FlutterView implements CALayerDelegate. Rendering the live layer is
      // the fast CPU path. Core Graphics does not copy CAMetalLayer contents
      // by itself. Blank output returns pixelCopyFailed so the caller can
      // choose an explicit compatibility path.
      view.layer.render(in: context)
      return false
    case .viewHierarchy:
      UIGraphicsPushContext(context)
      let drawn = view.drawHierarchy(in: bounds, afterScreenUpdates: afterScreenUpdates)
      UIGraphicsPopContext()
      return !drawn
    }
  }
}
