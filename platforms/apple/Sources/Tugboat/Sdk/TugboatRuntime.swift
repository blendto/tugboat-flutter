#if canImport(UIKit)
import UIKit

/// One running SDK: the engine host, the SwiftUI adapter, the capture
/// coordinator, the surface observer, and the lifecycle bridge, wired
/// together. Created by `start` (the composition root); main thread only.
/// It owns one engine handle from `engine.configure` to `engine.dispose`.
final class TugboatRuntime {
  private let host: EngineHost
  private let adapter: SwiftUIAdapter
  private let lifecycle: AppLifecycleBridge
  private let surfaces: SurfaceObserver
  private let captures: CaptureCoordinator
  private let watcher: SessionEndWatcher
  private let clock: HostClock
  private var stopped = false

  private init(parts: Parts) {
    host = parts.host
    adapter = parts.adapter
    lifecycle = parts.lifecycle
    surfaces = parts.surfaces
    captures = parts.captures
    watcher = parts.watcher
    clock = parts.clock
  }

  func setUserId(_ userId: String?) {
    host.post(type: SessionMessages.identitySet, inputJSON: SessionMessages.identityInput(userId), at: clock.now())
  }

  /// `traitsInput` is a `SessionMessages.traitsInput`.
  func setTraits(_ traitsInput: String) {
    host.post(type: SessionMessages.traitsSet, inputJSON: traitsInput, at: clock.now())
  }

  /// Detaches every observer (pending facts are posted first), ends the
  /// session, waits off the main thread for its `session_end` post to
  /// settle, then disposes the engine and the pixel runtime
  /// (`StopSequence`).
  func stop(sequence: StopSequence = StopSequence()) {
    guard !stopped else { return }
    stopped = true
    adapter.stop()
    lifecycle.stop()
    surfaces.stop()
    let host = self.host
    let captures = self.captures
    let clock = self.clock
    sequence.run(
      watcher: watcher,
      endSession: {
        host.post(type: SessionMessages.sessionEnd, inputJSON: SessionMessages.sessionEndInput(), at: clock.now())
      },
      finish: {
        host.close()
        captures.dispose()
      }
    )
  }

  /// Configures a new engine and starts a session; nil (logged) when a
  /// `session_start` field is missing or the engine refuses a handle.
  static func start(config: TugboatConfig, sessionEpoch: Int) -> TugboatRuntime? {
    let device = DeviceSnapshot.read()
    let metadata = HostMetadata(app: config.app, device: device)
    let missing = metadata.missingFields + collectorProblems(config.collector)
    guard missing.isEmpty else {
      HostLog.error("Tugboat not started: required session_start fields are missing: \(missing)")
      return nil
    }
    guard let transport = EngineBridge.open() else {
      HostLog.error("Tugboat not started: the session engine is unavailable")
      return nil
    }
    let parts = Parts.assemble(config: config, transport: transport)
    parts.host.postUntimed(
      type: SessionMessages.engineConfigure,
      inputJSON: EngineConfiguration.build(config: config, host: metadata, gesture: parts.adapter.gesture).json)
    parts.host.post(
      type: SessionMessages.sessionStart,
      inputJSON: SessionMessages.sessionStartInput(
        viewport: KeyWindow.viewport(fallback: device), host: metadata, sessionEpoch: sessionEpoch),
      at: parts.clock.now())
    parts.lifecycle.start()
    parts.surfaces.start()
    parts.adapter.start()
    return TugboatRuntime(parts: parts)
  }

  private static func collectorProblems(_ collector: TugboatConfig.Collector) -> [String] {
    var problems: [String] = []
    let scheme = collector.baseURL.scheme?.lowercased()
    if scheme != "http" && scheme != "https" || collector.baseURL.host == nil {
      problems.append("collector.baseURL")
    }
    if collector.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      problems.append("collector.apiKey")
    }
    return problems
  }
}
#endif
