import Foundation

/// Runs `http.send` effects with one ephemeral `URLSession` whose delegate
/// queue runs on the serial `tugboat.io` queue. Headers and bodies match the
/// Flutter `CollectorHttpSink` and the Android host.
///
/// `timeoutMs` is a total deadline: a watchdog on the IO queue answers
/// `.timeout` and cancels the task (the request's `timeoutInterval` is only
/// the idle timeout). Every request is answered exactly once; failures become
/// `.error`, never a throw, and every answer is one the engine accepts
/// (`CollectorResponse`). All mutable state is confined to the IO queue.
final class HTTPExecutor: HTTPSender {
  /// Dart's `http` adds the charset to the sink's `application/json`.
  static let jsonContentType = "application/json; charset=utf-8"
  private static let jpegContentType = "image/jpeg"
  private static let framesField = "files"

  /// Session-wide backstop; each request's own deadline is its watchdog.
  static let resourceTimeout: TimeInterval = 120

  private let config: HostConfig
  private let frameBytes: (_ handle: String) -> Data?
  private let ioQueue: DispatchQueue
  private let session: URLSession

  // IO queue only.
  private var inFlight: [Int: InFlight] = [:]
  private var closed = false

  /// One running request.
  private final class InFlight {
    let task: URLSessionTask
    let watchdog: DispatchSourceTimer
    let onResult: (TransportOutcome) -> Void
    var status: Int?
    var retryAfter: String?
    var body = Data()

    init(task: URLSessionTask, watchdog: DispatchSourceTimer, onResult: @escaping (TransportOutcome) -> Void) {
      self.task = task
      self.watchdog = watchdog
      self.onResult = onResult
    }
  }

  private struct Payload {
    let contentType: String
    let bytes: Data
  }

