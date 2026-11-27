import XCTest

/// BLE-711: React Native's HTTP handler skips the image loader's requests and
/// keeps every other request. The handler lives in the app (an Objective-C++
/// class), so the tests reach it through the runtime.
final class ImageLoaderRequestFilterTests: XCTestCase {
  private let handlerClass: NSObject.Type = {
    guard let handler = NSClassFromString("TugboatHTTPRequestHandler") as? NSObject.Type else {
      fatalError("TugboatHTTPRequestHandler is not in the app")
    }
    return handler
  }()

  private func isImageLoaderRequest(_ request: URLRequest) -> Bool {
    // A class method returning BOOL: call its implementation with the right type.
    typealias Filter = @convention(c) (AnyObject, Selector, NSURLRequest) -> Bool
    let selector = NSSelectorFromString("isImageLoaderRequest:")
    let implementation = class_getMethodImplementation(object_getClass(handlerClass), selector)
    return unsafeBitCast(implementation, to: Filter.self)(handlerClass, selector, request as NSURLRequest)
  }

  private func request(_ url: String, trackingName: String? = nil) -> URLRequest {
    let mutable = NSMutableURLRequest(url: URL(string: url)!)
    if let trackingName {
      URLProtocol.setProperty(trackingName, forKey: "trackingName", in: mutable)
    }
    return mutable as URLRequest
  }

  func testImageLoaderRequestIsSkipped() {
    XCTAssertTrue(isImageLoaderRequest(request("https://example.com/cat.png", trackingName: "RCTImageLoader")))
  }

  func testPlainFetchOfAnImageUrlIsKept() {
    XCTAssertFalse(isImageLoaderRequest(request("https://example.com/cat.png")))
  }

  func testOtherTrackingNameIsKept() {
    XCTAssertFalse(isImageLoaderRequest(request("https://example.com/api", trackingName: "MyFetch")))
  }

  func testTagSurvivesACopy() {
    // React Native hands the handler a copy of the request it tagged.
    let tagged = request("https://example.com/cat.png", trackingName: "RCTImageLoader")
    XCTAssertTrue(isImageLoaderRequest((tagged as NSURLRequest).mutableCopy() as! URLRequest))
  }
}
