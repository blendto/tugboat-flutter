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
    let session: SessionFlag
    let clock: HostClock
    let locale: LocaleBridge
    let sessionStartAt: HostTime

    static func assemble(config: TugboatConfig, transport: EngineTransport, initialLocale: LocaleSnapshot) -> Parts {
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
      let reporter = SurfaceReporter { input in
        HostLog.debug("surface \(input)")
        ref.host?.post(type: SurfaceReporter.factType, inputJSON: input, at: clock.now())
      }
      let captures = CaptureCoordinator(
        window: { KeyWindow.current() },
        masks: { Parts.frameMasks(reporter) },
        capturer: RuntimeWindowCapturer(),
        frames: frames,
        answer: { answer in
          if case let .captured(requestId, frame, boundary, _) = answer {
            HostLog.debug(
              "capture.result \(requestId) \(frame.width)x\(frame.height) px boundaryRect \(boundary.map { "\($0)" } ?? "none") pt")
          }
          ref.host?.post(
            type: HostMessages.captureResult, inputJSON: CaptureResultJSON.encode(answer), at: clock.now(),
            frameHandles: answer.frameHandles)
        }
      )
      let host = EngineHost.start(transport: transport, frames: frames, http: watcher, captures: captures)
      ref.host = host
      let adapter = SwiftUIAdapter(
        sink: host, hostClock: clock, gesture: .uiKitDefault,
        trackHostingControllers: config.trackHostingControllers,
        accessibilityIdentity: config.swiftUIAccessibilityIdentity)
      let session = SessionFlag()
      let startAt = clock.now()
      let locale = LocaleBridge(initial: initialLocale) { input in
        ref.host?.post(type: SessionMessages.localeSet, inputJSON: input, at: clock.now())
      }
      let lifecycle = AppLifecycleBridge { state in
        ref.host?.post(type: SessionMessages.appLifecycle, inputJSON: SessionMessages.appLifecycleInput(state), at: clock.now())
        // The engine ends the session on `detached`.
        if state == AppLifecycleBridge.detached { session.isLive = false }
      }
      return Parts(
        host: host, adapter: adapter, lifecycle: lifecycle, surfaces: SurfaceObserver(reporter: reporter),
        captures: captures, watcher: watcher, session: session, clock: clock, locale: locale,
        sessionStartAt: startAt)
    }

    /// One capture's mask supplier: the adapter's mask walk, the current
    /// `.tugboatScreen` for the structure, and the drawn size as `surface`.
    private static func frameMasks(_ reporter: SurfaceReporter) -> FrameMasks {
      FrameMasks(
        compute: { WindowMasks.compute($0) },
        screen: {
          ScreenTracker.shared.settle()
          return ScreenTracker.shared.visibleTop?.name
        },
        onGeometry: { reporter.observe($0.boundaryRect) }
      )
    }
  }

  /// The host as the parts' closures see it.
  final class HostRef {
    weak var host: EngineHost?
  }

  /// Whether the session can still post `session_end`. Main thread only.
  final class SessionFlag {
    var isLive = true
  }
}
#endif
