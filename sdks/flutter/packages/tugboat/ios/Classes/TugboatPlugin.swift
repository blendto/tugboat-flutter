import Flutter
import TugboatCaptureRuntime
import UIKit

public class TugboatPlugin: NSObject, FlutterPlugin, NativeCaptureHostApi {
  private var runtime: CaptureRuntime?
  private weak var registrar: FlutterPluginRegistrar?
  private let callbackQueue = DispatchQueue.main

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = TugboatPlugin()
    instance.registrar = registrar
    instance.runtime = CaptureRuntime()
    NativeCaptureHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
  }

  func getCapabilities() throws -> NativeCaptureCapabilities {
    NativeCaptureMapping.capabilities(requireRuntime().capabilities())
  }

  func capture(
    request: NativeCaptureRequest,
    completion: @escaping (Result<NativeCaptureResult, Error>) -> Void
  ) {
    guard let view = flutterView() else {
      completion(.success(NativeCaptureMapping.failed(request, .surfaceUnavailable)))
      return
    }
    requireRuntime().capture(view: view, request: NativeCaptureMapping.request(request)) { result in
      self.callbackQueue.async {
        completion(.success(NativeCaptureMapping.result(result)))
      }
    }
  }

  func cancel(requestId: Int64) throws {
    runtime?.cancel(requestId: requestId)
  }

  func dispose() throws {
    runtime?.dispose()
    runtime = nil
  }

  private func requireRuntime() -> CaptureRuntime {
    if let runtime {
      return runtime
    }
    let created = CaptureRuntime()
    runtime = created
    return created
  }

  private func flutterView() -> UIView? {
    guard let controller = hostViewController() else {
      return nil
    }
    return findFlutterView(controller.view) ?? controller.view
  }

  /// Flutter 3.38+ exposes `registrar.viewController`. The package floor is
  /// Flutter 3.35, which does not declare that property, so look it up at
  /// runtime and fall back to the key window.
  private func hostViewController() -> UIViewController? {
    if let registrar {
      let selector = NSSelectorFromString("viewController")
      if registrar.responds(to: selector),
         let controller = registrar.perform(selector)?.takeUnretainedValue()
           as? UIViewController
      {
        return controller
      }
    }
    return keyWindowRootViewController()
  }

  private func keyWindowRootViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    let keyWindow = windows.first(where: \.isKeyWindow) ?? windows.first
    return keyWindow?.rootViewController
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
