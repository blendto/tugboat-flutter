import Foundation
import XCTest

@testable import Tugboat

/// `HostMetadata`, `EngineConfiguration`, and `SessionMessages`: the inputs
/// the SDK builds for the engine.
final class SdkMessagesTests: XCTestCase {
  private let app = TugboatConfig.App(name: "Sample", version: "1.2", buildNumber: "7", appId: "com.example", installationId: "i-1")
  private let device = DeviceSnapshot(
    id: "v-1", model: "iPhone", osVersion: "17.5", screenWidth: 390, screenHeight: 844, scale: 3,
    locale: LocaleSnapshot(language: "pt", country: "BR", script: "Latn"), timezone: "GMT-3")

  func testCompleteMetadataHasNoMissingFields() {
    XCTAssertEqual(HostMetadata(app: app, device: device).missingFields, [])
  }

  func testBlankOrInvalidRequiredFieldsAreNamed() {
    let blankApp = TugboatConfig.App(name: " ", version: "", buildNumber: "\n", appId: "id", installationId: "i")
    let badDevice = DeviceSnapshot(
      id: "", model: nil, osVersion: nil, screenWidth: 0, screenHeight: .nan, scale: -1,
      locale: LocaleSnapshot(language: "", country: nil, script: nil), timezone: "")
    XCTAssertEqual(
      HostMetadata(app: blankApp, device: badDevice).missingFields,
      [
        "app.name", "app.version", "app.buildNumber", "device.id", "device.screenSize.width",
        "device.screenSize.height", "device.screenDensity", "device.screenDpi", "locale.language",
      ])
  }

  func testEngineConfigurationPinsEveryGroup() throws {
    let config = TugboatConfig(
      collector: .init(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:3000")), apiKey: "k"), app: app,
      captureFocusChanges: true)
    let json = EngineConfiguration.build(config: config, host: HostMetadata(app: app, device: device), gesture: .uiKitDefault).json
    XCTAssertEqual(
      json,
      "{\"host\":{\"app\":{\"name\":\"Sample\",\"version\":\"1.2\",\"buildNumber\":\"7\",\"installationId\":\"i-1\","
        + "\"appId\":\"com.example\"},\"device\":{\"id\":\"v-1\",\"platform\":\"ios\",\"model\":\"iPhone\","
        + "\"osVersion\":\"17.5\",\"screenSize\":{\"width\":390,\"height\":844},\"screenDensity\":3,\"screenDpi\":480,"
        + "\"screenPixelDensity\":3},\"ip\":{\"ip\":\"127.0.0.1\"},\"locale\":{\"language\":\"pt\",\"country\":\"BR\","
        + "\"timezone\":\"GMT-3\"}},\"limits\":{\"maxEvents\":5000,\"maxFrames\":500,\"maxScrollSamples\":200},"
        + "\"gesture\":{\"touchSlop\":10,\"panSlop\":20,\"scaleSlop\":20,\"trackpadScaleThreshold\":1.08},"
        + "\"capture\":{\"answerTimeoutMs\":5000},\"collector\":{\"enabled\":true},"
        + "\"capabilities\":{\"focusChanges\":true,\"captureDiagnostics\":false}}")
  }

  func testCaptureDiagnosticsIsAnEngineCapability() throws {
    var config = TugboatConfig(
      collector: .init(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:3000")), apiKey: "k"), app: app)
    XCTAssertFalse(config.captureDiagnostics)
    config.captureDiagnostics = true
    let json = EngineConfiguration.build(config: config, host: HostMetadata(app: app, device: device), gesture: .uiKitDefault).json
    XCTAssertEqual(
      jsonObject(json)["capabilities"] as? NSDictionary, ["focusChanges": false, "captureDiagnostics": true])
  }

  func testSessionStartCarriesNonBlankActivationAndExplorationIds() {
    let host = HostMetadata(app: app, device: device)
    let both = jsonObject(
      SessionMessages.sessionStartInput(
        viewport: (1, 1), host: host, sessionEpoch: 3, activationRequestId: "act-1", explorationRunId: " run 2 "))
    XCTAssertEqual(both["activationRequestId"] as? String, "act-1")
    XCTAssertEqual(both["explorationRunId"] as? String, " run 2 ", "sent as given when not blank")
    XCTAssertEqual(both["sessionEpoch"] as? Int, 3)
    for blank in [nil, "", "  \n"] {
      let input = jsonObject(
        SessionMessages.sessionStartInput(
          viewport: (1, 1), host: host, sessionEpoch: 0, activationRequestId: blank, explorationRunId: blank))
      XCTAssertNil(input["activationRequestId"], "blank is omitted, not sent as \"\"")
      XCTAssertNil(input["explorationRunId"])
    }
  }

  func testTheConfigurationDefaultsToDormant() throws {
    let config = TugboatConfig(
      collector: .init(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:3000")), apiKey: "k"), app: app)
    XCTAssertFalse(config.enabled)
    XCTAssertNil(config.explorationRunId)
  }

  func testSessionStartCarriesTheActiveLocale() {
    let input = SessionMessages.sessionStartInput(
      viewport: (390, 844), host: HostMetadata(app: app, device: device), sessionEpoch: 2)
    XCTAssertEqual(
      input,
      "{\"viewport\":{\"width\":390,\"height\":844},\"platform\":\"ios\",\"sessionEpoch\":2,"
        + "\"locale\":{\"language\":\"pt\",\"country\":\"BR\",\"script\":\"Latn\",\"tag\":\"pt-Latn-BR\"}}")
  }

  func testIdentityLifecycleAndEndInputs() {
    XCTAssertEqual(SessionMessages.identityInput("u-\"1"), "{\"userId\":\"u-\\\"1\"}")
    XCTAssertEqual(SessionMessages.identityInput(nil), "{\"userId\":null}")
    XCTAssertEqual(SessionMessages.appLifecycleInput("paused"), "{\"state\":\"paused\"}")
    XCTAssertEqual(SessionMessages.sessionEndInput(), "{\"reason\":\"session_end\"}")
  }

  func testTraitsAreEncodedOrRejected() {
    let input = SessionMessages.traitsInput(["plan": "pro", "seats": 3, "beta": true])
    XCTAssertEqual(jsonObject(input ?? "")["traits"] as? NSDictionary, ["plan": "pro", "seats": 3, "beta": true])
    XCTAssertNil(SessionMessages.traitsInput(["ratio": Double.nan]))
    XCTAssertNil(SessionMessages.traitsInput(["when": Date()]))
  }

  func testDpiFollowsFlutter() {
    XCTAssertEqual(device.screenDpi, 480)
    let twoX = DeviceSnapshot(
      id: "v", model: nil, osVersion: nil, screenWidth: 1, screenHeight: 1, scale: 2,
      locale: LocaleSnapshot(language: "en", country: nil, script: nil), timezone: "UTC")
    XCTAssertEqual(twoX.screenDpi, 320)
  }
}
