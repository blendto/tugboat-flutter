import Flutter
import TugboatCaptureRuntime
import UIKit

public class TugboatPlugin: NSObject, FlutterPlugin, NativeCaptureHostApi {
  private var engineRuntime: CaptureRuntime?
  private var hierarchyRuntime: CaptureRuntime?
  private weak var registrar: FlutterPluginRegistrar?
  private let callbackQueue = DispatchQueue.main
  private let stateLock = NSLock()
  private var disposed = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = TugboatPlugin()
    instance.registrar = registrar
    instance.engineRuntime = CaptureRuntime()
    NativeCaptureHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
  }

  func getCapabilities() throws -> NativeCaptureCapabilities {
    guard let runtime = engineCaptureRuntime() else {
      return NativeCaptureCapabilities(
        nativeCaptureSupported: false,
        apiLevel: Int64(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
        minNativeApi: Int64(CaptureRuntime.minNativeApi)
      )
    }
    return NativeCaptureMapping.capabilities(runtime.capabilities())
  }

  func capture(
    request: NativeCaptureRequest,
    completion: @escaping (Result<NativeCaptureResult, Error>) -> Void
  ) {
    guard let runtime = engineCaptureRuntime() else {
      complete(NativeCaptureMapping.failed(request, .disposed), completion: completion)
      return
    }
    guard let view = flutterView() else {
      complete(
        NativeCaptureMapping.failed(request, .surfaceUnavailable),
        completion: completion
      )
      return
    }
    let started = DispatchTime.now()
    let nativeRequest = NativeCaptureMapping.request(request)
    runtime.capture(view: view, request: nativeRequest) { result in
      guard result.status == .pixelCopyFailed else {
        self.complete(result, completion: completion)
        return
      }

      let remainingMs = self.remainingTimeoutMs(since: started)
      guard remainingMs > 0 else {
        self.complete(NativeCaptureMapping.failed(request, .timeout), completion: completion)
        return
      }
      guard let hierarchyRuntime = self.makeHierarchyRuntime(timeoutMs: remainingMs) else {
        self.complete(NativeCaptureMapping.failed(request, .disposed), completion: completion)
        return
      }
      hierarchyRuntime.capture(view: view, request: nativeRequest) { retry in
        self.complete(retry, completion: completion)
      }
    }
  }

  func cancel(requestId: Int64) throws {
    let runtimes = captureRuntimes()
    runtimes.engine?.cancel(requestId: requestId)
    runtimes.hierarchy?.cancel(requestId: requestId)
  }

  func dispose() throws {
    stateLock.lock()
    disposed = true
    let engine = engineRuntime
    let hierarchy = hierarchyRuntime
    engineRuntime = nil
    hierarchyRuntime = nil
    stateLock.unlock()
    engine?.dispose()
    hierarchy?.dispose()
  }

  private func complete(
    _ result: CaptureResult,
    completion: @escaping (Result<NativeCaptureResult, Error>) -> Void
  ) {
    complete(NativeCaptureMapping.result(result), completion: completion)
  }

  private func complete(
    _ result: NativeCaptureResult,
    completion: @escaping (Result<NativeCaptureResult, Error>) -> Void
  ) {
    callbackQueue.async {
      completion(.success(result))
    }
  }

  private func engineCaptureRuntime() -> CaptureRuntime? {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !disposed else { return nil }
    if let engineRuntime {
      return engineRuntime
    }
    let created = CaptureRuntime()
    engineRuntime = created
    return created
  }

  /// The controller serializes capture requests. Replace the prior retry runtime
  /// so this attempt uses only the time left in the original request budget.
  private func makeHierarchyRuntime(timeoutMs: Int64) -> CaptureRuntime? {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !disposed else { return nil }
    let created = CaptureRuntime(timeoutMs: timeoutMs, coverage: .viewHierarchy)
    hierarchyRuntime?.dispose()
    hierarchyRuntime = created
    return created
  }

  private func captureRuntimes() -> (engine: CaptureRuntime?, hierarchy: CaptureRuntime?) {
    stateLock.lock()
    defer { stateLock.unlock() }
    return (engineRuntime, hierarchyRuntime)
  }

  private func remainingTimeoutMs(since started: DispatchTime) -> Int64 {
    let elapsedMs = Int64(
      (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
    )
    return max(0, CaptureRuntime.defaultTimeoutMs - elapsedMs)
  }

  private func flutterView() -> UIView? {
    if let controller = registrarViewController(),
      let view = findFlutterView(controller.view)
    {
      return view
    }

    for window in foregroundWindows() {
      if let view = findFlutterView(window) {
        return view
      }
    }
    return nil
  }

  /// Flutter 3.38+ exposes `registrar.viewController`. The package floor is
  /// Flutter 3.35, which does not declare that property, so look it up at runtime.
  private func registrarViewController() -> UIViewController? {
    if let registrar {
      let selector = NSSelectorFromString("viewController")
      if registrar.responds(to: selector),
         let controller = registrar.perform(selector)?.takeUnretainedValue()
           as? UIViewController
      {
        return controller
      }
    }
    return nil
  }

  /// Prefer the active key window. Do not use an arbitrary controller view when
  /// FlutterView is absent because that can produce a valid but unrelated frame.
  private func foregroundWindows() -> [UIWindow] {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
    let activeScenes = scenes.filter { $0.activationState == .foregroundActive }
    let inactiveScenes = scenes.filter { $0.activationState == .foregroundInactive }

    return (activeScenes + inactiveScenes).flatMap { scene in
      scene.windows
        .filter { !$0.isHidden && $0.alpha > 0 }
        .sorted { left, right in
          if left.isKeyWindow != right.isKeyWindow {
            return left.isKeyWindow
          }
          return left.windowLevel.rawValue < right.windowLevel.rawValue
        }
    }
  }

  private func findFlutterView(_ view: UIView) -> UIView? {
    let name = NSStringFromClass(type(of: view))
    if name == "FlutterView" || name.hasSuffix(".FlutterView") {
      return view
    }
    for child in view.subviews {
      if let found = findFlutterView(child) {
        return found
      }
    }
    return nil
  }
}
