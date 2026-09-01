import Foundation

enum MaskMapper {
  static func toPixelRects(masks: [NormalizedMask], width: Int, height: Int) -> [Int32] {
    if width <= 0 || height <= 0 {
      return []
    }
    var packed: [Int32] = []
    packed.reserveCapacity(masks.count * 4)
    for mask in masks {
      if mask.width <= 0.0 || mask.height <= 0.0 {
        continue
      }
      let left = clamp(Int(floor(mask.x * Double(width))), 0, width)
      let top = clamp(Int(floor(mask.y * Double(height))), 0, height)
      let right = clamp(Int(ceil((mask.x + mask.width) * Double(width))), 0, width)
      let bottom = clamp(Int(ceil((mask.y + mask.height) * Double(height))), 0, height)
      if right <= left || bottom <= top {
        continue
      }
      packed.append(Int32(left))
      packed.append(Int32(top))
      packed.append(Int32(right))
      packed.append(Int32(bottom))
    }
    return packed
  }

  private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
    min(max(value, lower), upper)
  }
}
