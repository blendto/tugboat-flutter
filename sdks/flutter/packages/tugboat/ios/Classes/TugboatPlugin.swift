import Flutter
import UIKit

public class TugboatPlugin: NSObject, FlutterPlugin, NativeCaptureHostApi {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = TugboatPlugin()
    NativeCaptureHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
  }

  public func getCapabilities() throws -> NativeCaptureCapabilities {
    NativeCaptureCapabilities(
      nativeCaptureSupported: false,
      apiLevel: 0,
      minNativeApi: 24
    )
  }

  public func capture(
    request: NativeCaptureRequest,
    completion: @escaping (Result<NativeCaptureResult, Error>) -> Void
  ) {
    completion(
      .success(
        NativeCaptureResult(
          requestId: request.requestId,
          status: .unsupportedApi,
          jpeg: FlutterStandardTypedData(bytes: Data()),
          width: 0,
          height: 0,
          dHash: "",
          contentHash: "",
          timings: NativeCaptureTimings(
            surfaceCopyMicros: 0,
            maskFillMicros: 0,
            dHashMicros: 0,
            jpegMicros: 0,
            sha256Micros: 0,
            pixelReadbackMicros: 0
          ),
          renderMode: .unknown,
          incomplete: false
        )
      )
    )
  }

  public func cancel(requestId: Int64) throws {}

  public func dispose() throws {}
}
