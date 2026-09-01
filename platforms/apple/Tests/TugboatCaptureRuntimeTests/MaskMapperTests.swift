import XCTest
@testable import TugboatCaptureRuntime

final class MaskMapperTests: XCTestCase {
  func testDropsEmptyAndNonPositive() {
    let packed = MaskMapper.toPixelRects(
      masks: [
        NormalizedMask(x: 0.0, y: 0.0, width: 0.0, height: 1.0),
        NormalizedMask(x: 0.0, y: 0.0, width: 1.0, height: -0.1),
      ],
      width: 100,
      height: 100
    )
    XCTAssertEqual(packed, [])
  }

  func testPrivacyExpandsWithFloorCeil() {
    let packed = MaskMapper.toPixelRects(
      masks: [NormalizedMask(x: 0.25, y: 0.25, width: 0.5, height: 0.5)],
      width: 8,
      height: 8
    )
    XCTAssertEqual(packed, [2, 2, 6, 6])
  }

  func testClipsToBounds() {
    let packed = MaskMapper.toPixelRects(
      masks: [NormalizedMask(x: -0.1, y: -0.1, width: 2.0, height: 2.0)],
      width: 10,
      height: 10
    )
    XCTAssertEqual(packed, [0, 0, 10, 10])
  }

  func testIgnoresFullyOutsideAfterClip() {
    let packed = MaskMapper.toPixelRects(
      masks: [NormalizedMask(x: 2.0, y: 2.0, width: 0.1, height: 0.1)],
      width: 10,
      height: 10
    )
    XCTAssertEqual(packed, [])
  }

  func testMapsLandscapeAndPortraitTheSameNormalizedRect() {
    let mask = [NormalizedMask(x: 0.0, y: 0.0, width: 0.25, height: 0.25)]
    XCTAssertEqual(
      MaskMapper.toPixelRects(masks: mask, width: 160, height: 80),
      [0, 0, 40, 20]
    )
    XCTAssertEqual(
      MaskMapper.toPixelRects(masks: mask, width: 80, height: 160),
      [0, 0, 20, 40]
    )
  }

  func testOriginQuarterMaskCoversAtLeastOnePixelOnTypicalSizes() {
    let mask = [NormalizedMask(x: 0.0, y: 0.0, width: 0.25, height: 0.25)]
    for size in [40, 80, 120, 270, 293, 323] {
      let packed = MaskMapper.toPixelRects(masks: mask, width: size, height: size)
      XCTAssertEqual(packed.count, 4)
      XCTAssertEqual(packed[0], 0)
      XCTAssertEqual(packed[1], 0)
      let expectedRight = min(Int(ceil(0.25 * Double(size))), size)
      XCTAssertEqual(packed[2], Int32(expectedRight))
      XCTAssertEqual(packed[3], Int32(expectedRight))
      XCTAssertGreaterThan(packed[2], packed[0])
    }
  }
}
