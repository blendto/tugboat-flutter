import Foundation
import XCTest

@testable import Tugboat

final class EffectParserTests: XCTestCase {
  private func parse(_ effects: String...) throws -> [Effect] {
    try EffectParser.parse(Data(("{\"type\":\"t\",\"records\":[],\"effects\":[" + effects.joined(separator: ",") + "]}").utf8))
  }

  func testParsesEveryKnownEffectInOrder() throws {
    let effects = try parse(
      "{\"type\":\"timer.schedule\",\"timerId\":\"flush\",\"atMonoUs\":4000000}",
      "{\"type\":\"frame.release\",\"handle\":\"frame-1\"}",
      "{\"type\":\"timer.cancel\",\"timerId\":\"flush\"}",
      "{\"type\":\"capture.request\",\"requestId\":\"capture_request-1\"}"
    )
    XCTAssertEqual(
      effects,
      [
        .timerSchedule(timerId: "flush", atMonoUs: 4_000_000),
        .frameRelease(handle: "frame-1"),
        .timerCancel(timerId: "flush"),
        .unknown(type: "capture.request"),
      ])
  }

  func testJSONBodyIsThePreEncodedString() throws {
    let effects = try parse(
      "{\"type\":\"http.send\",\"requestId\":\"http-7\",\"lane\":\"events\",\"path\":\"/v1/events/batch\","
        + "\"timeoutMs\":15000,\"jsonBody\":\"{\\\"events\\\":[{\\\"w\\\":390.0}]}\"}")
    XCTAssertEqual(
      effects,
      [
        .httpSend(
          HTTPRequest(
            requestId: "http-7", lane: "events", path: "/v1/events/batch", timeoutMs: 15_000,
            body: .json("{\"events\":[{\"w\":390.0}]}")))
      ])
  }

  func testMultipartKeepsFieldPairOrderAndFrames() throws {
    let effects = try parse(
      "{\"type\":\"http.send\",\"requestId\":\"http-3\",\"lane\":\"frames\",\"path\":\"/v1/frames\",\"timeoutMs\":15000,"
        + "\"multipart\":{\"fields\":[[\"sessionId\",\"s-1\"],[\"frameNos\",\"1,2\"],"
        + "[\"frameMetadata\",\"[{\\\"frameNo\\\":1}]\"]],"
        + "\"frames\":[{\"handle\":\"frame-1\",\"filename\":\"1.jpg\"},{\"handle\":\"frame-2\",\"filename\":\"2.jpg\"}]}}")
    guard case let .httpSend(request)? = effects.first, effects.count == 1 else {
      return XCTFail("expected one http.send, got \(effects)")
    }
    XCTAssertEqual(request.requestId, "http-3")
    XCTAssertEqual(
      request.body,
      .multipart(
        fields: [
          FormField(name: "sessionId", value: "s-1"),
          FormField(name: "frameNos", value: "1,2"),
          FormField(name: "frameMetadata", value: "[{\"frameNo\":1}]"),
        ],
        frames: [FramePart(handle: "frame-1", filename: "1.jpg"), FramePart(handle: "frame-2", filename: "2.jpg")]))
  }

  func testUnknownTypesAreKeptForTheDispatcher() throws {
    XCTAssertEqual(try parse("{\"type\":\"outbox.write\",\"id\":\"o\"}"), [.unknown(type: "outbox.write")])
  }

  func testMalformedEffectsAreSkipped() throws {
    let effects = try parse(
      "{\"type\":\"timer.schedule\",\"timerId\":\"t\"}",
      "{\"type\":\"timer.schedule\",\"timerId\":\"t\",\"atMonoUs\":1.5}",
      "{\"type\":\"timer.schedule\",\"timerId\":\"t\",\"atMonoUs\":true}",
      "{\"type\":\"timer.schedule\",\"timerId\":7,\"atMonoUs\":1}",
      "{\"type\":\"http.send\",\"requestId\":\"r\",\"lane\":\"events\",\"path\":\"/p\",\"timeoutMs\":1}",
      "{\"type\":\"http.send\",\"requestId\":\"r\",\"lane\":\"frames\",\"path\":\"/p\",\"timeoutMs\":1,"
        + "\"multipart\":{\"fields\":[[\"only-a-name\"]],\"frames\":[]}}",
      "{\"type\":\"http.send\",\"requestId\":\"r\",\"lane\":\"frames\",\"path\":\"/p\",\"timeoutMs\":1,"
        + "\"multipart\":{\"fields\":[],\"frames\":[{\"handle\":\"frame-1\"}]}}",
      "{\"noType\":true}",
      "17",
      "{\"type\":\"timer.cancel\",\"timerId\":\"t\"}"
    )
    XCTAssertEqual(effects, [.timerCancel(timerId: "t")])
  }

  func testResponsesWithoutEffectsHaveNone() throws {
    let effects = try EffectParser.parse(Data("{\"type\":\"fingerprint.labelHash\",\"result\":{\"hash\":\"x\"}}".utf8))
    XCTAssertEqual(effects, [])
  }

  func testNonObjectResponsesThrow() {
    XCTAssertThrowsError(try EffectParser.parse(Data("not json".utf8)))
    XCTAssertThrowsError(try EffectParser.parse(Data("[1]".utf8)))
  }
}
