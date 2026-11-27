/// The visible structure of a masked window as an opaque token
/// (stateful-engine.md 8.2, "dHash baseline"): a 64-bit FNV-1a hash over
///
/// - the window size in points and the whole-frame flag;
/// - every quantized mask rectangle, which follow each text, image and shape
///   layer the mask walk found;
/// - the state of each visible control (`StructureProbe`: `UIControl`
///   selected / highlighted / enabled, `UISwitch` on, the accessibility
///   `selected` trait), in walk order;
/// - the current `.tugboatScreen` name.
///
/// A moved element, an added row, a toggled switch, a newly selected tab, or
/// another screen changes it, so the engine does not coalesce such a frame
/// into an earlier one that looks alike at dHash resolution. Visible text
/// never enters it.
struct StructureSignature {
  /// Coordinates are quantized so float noise does not change the token.
  private static let quantum = 10_000.0
  private static let prime: UInt64 = 0x0000_0100_0000_01b3

  private var hash: UInt64 = 0xcbf2_9ce4_8422_2325

  static func of(
    _ result: MaskResult,
    width: Double,
    height: Double,
    controls: [Int64] = [],
    screen: String? = nil
  ) -> String {
    var signature = StructureSignature()
    signature.mix(width)
    signature.mix(height)
    signature.mix(Int64(result.fallback == nil ? 0 : 1))
    for rect in result.rects {
      signature.mix(rect.x)
      signature.mix(rect.y)
      signature.mix(rect.width)
      signature.mix(rect.height)
    }
    signature.mix(Int64(controls.count))
    controls.forEach { signature.mix($0) }
    for byte in (screen ?? "").utf8 {
      signature.mix(Int64(byte))
    }
    return String(signature.hash, radix: 16)
  }

  private mutating func mix(_ value: Int64) {
    var bits = UInt64(bitPattern: value)
    for _ in 0..<8 {
      hash = (hash ^ (bits & 0xff)) &* StructureSignature.prime
      bits >>= 8
    }
  }

  private mutating func mix(_ value: Double) {
    let scaled = (value * StructureSignature.quantum).rounded()
    mix(scaled.isFinite && abs(scaled) < 9e18 ? Int64(scaled) : 0)
  }
}
