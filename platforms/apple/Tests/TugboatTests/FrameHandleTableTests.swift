import Foundation
import XCTest

@testable import Tugboat

final class FrameHandleTableTests: XCTestCase {
  func testPutGetReleaseLifecycle() {
    let table = FrameHandleTable()
    let jpeg = Data([1, 2, 3])
    let handle = table.put(jpeg)

    XCTAssertEqual(table.get(handle), jpeg)
    XCTAssertEqual(table.count, 1)
    XCTAssertTrue(table.release(handle))
    XCTAssertNil(table.get(handle))
    XCTAssertFalse(table.release(handle), "a second release is a no-op")
    XCTAssertEqual(table.count, 0)
  }

  func testHandlesAreNeverReused() {
    let table = FrameHandleTable()
    let first = table.put(Data([1]))
    table.release(first)
    let second = table.put(Data([2]))
    XCTAssertNotEqual(first, second)
    XCTAssertNil(table.get(first))
  }

  func testUnknownHandlesResolveToNil() {
    let table = FrameHandleTable()
    XCTAssertNil(table.get("frame-404"))
    XCTAssertFalse(table.release("frame-404"))
  }

  func testCloseFreesEverythingAndKeepsNothingAfterwards() {
    let table = FrameHandleTable()
    let handles = (1...3).map { table.put(Data([UInt8($0)])) }
    table.close()
    XCTAssertEqual(table.count, 0)
    for handle in handles {
      XCTAssertNil(table.get(handle))
    }

    let late = table.put(Data([9]))
    XCTAssertNil(table.get(late))
    XCTAssertFalse(handles.contains(late), "still a new handle")
    XCTAssertEqual(table.count, 0)
  }

  func testPutsRacingCloseRetainNothing() {
    let table = FrameHandleTable()
    DispatchQueue.concurrentPerform(iterations: 400) { index in
      if index == 200 {
        table.close()
      }
      _ = table.put(Data([0]))
    }
    table.close()
    XCTAssertEqual(table.count, 0)
  }

  func testConcurrentPutsGetDistinctHandles() {
    let table = FrameHandleTable()
    let handles = Locked<[String]>([])
    DispatchQueue.concurrentPerform(iterations: 400) { _ in
      let handle = table.put(Data([0]))
      handles.withLock { $0.append(handle) }
    }
    XCTAssertEqual(Set(handles.current).count, 400)
    XCTAssertEqual(table.count, 400)
  }
}
