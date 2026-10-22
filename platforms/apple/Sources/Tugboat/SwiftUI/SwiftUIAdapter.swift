#if canImport(UIKit)
import UIKit

/// The SwiftUI toolkit adapter (native SDK note section 5): it turns the
/// app's windows into engine facts and answers mask queries. It owns no
/// engine state; facts leave once per frame through `sink`
/// (`EngineHost.postBatch`), each with its own time.
///
/// - Pointer: a `WindowPointerRecognizer` on each window that becomes key.
/// - Tap evidence: `.tugboatTag` frames, then UIKit hit-testing, then
///   (opt-in, ADR 0010) the accessibility tree.
/// - Scroll: KVO on the scroll views of observed windows.
/// - Navigation: `.tugboatScreen` appear and disappear; hosting-controller
///   appearance when `trackHostingControllers` (installs a one-time method
///   exchange, see `ViewControllerAppearance`).
/// - Focus: text editing notifications.
///
/// Internal: the public `Tugboat` facade and the capture wiring are later
/// slices. Main thread only.
final class SwiftUIAdapter {
  private static let discoveryIntervalUs: Int64 = 250_000

  let gesture: GestureConfig
  private let clock: FactClock
  private let batcher: FactBatcher
  private let resolver: AnchorResolver
  private let screens: ScreenTracker
  private let trackHostingControllers: Bool
  private let center: NotificationCenter
  private lazy var focus = FocusObserver(
    clock: clock,
    emit: { [weak self] in self?.batcher.add($0) },
    requestFrame: { [weak self] in self?.batcher.requestFrame() }
  )
  private lazy var scroll = ScrollObserver(
    clock: clock,
    anchorFor: { [weak self] view in view.window.flatMap { self?.resolver.anchor(for: view, in: $0) } },
    emit: { [weak self] in self?.batcher.add($0) },
    requestFrame: { [weak self] in self?.batcher.requestFrame() }
  )
  private let hostingControllers = HostingControllerTracker.shared
  /// One recognizer per observed window. Entries whose window is gone are
  /// dropped on the next attach.
  private struct Attachment {
    weak var window: UIWindow?
    let recognizer: WindowPointerRecognizer
  }

  private var attachments: [ObjectIdentifier: Attachment] = [:]
  private var keyWindowToken: NSObjectProtocol?
  private var nextDiscoveryMonoUs = Int64.min
  private(set) var isStarted = false

  init(
    sink: FactSink,
    hostClock: HostClock = SystemHostClock(),
    frames: FrameScheduler = DisplayLinkFrames(),
    gesture: GestureConfig = .uiKitDefault,
    trackHostingControllers: Bool = true,
    accessibilityIdentity: SwiftUIAccessibilityIdentity = .off,
    screens: ScreenTracker = .shared,
    tags: TagRegistry = .shared,
    center: NotificationCenter = .default
  ) {
    self.clock = FactClock(clock: hostClock)
    self.batcher = FactBatcher(sink: sink, frames: frames)
    self.gesture = gesture
    self.screens = screens
    // `.off` builds no source at all: the tree is never read.
    let accessibility = accessibilityIdentity == .off ? nil : AccessibilityIdentitySource(mode: accessibilityIdentity)
    self.resolver = AnchorResolver(tags: tags, screens: screens, accessibility: accessibility)
    self.trackHostingControllers = trackHostingControllers
    self.center = center
    batcher.onFrame { [weak self] in self?.onFrame() }
  }

  /// Starts observing: the current key window, every window that becomes
  /// key later, focus, screens. Idempotent.
  func start() {
    guard !isStarted else { return }
    isStarted = true
    screens.beginSession()
    hostingControllers.beginSession()
    screens.settle()
    seedSessionStartNavigation()
    screens.isRecording = true
    hostingControllers.isRecording = true
    screens.onEvent = { [weak self] in self?.batcher.requestFrame() }
    focus.start(center: center)
    keyWindowToken = center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: nil) { [weak self] note in
      guard let window = note.object as? UIWindow else { return }
      self?.attach(to: window)
    }
    if trackHostingControllers {
      ViewControllerAppearance.observer = { [weak self] controller, appeared in
        self?.hostingControllers.controller(controller, appeared: appeared)
      }
      ViewControllerAppearance.install()
    }
    SwiftUIAdapter.keyWindows().forEach(attach(to:))
  }

  /// Detaches from every window and posts what is pending.
  func stop() {
    guard isStarted else { return }
    isStarted = false
    if let token = keyWindowToken {
      center.removeObserver(token)
    }
    keyWindowToken = nil
    focus.stop(center: center)
    if trackHostingControllers {
      ViewControllerAppearance.observer = nil
    }
    for attachment in attachments.values {
      attachment.window?.removeGestureRecognizer(attachment.recognizer)
    }
    attachments.removeAll()
    scroll.stop()
    // The last flush still collects screen facts; recording stops after it.
    batcher.close()
    screens.isRecording = false
    hostingControllers.isRecording = false
    screens.onEvent = nil
  }

  private func seedSessionStartNavigation() {
    let at = clock.now()
    if let fact = screens.sessionStartFact(at: at) {
      batcher.add(fact)
    }
    if trackHostingControllers, let fact = hostingControllers.sessionStartFact(at: at) {
      batcher.add(fact)
    }
  }

  /// Mask rectangles for `window` under `allTextAndMedia`; called on the
  /// main thread per `capture.request`.
  func masks(for window: UIWindow) -> MaskResult {
    WindowMasks.compute(window)
  }

  /// Observes `window`'s touches and scroll views. Once per window.
  func attach(to window: UIWindow) {
    attachments = attachments.filter { $0.value.window != nil }
    guard isStarted, attachments[ObjectIdentifier(window)]?.window !== window else { return }
    let builder = PointerFactBuilder(clock: clock, gesture: gesture) { [weak self, weak window] point in
      guard let self = self, let window = window else { return .failed(.resolutionError) }
      return self.resolver.tapEvidence(in: window, at: point)
    }
    let recognizer = WindowPointerRecognizer(
      onSample: { [weak self, weak window] sample in
        guard let self = self else { return }
        if sample.phase == .began, let window = window {
          self.scroll.observe(at: sample.location, in: window)
          self.discoverScrollViews(in: window)
        }
        builder.facts(for: sample).forEach(self.batcher.add)
      },
      onReset: { [weak self] in
        builder.cancelAll().forEach { self?.batcher.add($0) }
      }
    )
    window.addGestureRecognizer(recognizer)
    attachments[ObjectIdentifier(window)] = Attachment(window: window, recognizer: recognizer)
    scroll.discover(in: window)
  }

  private func discoverScrollViews(in window: UIWindow) {
    let now = clock.now().monoUs
    guard now >= nextDiscoveryMonoUs else { return }
    nextDiscoveryMonoUs = now.addingReportingOverflow(SwiftUIAdapter.discoveryIntervalUs).partialValue
    scroll.discover(in: window)
  }

  private func onFrame() {
    let navigation = screens.takeFacts() + hostingControllers.takeFacts()
    navigation.forEach(batcher.add)
    if !navigation.isEmpty {
      // A screen came or went: find its scroll views before a finger does.
      attachments.values.compactMap { $0.window }.forEach(scroll.discover(in:))
    }
    focus.onFrame()
    scroll.onFrame()
  }

  private static func keyWindows() -> [UIWindow] {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .filter { $0.isKeyWindow }
  }
}
#endif
