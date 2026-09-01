import CoreGraphics
import Foundation
import ImageIO

enum JpegEncoder {
  static let quality = Double(CaptureRuntime.jpegQuality) / 100.0

  static func encode(from context: CGContext) -> Data? {
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
    else {
      return nil
    }
    let options: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: quality
    ]
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }
}
