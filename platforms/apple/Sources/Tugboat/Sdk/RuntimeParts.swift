#if canImport(UIKit)
import UIKit

extension TugboatRuntime {
  /// The objects one runtime owns, built in dependency order. Closures that
  /// post to the host hold it weakly through `HostRef`, so nothing outlives
  /// `stop` through a cycle.
  struct Parts {
    let host: EngineHost
    let adapter: SwiftUIAdapter
    let lifecycle: AppLifecycleBridge
    let surfaces: SurfaceObserver
    let captures: CaptureCoordinator
    let watcher: SessionEndWatcher
    let clock: HostClock

    static func assemble(config: TugboatConfig, transport: EngineTransport) -> Parts {
      let clock = SystemHostClock()
      let frames = FrameHandleTable()
      let hostConfig = HostConfig(
        collectorBaseURL: config.collector.baseURL.absoluteString,
        apiKey: config.collector.apiKey,
        appVersion: config.app.version,
        appBuild: config.app.buildNumber,
        appId: config.app.appId
      )
      let watcher = SessionEndWatcher(delegate: HTTPExecutor(config: hostConfig, frameBytes: { frames.get($0) }))
      let ref = HostRef()
      let surfaces = SurfaceObserver(
        reporter: SurfaceReporter { input in
          ref.host?.post(type: SurfaceReporter.factType, inputJSON: input, at: clock.now())
        })
      let captures = CaptureCoordinator(
        window: { KeyWindow.current() },
        masks: { WindowMasks.compute($0) },
        capturer: RuntimeWindowCapturer(),
        frames: frames,
        onSurface: { [weak surfaces] in surfaces?.report($0) },
        answer: { answer in
          ref.host?.post(
            type: HostMessages.captureResult, inputJSON: CaptureResultJSON.encode(answer), at: clock.now(),
            frameHandles: answer.frameHandles)
        }
      )
      let host = EngineHost.start(transport: transport, frames: frames, http: watcher, captures: captures)
      ref.host = host
      let adapter = SwiftUIAdapter(
        sink: host, hostClock: clock, gesture: .uiKitDefault,
        trackHostingControllers: config.trackHostingControllers)
      let lifecycle = AppLifecycleBridge { state in
        ref.host?.post(type: SessionMessages.appLifecycle, inputJSON: SessionMessages.appLifecycleInput(state), at: clock.now())
      }
      return Parts(
        host: host, adapter: adapter, lifecycle: lifecycle, surfaces: surfaces, captures: captures, watcher: watcher,
        clock: clock)
    }
  }

  /// The host as the parts' closures see it.
  final class HostRef {
    weak var host: EngineHost?
  }
}
#endif
