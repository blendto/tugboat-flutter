import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum JpegEncoder {
  static let quality = Double(CaptureRuntime.jpegQuality) / 100.0

  static func encode(from context: CGContext) -> Data? {
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    let type = UTType.jpeg.identifier as CFString
    guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
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
