import Flutter
import UIKit
import TugboatCaptureRuntime

public class TugboatPlugin: NSObject, FlutterPlugin, NativeCaptureHostApi {
  private var runtime: CaptureRuntime?
  private let callbackQueue = DispatchQueue.main

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = TugboatPlugin()
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
    if let controller = flutterViewController() {
      return findFlutterView(controller.view) ?? controller.view
    }
    guard let root = keyWindow()?.rootViewController?.view else {
      return nil
    }
    return findFlutterView(root)
  }

  private func flutterViewController() -> FlutterViewController? {
    guard let root = keyWindow()?.rootViewController else {
      return nil
    }
    return findFlutterViewController(root)
  }

  private func findFlutterViewController(_ controller: UIViewController) -> FlutterViewController? {
    if let flutter = controller as? FlutterViewController {
      return flutter
    }
    for child in controller.children {
      if let found = findFlutterViewController(child) {
        return found
      }
    }
    if let presented = controller.presentedViewController {
      return findFlutterViewController(presented)
    }
    return nil
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

  private func keyWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    return windows.first(where: \.isKeyWindow) ?? windows.first
  }
}
