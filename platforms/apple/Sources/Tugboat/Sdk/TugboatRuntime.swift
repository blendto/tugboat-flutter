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
  private let outbox: OutboxParts?
  private var stopped = false

  /// The session's id (`session-<UUIDv4>`, what the collector sees), derived
  /// from the `idSeed` this session started with.
  let captureSessionId: String

  /// The engine handle each session opens; tests wrap it to record what the
  /// SDK submits. Main thread only.
  static var openTransport: () -> EngineTransport? = { EngineBridge.open() }

  /// The store the installation id lives in (tests replace it); read on the
  /// engine queue, never on the main thread.
  static var installationIds: InstallationIdStore = .shared

  /// Keeps the process running for the background flush; tests replace it.
  /// Main thread only.
  static var backgroundTasks: BackgroundTasks = ApplicationBackgroundTasks()

  private init(parts: Parts, captureSessionId: String) {
    host = parts.host
    adapter = parts.adapter
    lifecycle = parts.lifecycle
    surfaces = parts.surfaces
    captures = parts.captures
    watcher = parts.watcher
    session = parts.session
    clock = parts.clock
    locale = parts.locale
    outbox = parts.outbox
    self.captureSessionId = captureSessionId
  }

  /// False once the engine host closed or disabled itself; any thread.
  var isHostRunning: Bool {
    host.isRunning
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
  /// returns.
  func stop(sequence: StopSequence = StopSequence()) {
    guard !stopped else { return }
    stopped = true
    // No replay once the session ends: nothing is sent while dormant.
    outbox?.outbox.stopReplay()
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
  /// `explorationRunId` go on `session.start` when non-blank.
  static func start(config: TugboatConfig, sessionEpoch: Int, activationRequestId: String?) -> TugboatRuntime? {
    let device = DeviceSnapshot.read()
    // Validates what the config and device give; the installation id is resolved later, off the main thread.
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
    let parts = Parts.assemble(config: config, transport: transport, initialLocale: device.locale)
    // The installation id (the host's when non-blank, else the SDK's own file, seeded with
    // `identifierForVendor`) is read, or minted and written, on the engine queue when this message is
    // reached: `start` does not wait for the disk, and the id is in place before `session.start` and so
    // before the first `session_start`.
    let vendorId = device.id == "ios-unknown" ? nil : device.id
    let gesture = parts.adapter.gesture
    let installationIds = Self.installationIds
    parts.host.postUntimed(type: SessionMessages.engineConfigure) {
      let app = config.app.resolvingInstallationId(vendorId: vendorId, store: installationIds)
      return EngineConfiguration.build(config: config, host: HostMetadata(app: app, device: device), gesture: gesture).json
    }
    let idSeed = IdSeed.generate()
    parts.host.post(
      type: SessionMessages.sessionStart,
      inputJSON: SessionMessages.sessionStartInput(
        viewport: KeyWindow.viewport(fallback: device), host: metadata, sessionEpoch: sessionEpoch,
        activationRequestId: activationRequestId, explorationRunId: config.explorationRunId, idSeed: idSeed),
      at: parts.sessionStartAt)
    parts.outbox?.startReplay()
    parts.lifecycle.start()
    parts.locale.start()
    parts.surfaces.start()
    parts.adapter.start()
    return TugboatRuntime(parts: parts, captureSessionId: IdSeed.sessionId(idSeed))
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
