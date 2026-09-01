import CoreGraphics
import UIKit

final class NativeBitmap {
  let width: Int
  let height: Int
  let stride: Int
  let pixels: UnsafeMutableRawPointer
  let incomplete: Bool
  private var context: CGContext?

  var cgContext: CGContext? { context }

  init(width: Int, height: Int, stride: Int, pixels: UnsafeMutableRawPointer, context: CGContext, incomplete: Bool) {
    self.width = width
    self.height = height
    self.stride = stride
    self.pixels = pixels
    self.context = context
    self.incomplete = incomplete
  }

  deinit {
    context = nil
    pixels.deallocate()
  }
}

enum ViewHierarchyCapture {
  static func capture(view: UIView, pixelWidth: Int, pixelHeight: Int) -> NativeBitmap? {
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
    UIGraphicsPushContext(context)
    let drawn = view.drawHierarchy(in: bounds, afterScreenUpdates: false)
    UIGraphicsPopContext()
    return NativeBitmap(
      width: pixelWidth,
      height: pixelHeight,
      stride: stride,
      pixels: pixels,
      context: context,
      incomplete: !drawn
    )
  }
}