  /// `frameBytes` returns the JPEG for a frame handle at send time; normally
  /// `FrameHandleTable.get`.
  init(
    config: HostConfig,
    frameBytes: @escaping (_ handle: String) -> Data?,
    sessionConfiguration: URLSessionConfiguration = HTTPExecutor.makeSessionConfiguration()
  ) {
    self.config = config
    self.frameBytes = frameBytes
    let ioQueue = DispatchQueue(label: "tugboat.io", qos: .utility)
    let delegateQueue = OperationQueue()
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.underlyingQueue = ioQueue
    let delegate = HTTPSessionDelegate()
    self.ioQueue = ioQueue
    self.session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: delegateQueue)
    delegate.executor = self
  }

  deinit {
    // Nothing else references this executor, so no IO-queue work can race.
    for entry in inFlight.values {
      entry.watchdog.cancel()
      entry.onResult(.error)
    }
    inFlight.removeAll()
    session.invalidateAndCancel()
  }

  /// Ephemeral: no cache, cookies, or credential storage.
  static func makeSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForResource = resourceTimeout
    return configuration
  }

  func send(_ request: HTTPRequest, onResult: @escaping (TransportOutcome) -> Void) {
    ioQueue.async {
      self.start(request, onResult: onResult)
    }
  }

  func close() {
    ioQueue.async {
      guard !self.closed else { return }
      self.closed = true
      // Running tasks finish (each bounded by its watchdog); no new ones start.
      self.session.finishTasksAndInvalidate()
    }
  }

  // MARK: - IO queue

  private func start(_ request: HTTPRequest, onResult: @escaping (TransportOutcome) -> Void) {
    guard !closed, let urlRequest = makeURLRequest(request) else {
      onResult(.error)
      return
    }
    let task = session.dataTask(with: urlRequest)
    let taskId = task.taskIdentifier
    let watchdog = DispatchSource.makeTimerSource(flags: [], queue: ioQueue)
    watchdog.setEventHandler { [weak self] in
      self?.expire(taskId: taskId)
    }
    inFlight[taskId] = InFlight(task: task, watchdog: watchdog, onResult: onResult)
    watchdog.schedule(deadline: .now() + .milliseconds(HTTPExecutor.timeoutMs(request)), repeating: .never)
    watchdog.resume()
    task.resume()
  }

  func received(response: URLResponse, taskId: Int) {
    guard let entry = inFlight[taskId], let http = response as? HTTPURLResponse else { return }
    entry.status = http.statusCode
    entry.retryAfter = CollectorResponse.forwardRetryAfter(HTTPExecutor.header("Retry-After", in: http))
  }

  /// A response header by case-insensitive name. `value(forHTTPHeaderField:)`
  /// needs macOS 10.15, below the package's macOS floor for `swift build`.
  private static func header(_ name: String, in response: HTTPURLResponse) -> String? {
    for (key, value) in response.allHeaderFields {
      if let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame {
        return value as? String
      }
    }
    return nil
  }

  func received(data: Data, taskId: Int) {
    guard let entry = inFlight[taskId] else { return }
    let room = max(0, CollectorResponse.maxBodyBytes - entry.body.count)
    entry.body.append(data.prefix(room))
    guard entry.body.count >= CollectorResponse.maxBodyBytes, let status = entry.status else { return }
    // The engine only reads the first 64 KiB; stop downloading the rest.
    finish(
      taskId: taskId,
      outcome: CollectorResponse.outcome(
        status: status, body: entry.body, retryAfter: entry.retryAfter))
    entry.task.cancel()
  }

  func completed(taskId: Int, error: Error?) {
    guard let entry = inFlight[taskId] else { return }
    if let error = error {
      let timedOut = (error as? URLError)?.code == .timedOut
      if !timedOut {
        HostLog.warning("collector request failed: \((error as NSError).domain) \((error as NSError).code)")
      }
      finish(taskId: taskId, outcome: timedOut ? .timeout : .error)
    } else if let status = entry.status {
      finish(
      taskId: taskId,
      outcome: CollectorResponse.outcome(
        status: status, body: entry.body, retryAfter: entry.retryAfter))
    } else {
      finish(taskId: taskId, outcome: .error)
    }
  }

  private func expire(taskId: Int) {
    guard let entry = inFlight[taskId] else { return }
    finish(taskId: taskId, outcome: .timeout)
    entry.task.cancel()
  }

  private func finish(taskId: Int, outcome: TransportOutcome) {
    guard let entry = inFlight.removeValue(forKey: taskId) else { return }
    entry.watchdog.cancel()
    entry.onResult(outcome)
  }

  // MARK: - Requests

  private func makeURLRequest(_ request: HTTPRequest) -> URLRequest? {
    guard let url = HTTPExecutor.resolve(baseURL: config.collectorBaseURL, path: request.path) else {
      HostLog.warning("collector base URL or path is not an http(s) URL: \(request.path)")
      return nil
    }
    guard let payload = payload(request.body) else { return nil }
    let idleTimeout = TimeInterval(HTTPExecutor.timeoutMs(request)) / 1000
    var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: idleTimeout)
    urlRequest.httpMethod = "POST"
    for header in config.collectorHeaders {
      urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
    }
    urlRequest.setValue(payload.contentType, forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = payload.bytes
    return urlRequest
  }

  private func payload(_ body: HTTPBody) -> Payload? {
    switch body {
    case let .json(text):
      return Payload(contentType: HTTPExecutor.jsonContentType, bytes: Data(text.utf8))
    case let .multipart(fields, frames):
      var files: [MultipartBody.File] = []
      for frame in frames {
        guard let jpeg = frameBytes(frame.handle) else {
          HostLog.warning("frame handle \(frame.handle) is not in the table")
          return nil
        }
        files.append(
          MultipartBody.File(
            field: HTTPExecutor.framesField, filename: frame.filename,
            contentType: HTTPExecutor.jpegContentType, bytes: jpeg))
      }
      let multipart = MultipartBody(fields: fields, files: files)
      return Payload(contentType: multipart.contentType, bytes: multipart.encoded())
    }
  }

  /// `timeoutMs` within 1 ms and one day, the engine's own duration range.
  static func timeoutMs(_ request: HTTPRequest) -> Int {
    min(max(1, request.timeoutMs), 86_400_000)
  }

  /// Dart's `Uri.resolve` on the base URL without trailing slashes; only
  /// absolute http(s) results are sent.
  static func resolve(baseURL: String, path: String) -> URL? {
    var base = baseURL
    while base.hasSuffix("/") {
      base.removeLast()
    }
    guard let baseURL = URL(string: base),
      let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      url.host != nil
    else {
      return nil
    }
    return url
  }
}
