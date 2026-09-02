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
    guard let controller = registrar?.viewController else {
      return nil
    }
    return findFlutterView(controller.view) ?? controller.view
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
