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
    requireRuntime().capabilities().toPigeon()
  }

  func capture(
    request: NativeCaptureRequest,
    completion: @escaping (Result<NativeCaptureResult, Error>) -> Void
  ) {
    guard let view = flutterView() else {
      completion(.success(request.toFailed(.surfaceUnavailable)))
      return
    }
    requireRuntime().capture(view: view, request: request.toRuntime()) { result in
      self.callbackQueue.async {
        completion(.success(result.toPigeon()))
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

private extension CaptureCapabilities {
  func toPigeon() -> NativeCaptureCapabilities {
    NativeCaptureCapabilities(
      nativeCaptureSupported: nativeCaptureSupported,
      apiLevel: Int64(apiLevel),
      minNativeApi: Int64(minNativeApi)
    )
  }
}

private extension NativeCaptureRequest {
  func toRuntime() -> CaptureRequest {
    CaptureRequest(
      requestId: requestId,
      pixelWidth: Int(pixelWidth),
      pixelHeight: Int(pixelHeight),
      force: force,
      lastDHash: lastDHash,
      masks: masks.map {
        NormalizedMask(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
      }
    )
  }

  func toFailed(_ status: NativeCaptureStatus) -> NativeCaptureResult {
    NativeCaptureResult(
      requestId: requestId,
      status: status,
      jpeg: FlutterStandardTypedData(bytes: Data()),
      width: 0,
      height: 0,
      dHash: "",
      contentHash: "",
      timings: emptyTimings(),
      renderMode: .unknown,
      incomplete: false
    )
  }
}

private extension CaptureResult {
  func toPigeon() -> NativeCaptureResult {
    NativeCaptureResult(
      requestId: requestId,
      status: status.toPigeon(),
      coverage: coverage?.toPigeon(),
      jpeg: FlutterStandardTypedData(bytes: jpeg),
      width: Int64(width),
      height: Int64(height),
      dHash: dHash,
      contentHash: contentHash,
      timings: timings.toPigeon(),
      renderMode: renderMode.toPigeon(),
      incomplete: incomplete
    )
  }
}

private extension CaptureStatus {
  func toPigeon() -> NativeCaptureStatus {
    switch self {
    case .ok: return .ok
    case .skippedByDHash: return .skippedByDHash
    case .unsupportedApi: return .unsupportedApi
    case .unsupportedRenderMode: return .unsupportedRenderMode
    case .surfaceUnavailable: return .surfaceUnavailable
    case .timeout: return .timeout
    case .pixelCopyFailed: return .pixelCopyFailed
    case .processingFailed: return .processingFailed
    case .cancelled: return .cancelled
    case .disposed: return .disposed
    }
  }
}

private extension CaptureCoverage {
  func toPigeon() -> NativeCaptureCoverage {
    switch self {
    case .engineSurface: return .engineSurface
    case .viewHierarchy: return .viewHierarchy
    }
  }
}

private extension RenderMode {
  func toPigeon() -> NativeCaptureRenderMode {
    switch self {
    case .surfaceView: return .surfaceView
    case .textureView: return .textureView
    case .hybrid: return .hybrid
    case .unknown: return .unknown
    }
  }
}

private extension CaptureTimings {
  func toPigeon() -> NativeCaptureTimings {
    NativeCaptureTimings(
      surfaceCopyMicros: surfaceCopyMicros,
      maskFillMicros: maskFillMicros,
      dHashMicros: dHashMicros,
      jpegMicros: jpegMicros,
      sha256Micros: sha256Micros,
      pixelReadbackMicros: pixelReadbackMicros
    )
  }
}

private func emptyTimings() -> NativeCaptureTimings {
  NativeCaptureTimings(
    surfaceCopyMicros: 0,
    maskFillMicros: 0,
    dHashMicros: 0,
    jpegMicros: 0,
    sha256Micros: 0,
    pixelReadbackMicros: 0
  )
}
