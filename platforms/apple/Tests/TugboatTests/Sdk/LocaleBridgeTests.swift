import Foundation
import XCTest

@testable import Tugboat

/// `LocaleBridge`: `locale.set` on `NSLocale.currentLocaleDidChangeNotification`,
/// deduped, observed only between `start` and `stop`.
final class LocaleBridgeTests: XCTestCase {
  /// Records the observers removed, so the removal itself is seen.
  private final class RecordingCenter: NotificationCenter, @unchecked Sendable {
    private(set) var removed = 0

    override func removeObserver(_ observer: Any) {
      removed += 1
      super.removeObserver(observer)
    }
  }

  private let center = RecordingCenter()
  private let french = LocaleSnapshot(language: "fr", country: "FR", script: nil)
  private let english = LocaleSnapshot(language: "en", country: "US", script: nil)
  private var current = LocaleSnapshot(language: "en", country: "US", script: nil)
  private var posts: [String] = []

  private lazy var bridge = LocaleBridge(
    center: center, initial: english, read: { [unowned self] in self.current },
    post: { [unowned self] in self.posts.append($0) })

  private func localeChanged() {
    center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
  }

  func testNothingIsObservedBeforeStart() {
    current = french
    localeChanged()
    XCTAssertFalse(bridge.isObserving)
    XCTAssertEqual(posts, [])
  }

  func testAChangedLocaleIsPostedWithTheSessionStartShape() {
    bridge.start()
    XCTAssertTrue(bridge.isObserving)
    current = french
    localeChanged()
    XCTAssertEqual(posts, ["{\"locale\":{\"language\":\"fr\",\"country\":\"FR\",\"tag\":\"fr-FR\"}}"])
    XCTAssertEqual(
      jsonObject(posts.first ?? "")["locale"] as? NSDictionary,
      ["language": "fr", "country": "FR", "tag": "fr-FR"])
  }

  func testTheSameLocaleIsNotPostedAgain() {
    bridge.start()
    localeChanged()
    XCTAssertEqual(posts, [], "equal to the session's start locale")
    current = french
    localeChanged()
    localeChanged()
    XCTAssertEqual(posts.count, 1)
    current = english
    localeChanged()
    XCTAssertEqual(posts.count, 2)
  }

  func testStopRemovesTheObserver() {
    bridge.start()
    bridge.start()
    current = french
    localeChanged()
    XCTAssertEqual(posts.count, 1, "start is idempotent: one observer")
    bridge.stop()
    XCTAssertEqual(center.removed, 1, "the observer is removed at session end")
    XCTAssertFalse(bridge.isObserving)
    bridge.stop()
    XCTAssertEqual(center.removed, 1)
    current = english
    localeChanged()
    bridge.localeMayHaveChanged()
    XCTAssertEqual(posts.count, 1, "nothing after stop")
  }

  func testALocaleWithoutALanguageIsNotPosted() {
    bridge.start()
    current = LocaleSnapshot(language: "", country: "FR", script: nil)
    localeChanged()
    XCTAssertEqual(posts, [])
  }

  func testTheInputMatchesSessionStartLocale() {
    let metadata = HostMetadata(
      app: TugboatConfig.App(name: "n", version: "1", buildNumber: "1", appId: "a", installationId: "i"),
      device: DeviceSnapshot(
        id: "d", model: nil, osVersion: nil, screenWidth: 1, screenHeight: 1, scale: 1,
        locale: LocaleSnapshot(language: "pt", country: "BR", script: "Latn"), timezone: "UTC"))
    let start = jsonObject(SessionMessages.sessionStartInput(viewport: (1, 1), host: metadata, sessionEpoch: 0))
    let set = jsonObject(SessionMessages.localeSetInput(LocaleSnapshot(language: "pt", country: "BR", script: "Latn")))
    XCTAssertEqual(set["locale"] as? NSDictionary, start["locale"] as? NSDictionary)
    XCTAssertEqual(Array(set.keys), ["locale"])
  }
}
