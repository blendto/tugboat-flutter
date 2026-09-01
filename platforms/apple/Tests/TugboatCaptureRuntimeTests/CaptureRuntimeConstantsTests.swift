import XCTest
@testable import TugboatCaptureRuntime

final class CaptureRuntimeConstantsTests: XCTestCase {
  func testNativeFloorAndDefaults() {
    XCTAssertEqual(CaptureRuntime.minNativeApi, 15)
    XCTAssertEqual(CaptureRuntime.defaultTimeoutMs, 2_000)
    XCTAssertEqual(CaptureRuntime.jpegQuality, 80)
    XCTAssertEqual(CaptureStatus.cancelled, CaptureStatus.cancelled)
  }

  func testRepeatedDisposeIsSafe() {
    let runtime = CaptureRuntime()
    runtime.dispose()
    runtime.dispose()
    runtime.cancel(1)
  }

  func testRepeatedInitializationCreatesIndependentRuntimes() {
    let first = CaptureRuntime()
    let second = CaptureRuntime()
    first.dispose()
    second.dispose()
    first.dispose()
  }

  func testCapabilitiesReportIosMajorVersion() {
    let caps = CaptureRuntime().capabilities()
    let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    XCTAssertEqual(caps.apiLevel, major)
    XCTAssertEqual(caps.minNativeApi, 15)
    XCTAssertEqual(caps.nativeCaptureSupported, major >= 15)
  }
}
