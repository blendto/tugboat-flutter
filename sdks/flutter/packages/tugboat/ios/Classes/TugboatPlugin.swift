import Flutter
import TugboatCaptureRuntime
import UIKit

public class TugboatPlugin: NSObject, FlutterPlugin, NativeCaptureHostApi {
  private var engineRuntime: CaptureRuntime?
  private var hierarchyRuntime: CaptureRuntime?
  private weak var registrar: FlutterPluginRegistrar?
  private let callbackQueue = DispatchQueue.main

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = TugboatPlugin()
    instance.registrar = registrar
    instance.engineRuntime = CaptureRuntime()
    instance.hierarchyRuntime = CaptureRuntime(coverage: .viewHierarchy)
    NativeCaptureHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
  }

  func getCapabilities() throws -> NativeCaptureCapabilities {
    NativeCaptureMapping.capabilities(requireEngineRuntime().capabilities())
  }

  func capture(
    request: NativeCaptureRequest,
    completion: @escaping (Result<NativeCaptureResult, Error>) -> Void
  ) {
    guard let view = flutterView() else {
      completion(.success(NativeCaptureMapping.failed(request, .surfaceUnavailable)))
      return
    }
    let nativeRequest = NativeCaptureMapping.request(request)
    requireEngineRuntime().capture(view: view, request: nativeRequest) { result in
      guard result.status == .pixelCopyFailed else {
        self.complete(result, completion: completion)
        return
      }

      self.requireHierarchyRuntime().capture(view: view, request: nativeRequest) { retry in
        self.complete(retry, completion: completion)
      }
    }
  }

  func cancel(requestId: Int64) throws {
    engineRuntime?.cancel(requestId: requestId)
    hierarchyRuntime?.cancel(requestId: requestId)
  }

  func dispose() throws {
    engineRuntime?.dispose()
    hierarchyRuntime?.dispose()
    engineRuntime = nil
    hierarchyRuntime = nil
  }

  private func complete(
    _ result: CaptureResult,
    completion: @escaping (Result<NativeCaptureResult, Error>) -> Void
  ) {
    callbackQueue.async {
      completion(.success(NativeCaptureMapping.result(result)))
    }
  }

  private func requireEngineRuntime() -> CaptureRuntime {
    if let engineRuntime {
      return engineRuntime
    }
    let created = CaptureRuntime()
    engineRuntime = created
    return created
  }

  private func requireHierarchyRuntime() -> CaptureRuntime {
    if let hierarchyRuntime {
      return hierarchyRuntime
    }
    let created = CaptureRuntime(coverage: .viewHierarchy)
    hierarchyRuntime = created
    return created
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
