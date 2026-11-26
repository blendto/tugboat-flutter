import XCTest

@testable import Tugboat

final class FactBatcherTests: XCTestCase {
  private func fact(_ kind: String, at monoUs: Int64) -> AdapterFact {
    var input = JSONObject()
    input.set("kind", kind)
    return AdapterFact(type: FactTypes.focus, input: input, at: HostTime(monoUs: monoUs, wallUs: monoUs + 1))
  }

  func testFactsLeaveOncePerFrameAsOneBatchWithTheirOwnTimes() {
    let sink = RecordingSink()
    let frames = ManualFrames()
    let batcher = FactBatcher(sink: sink, frames: frames)

    batcher.add(fact("text_input", at: 100))
    batcher.add(fact("none", at: 250))
    XCTAssertEqual(frames.scheduled, 1, "one frame request per frame")
    XCTAssertTrue(sink.batches.isEmpty)

    frames.runFrame()
    XCTAssertEqual(sink.batches.count, 1)
    let json = EngineMessage.batchJSON(sink.batches[0])
    let batch = decodeObject(json)
    XCTAssertEqual(batch?["type"] as? String, "batch")
    let messages = batch?["messages"] as? [[String: Any]]
    XCTAssertEqual(messages?.compactMap { ($0["at"] as? [String: Any])?["monoUs"] as? Int }, [100, 250])
  }

  func testHooksRunBeforeTheFlushAndTheirFactsJoinTheBatch() {
    let sink = RecordingSink()
    let frames = ManualFrames()
    let batcher = FactBatcher(sink: sink, frames: frames)
    batcher.onFrame { batcher.add(self.fact("none", at: 9)) }

    batcher.add(fact("text_input", at: 1))
    frames.runFrame()

    XCTAssertEqual(sink.batches.count, 1)
    XCTAssertEqual(sink.batches[0].count, 2)
    XCTAssertEqual(frames.pending, 0, "facts added by a hook do not request another frame")
  }

  func testAnEmptyFramePostsNothingAndCloseFlushes() {
    let sink = RecordingSink()
    let frames = ManualFrames()
    let batcher = FactBatcher(sink: sink, frames: frames)
    batcher.requestFrame()
    frames.runFrame()
    XCTAssertTrue(sink.batches.isEmpty)

    batcher.add(fact("text_input", at: 1))
    batcher.close()
    XCTAssertEqual(sink.batches.count, 1)
    XCTAssertTrue(frames.invalidated)
  }

  func testEngineHostIsTheSink() {
    let asSink: (EngineHost) -> FactSink = { $0 }
    XCTAssertNotNil(asSink as Any)
  }
}
