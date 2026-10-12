import Foundation
import TugboatSessionEngine

/// `EngineTransport` over the real engine: owns one `tb_session_engine`
/// handle and calls the C ABI directly (no Objective-C++ bridge).
///
/// The engine owns each response buffer only until the next submit or
/// destroy, so `submit` copies it into `Data` before returning. Not
/// thread-safe: the host drives it from its engine queue.
final class EngineBridge: EngineTransport {
  private var handle: OpaquePointer?

  private init(handle: OpaquePointer) {
    self.handle = handle
  }

  deinit {
    close()
  }

  /// Creates a handle; nil when the engine refuses. 0 for a limit uses the
  /// engine default.
  static func open(maxDepth: UInt32 = 0, maxMessageBytes: Int = 0) -> EngineBridge? {
    var config = tb_session_engine_config_v1(
      abi_version: UInt32(TB_SESSION_ENGINE_ABI_VERSION),
      max_depth: maxDepth,
      max_message_bytes: maxMessageBytes
    )
    var created: OpaquePointer?
    let status = tb_session_engine_create_v1(&config, &created)
    guard status == TB_SESSION_OK, let handle = created else {
      HostLog.error("session engine create failed (\(EngineStatus(code: Int(status.rawValue)).wireName))")
      return nil
    }
    return EngineBridge(handle: handle)
  }

  func submit(_ message: Data) -> EngineResponse {
    guard let handle = handle else {
      return EngineResponse(status: .invalidArgument, json: Data())
    }
    var out: UnsafePointer<CChar>?
    var outLength = 0
    let status = message.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> tb_session_status in
      let bytes = raw.baseAddress?.assumingMemoryBound(to: CChar.self)
      return tb_session_engine_submit_v1(handle, bytes, raw.count, &out, &outLength)
    }
    // `out` belongs to the engine until the next call on this handle.
    var json = Data()
    if let out = out, outLength > 0 {
      json = Data(bytes: out, count: outLength)
    }
    return EngineResponse(status: EngineStatus(code: Int(status.rawValue)), json: json)
  }

  func close() {
    guard let handle = handle else { return }
    self.handle = nil
    tb_session_engine_destroy(handle)
  }
}
