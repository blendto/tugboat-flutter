#if canImport(UIKit)
import UIKit

/// One session: the engine host, the SwiftUI adapter, the capture
/// coordinator, the surface observer, and the lifecycle and locale bridges,
/// wired together. Created by `start` (the composition root) when a session
/// starts, never while Tugboat is dormant; main thread only. It owns one
/// engine handle from `engine.configure` to `engine.dispose`.
final class TugboatRuntime {
  private let host: EngineHost
  private let adapter: SwiftUIAdapter
  private let lifecycle: AppLifecycleBridge
  private let surfaces: SurfaceObserver
  private let captures: CaptureCoordinator
  private let watcher: SessionEndWatcher
  private let session: SessionFlag
  private let clock: HostClock
  private let locale: LocaleBridge
  private var stopped = false

  /// The engine handle each session opens; tests wrap it to record what the
  /// SDK submits. Main thread only.
  static var openTransport: () -> EngineTransport? = { EngineBridge.open() }

  private init(parts: Parts) {
    host = parts.host
    adapter = parts.adapter
    lifecycle = parts.lifecycle
    surfaces = parts.surfaces
    captures = parts.captures
    watcher = parts.watcher
    session = parts.session
    clock = parts.clock
    locale = parts.locale
  }

  /// Tests: whether the locale observer is installed.
  var observesLocale: Bool {
    locale.isObserving
  }

  /// Where coded events and network calls go; any thread.
  var evidenceSink: EvidenceSink {
    host
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
  /// settle (only when one will be posted), then disposes the engine and the
  /// pixel runtime (`StopSequence`). `session.end` is posted before this
  /// returns. A pending `TUGBOAT_HEALTH` line is not cancelled here: only
  /// `Tugboat.stop()` cancels it.
  func stop(sequence: StopSequence = StopSequence()) {
    guard !stopped else { return }
    stopped = true
    adapter.stop()
    lifecycle.stop()
    locale.stop()
    surfaces.stop()
    let host = self.host
    let captures = self.captures
    let clock = self.clock
    sequence.run(
      watcher: watcher,
      awaitDrain: host.isRunning && session.isLive,
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
  /// `activationRequestId` (from `Tugboat.activate`) and the configuration's
  /// `explorationRunId` go on `session.start` when non-blank. `lifecycle`
  /// is what `TUGBOAT_HEALTH` reports.
  static func start(
    config: TugboatConfig, sessionEpoch: Int, activationRequestId: String?,
    lifecycle: @escaping LaunchCorrelation.Lifecycle
  ) -> TugboatRuntime? {
    let device = DeviceSnapshot.read()
    let metadata = HostMetadata(app: config.app, device: device)
    let missing = problems(config: config, metadata: metadata)
    guard missing.isEmpty else {
      HostLog.error("Tugboat not started: required session_start fields are missing: \(missing)")
      return nil
    }
    guard let transport = openTransport() else {
      HostLog.error("Tugboat not started: the session engine is unavailable")
      return nil
    }
    let parts = Parts.assemble(
      config: config, transport: transport, initialLocale: device.locale, lifecycle: lifecycle)
    parts.host.postUntimed(
      type: SessionMessages.engineConfigure,
      inputJSON: EngineConfiguration.build(config: config, host: metadata, gesture: parts.adapter.gesture).json)
    parts.host.post(
      type: SessionMessages.sessionStart,
      inputJSON: SessionMessages.sessionStartInput(
        viewport: KeyWindow.viewport(fallback: device), host: metadata, sessionEpoch: sessionEpoch,
        activationRequestId: activationRequestId, explorationRunId: config.explorationRunId),
      at: parts.sessionStartAt)
    parts.lifecycle.start()
    parts.locale.start()
    parts.surfaces.start()
    parts.adapter.start()
    parts.launchCorrelation.startIfNeeded()
    return TugboatRuntime(parts: parts)
  }

  /// The fields a session could not start without, by wire path; empty when
  /// `config` is complete on this device. Main thread only.
  static func missingFields(_ config: TugboatConfig) -> [String] {
    problems(config: config, metadata: HostMetadata(app: config.app, device: DeviceSnapshot.read()))
  }

  private static func problems(config: TugboatConfig, metadata: HostMetadata) -> [String] {
    metadata.missingFields + collectorProblems(config.collector)
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
