import Foundation
import XCTest

@testable import Tugboat

/// The installation id rules of Flutter's `TugboatInstallationIdStore`
/// (BLE-618): mint once, persist in `tugboat/installation_id`, seed on
/// first launch, replace a corrupt file, never throw, host id wins.
final class InstallationIdTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("tb-installation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
  }

  private var idFile: URL { root.appendingPathComponent("tugboat/installation_id") }

  private func store(mint: @escaping () -> String = { UUID().uuidString.lowercased() }) -> InstallationIdStore {
    InstallationIdStore(directory: { self.root }, mint: mint)
  }

  func testFirstLaunchMintsAUuidV4AndPersistsIt() throws {
    let id = store().read()
    XCTAssertNotNil(
      id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression), id)
    XCTAssertEqual(try String(contentsOf: idFile, encoding: .utf8), id)
  }

  func testLaterLaunchReadsItBackAndOneIdPerProcess() {
    let first = store()
    let id = first.read()
    XCTAssertEqual(first.read(), id)
    XCTAssertEqual(store(mint: { "other" }).read(), id)
  }

  func testTheSeedIsUsedOnFirstLaunchOnly() {
    XCTAssertEqual(store().read(seed: "VENDOR-ID"), "VENDOR-ID")
    XCTAssertEqual(store().read(seed: "another"), "VENDOR-ID", "a persisted id beats a seed")
  }

  func testAnotherInstallGetsAnotherId() throws {
    let first = store().read()
    try FileManager.default.removeItem(at: root.appendingPathComponent("tugboat"))
    XCTAssertNotEqual(store().read(), first)
  }

  func testCorruptFilesAreReplaced() throws {
    for bad in ["", "   \n", String(repeating: "x", count: 129)] {
      try FileManager.default.createDirectory(at: idFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bad.write(to: idFile, atomically: true, encoding: .utf8)
      XCTAssertEqual(store(mint: { "fresh-id" }).read(), "fresh-id")
      XCTAssertEqual(try String(contentsOf: idFile, encoding: .utf8), "fresh-id")
    }
  }

  func testWhitespaceIsTrimmedOnRead() throws {
    try FileManager.default.createDirectory(at: idFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "  abc-123\n".write(to: idFile, atomically: true, encoding: .utf8)
    XCTAssertEqual(store().read(), "abc-123")
  }

  func testWriteFailureStillReturnsAStableIdAndRetriesLater() throws {
    // A non-empty directory where the file should be makes the write fail.
    try FileManager.default.createDirectory(at: idFile, withIntermediateDirectories: true)
    try "x".write(to: idFile.appendingPathComponent("child"), atomically: true, encoding: .utf8)
    let failing = store(mint: { "stable-id" })
    XCTAssertEqual(failing.read(), "stable-id")
    XCTAssertEqual(failing.read(), "stable-id")
    try FileManager.default.removeItem(at: idFile)
    XCTAssertEqual(failing.read(), "stable-id")
    XCTAssertEqual(try String(contentsOf: idFile, encoding: .utf8), "stable-id")
  }

  func testUnavailableDirectoryStillReturnsAnId() {
    let memory = InstallationIdStore(directory: { nil }, mint: { "mem-id" })
    XCTAssertEqual(memory.read(), "mem-id")
    XCTAssertEqual(memory.read(), "mem-id")
  }

  func testHostIdWinsWhenNonBlank() {
    XCTAssertEqual(InstallationIdStore.resolve(host: "  host-1 ") { XCTFail("not read"); return "" }, "host-1")
    XCTAssertEqual(InstallationIdStore.resolve(host: "  ") { "sdk" }, "sdk")
    XCTAssertEqual(InstallationIdStore.resolve(host: nil) { "sdk" }, "sdk")
  }

  func testAppResolvesItsInstallationId() {
    let blank = TugboatConfig.App(name: "n", version: "1", buildNumber: "1", appId: "a")
    XCTAssertEqual(blank.resolvingInstallationId(vendorId: "V", store: store()).installationId, "V")
    var hosted = blank
    hosted.installationId = "host"
    XCTAssertEqual(hosted.resolvingInstallationId(vendorId: "V", store: store()).installationId, "host")
  }

  func testIdSeedIs64LowercaseHexAndDiffersEachTime() {
    let seed = IdSeed.generate()
    XCTAssertNotNil(seed.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
    XCTAssertNotEqual(seed, IdSeed.generate())
  }
}
