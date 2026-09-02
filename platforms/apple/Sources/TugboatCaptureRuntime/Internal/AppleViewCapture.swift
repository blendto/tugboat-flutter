import CoreGraphics
import UIKit

final class NativeBitmap {
  let width: Int
  let height: Int
  let stride: Int
  let pixels: UnsafeMutableRawPointer
  let coverage: CaptureCoverage
  let incomplete: Bool
  private var context: CGContext?

  init(
    width: Int,
    height: Int,
    stride: Int,
    pixels: UnsafeMutableRawPointer,
    context: CGContext,
    coverage: CaptureCoverage,
    incomplete: Bool
  ) {
    self.width = width
    self.height = height
    self.stride = stride
    self.pixels = pixels
    self.coverage = coverage
    self.context = context
    self.incomplete = incomplete
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

enum AppleViewCapture {
  static func capture(
    view: UIView,
    pixelWidth: Int,
    pixelHeight: Int,
    coverage: CaptureCoverage
  ) -> NativeBitmap? {
    switch coverage {
    case .engineSurface:
      guard let bitmap = captureOnce(
        view: view,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        coverage: .engineSurface,
        afterScreenUpdates: false
      ), bitmap.hasCapturedContent else { return nil }
      return bitmap
    case .viewHierarchy:
      return captureHierarchy(
        view: view,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight
      )
    }
  }

  private static func captureHierarchy(
    view: UIView,
    pixelWidth: Int,
    pixelHeight: Int
  ) -> NativeBitmap? {
    var incompleteCapture: NativeBitmap?
    for afterScreenUpdates in [false, true] {
      guard
        let bitmap = captureOnce(
          view: view,
          pixelWidth: pixelWidth,
          pixelHeight: pixelHeight,
          coverage: .viewHierarchy,
          afterScreenUpdates: afterScreenUpdates
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
    pixelWidth: Int,
    pixelHeight: Int,
    coverage: CaptureCoverage,
    afterScreenUpdates: Bool
  ) -> NativeBitmap? {
    let bounds = view.bounds
    if bounds.width <= 0 || bounds.height <= 0 {
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
      incomplete: incomplete
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
