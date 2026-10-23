#if canImport(UIKit)
import QuartzCore
import UIKit

/// The main run loop's display frames: one `CADisplayLink`, paused while no
/// callback is armed so an idle app pays nothing. Main thread only.
final class DisplayLinkFrames: FrameScheduler {
  /// `CADisplayLink` retains its target; the proxy breaks the cycle.
  private final class Proxy: NSObject {
    weak var owner: DisplayLinkFrames?

    @objc func tick() {
      owner?.tick()
    }
  }

  private let proxy = Proxy()
  private var link: CADisplayLink?
  private var callbacks: [() -> Void] = []

  init() {
    proxy.owner = self
  }

  deinit {
    link?.invalidate()
  }

  func scheduleFrame(_ callback: @escaping () -> Void) {
    callbacks.append(callback)
    displayLink().isPaused = false
  }

  func invalidate() {
    callbacks.removeAll()
    link?.invalidate()
    link = nil
  }

  private func displayLink() -> CADisplayLink {
    if let link = link {
      return link
    }
    let created = CADisplayLink(target: proxy, selector: #selector(Proxy.tick))
    created.isPaused = true
    created.add(to: .main, forMode: .common)
    link = created
    return created
  }

  private func tick() {
    link?.isPaused = true
    let due = callbacks
    callbacks.removeAll()
    for callback in due {
      callback()
    }
  }
}
#endif
