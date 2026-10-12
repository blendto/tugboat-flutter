/// The visible structure of a masked window as an opaque token
/// (stateful-engine.md 8.2, "dHash baseline"): a 64-bit FNV-1a hash over
/// the window size, the mask mode, and every mask rectangle, which follow
/// each text, image and shape layer the mask walk found. A moved or
/// resized element, an added row, or a toggled control drawn as a shape
/// changes it, so the engine does not coalesce such a frame into an
/// earlier one that looks alike at dHash resolution. Visible text never
/// enters it.
enum StructureSignature {
  /// Coordinates are quantized so float noise does not change the token.
  private static let quantum = 10_000.0
  private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
  private static let prime: UInt64 = 0x0000_0100_0000_01b3

  static func of(_ result: MaskResult, width: Double, height: Double) -> String {
    var hash = offsetBasis
    func mix(_ value: Int64) {
      var bits = UInt64(bitPattern: value)
      for _ in 0..<8 {
        hash = (hash ^ (bits & 0xff)) &* prime
        bits >>= 8
      }
    }
    func mix(_ value: Double) {
      let scaled = (value * quantum).rounded()
      mix(scaled.isFinite && abs(scaled) < 9e18 ? Int64(scaled) : 0)
    }
    mix(width)
    mix(height)
    mix(Int64(result.fallback == nil ? 0 : 1))
    for rect in result.rects {
      mix(rect.x)
      mix(rect.y)
      mix(rect.width)
      mix(rect.height)
    }
    return String(hash, radix: 16)
  }
}
