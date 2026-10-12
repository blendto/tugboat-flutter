#if canImport(UIKit)
import UIKit

/// Scroll facts from KVO on `UIScrollView.contentOffset` (native SDK note
/// section 5; SwiftUI `ScrollView` and `List` are backed by scroll views).
///
/// - `discover(in:)` finds the scroll views of a window and observes each
///   once. The adapter runs it when it attaches to a window and on pointer
///   down (at most every 250 ms), so a scroll view is known before the
///   finger moves it.
/// - KVO marks a view dirty and requests a frame. On the frame, a first
///   move sends `start` (at the resting offset, with the scroll view's
///   anchor), then `update` with the latest offset (one per frame, at the
///   time of the last change); an offset past either end sends one
///   `overscroll` per scroll.
/// - A scroll ends on the first frame where no finger or momentum drives
///   the view (`isTracking` / `isDragging` / `isDecelerating`) and the
///   offset has not changed for `idleMs`, which also ends programmatic and
///   animated scrolls.
/// - Inset changes alone are not scrolls (offsets are relative to the
///   resting start). Text views are not observed: their offset follows the
///   caret.
///
/// Main thread only.
final class ScrollObserver {
  static let defaultIdleMs: Int64 = 100
  private static let maxDiscoveredViews = 4000

  private final class Tracked {
    weak var view: UIScrollView?
    var observation: NSKeyValueObservation?
    var resting: CGPoint
    var axis: ScrollAxis = .vertical
    var active = false
    var overscrolled = false
    var firstChangeAt: HostTime?
    var lastChangeAt: HostTime?
    /// When the last reported move happened.
    var lastMoveMonoUs: Int64 = 0

    init(view: UIScrollView) {
      self.view = view
      self.resting = ScrollViewReading.relativeOffset(of: view)
    }
  }

  private let clock: FactClock
  private let anchorFor: (UIScrollView) -> TargetAnchor?
  private let emit: (AdapterFact) -> Void
  private let requestFrame: () -> Void
  private let idleUs: Int64
  private var tracked: [ObjectIdentifier: Tracked] = [:]

  init(
    clock: FactClock,
    anchorFor: @escaping (UIScrollView) -> TargetAnchor?,
    emit: @escaping (AdapterFact) -> Void,
    requestFrame: @escaping () -> Void,
    idleMs: Int64 = ScrollObserver.defaultIdleMs
  ) {
    self.clock = clock
    self.anchorFor = anchorFor
    self.emit = emit
    self.requestFrame = requestFrame
    self.idleUs = idleMs.multipliedReportingOverflow(by: 1000).overflow ? Int64.max : idleMs * 1000
  }

  var observedCount: Int {
    tracked.values.filter { $0.view != nil }.count
  }

  /// Starts observing every visible scroll view under `root` not yet seen.
  func discover(in root: UIView) {
    var stack: [UIView] = [root]
    var visited = 0
    while let view = stack.popLast(), visited < ScrollObserver.maxDiscoveredViews {
      visited += 1
      guard !ViewTree.isInvisibleForMasks(view) else { continue }
      if let scrollView = view as? UIScrollView, !(view is UITextView) {
        observe(scrollView)
      }
      stack.append(contentsOf: view.subviews.reversed())
    }
  }

  /// Sends the facts due this frame.
  func onFrame() {
    let now = clock.now()
    var anyActive = false
    for (key, state) in tracked {
      guard let view = state.view else {
        state.observation?.invalidate()
        tracked[key] = nil
        continue
      }
      report(view, state)
      if state.active {
        anyActive = !endIfIdle(view, state, now: now) || anyActive
      }
    }
    if anyActive {
      requestFrame()
    }
  }

  /// Stops observing; scrolls in progress end now.
  func stop() {
    let now = clock.now()
    for state in tracked.values {
      if let view = state.view, state.active {
        emitEnd(view, state, at: now)
      }
      state.observation?.invalidate()
    }
    tracked.removeAll()
  }

  private func observe(_ view: UIScrollView) {
    let key = ObjectIdentifier(view)
    if let existing = tracked[key], existing.view === view {
      return
    }
    let state = Tracked(view: view)
    state.observation = view.observe(\.contentOffset, options: []) { [weak self] observed, _ in
      self?.offsetChanged(ObjectIdentifier(observed))
    }
    tracked[key] = state
  }

  private func offsetChanged(_ key: ObjectIdentifier) {
    guard let state = tracked[key] else { return }
    let now = clock.now()
    if state.firstChangeAt == nil {
      state.firstChangeAt = now
    }
    state.lastChangeAt = now
    requestFrame()
  }

  /// Sends `start` / `update` / `overscroll` for changes since the last frame.
  private func report(_ view: UIScrollView, _ state: Tracked) {
    guard let changedAt = state.lastChangeAt else { return }
    let startedAt = state.firstChangeAt ?? changedAt
    state.firstChangeAt = nil
    state.lastChangeAt = nil
    let id = ScrollViewReading.id(of: view)
    if !state.active {
      guard ScrollViewReading.hasMoved(view, from: state.resting) else { return }
      state.axis = ScrollViewReading.axis(of: view, from: state.resting)
      state.active = true
      let resting = ScrollViewReading.metrics(of: view, axis: state.axis, at: state.resting)
      emit(ScrollFacts.fact(id: id, phase: .start, metrics: resting, at: startedAt, anchor: anchorFor(view)))
    }
    let metrics = ScrollViewReading.metrics(of: view, axis: state.axis)
    emit(ScrollFacts.fact(id: id, phase: .update, metrics: metrics, at: changedAt))
    state.lastMoveMonoUs = changedAt.monoUs
    if ScrollViewReading.isOverscrolled(metrics), !state.overscrolled {
      state.overscrolled = true
      emit(ScrollFacts.fact(id: id, phase: .overscroll, metrics: metrics, at: changedAt))
    }
    state.resting = ScrollViewReading.relativeOffset(of: view)
  }

  /// Ends an idle scroll; true when it ended.
  private func endIfIdle(_ view: UIScrollView, _ state: Tracked, now: HostTime) -> Bool {
    let (idleFor, overflow) = now.monoUs.subtractingReportingOverflow(state.lastMoveMonoUs)
    guard !ScrollViewReading.isUserDriven(view), overflow || idleFor >= idleUs else { return false }
    state.active = false
    state.overscrolled = false
    state.resting = ScrollViewReading.relativeOffset(of: view)
    emitEnd(view, state, at: now)
    return true
  }

  private func emitEnd(_ view: UIScrollView, _ state: Tracked, at: HostTime) {
    let metrics = ScrollViewReading.metrics(of: view, axis: state.axis)
    emit(ScrollFacts.fact(id: ScrollViewReading.id(of: view), phase: .end, metrics: metrics, at: at))
  }
}
#endif
