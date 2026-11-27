#if canImport(UIKit)
import UIKit

/// What `AccessibilityIdentitySource` asks the OS and the main queue; tests
/// replace each part.
struct AccessibilityEnvironment {
  /// The running iOS major.
  var osMajor: () -> Int
  /// VoiceOver or Switch Control is running, so the tree already exists.
  var assistiveClientRunning: () -> Bool
  /// A uniform value in 0..<1, for `.sampled`.
  var draw: () -> Double
  /// Runs the work on the main queue's next turn.
  var nextTurn: (@escaping () -> Void) -> Void
  /// Builds the tree in-process: `accessibilityActivate()` on a hosting view.
  var activate: (UIView) -> Void

  static let live = AccessibilityEnvironment(
    osMajor: { ProcessInfo.processInfo.operatingSystemVersion.majorVersion },
    assistiveClientRunning: { UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning },
    draw: { Double.random(in: 0..<1) },
    nextTurn: { DispatchQueue.main.async(execute: $0) },
    activate: { _ = $0.accessibilityActivate() }
  )
}

/// What `AnchorResolver` asks for the accessibility element at an untagged
/// tap (ADR 0010); nil keeps today's result.
protocol AccessibilityLeafSource: AnyObject {
  func leaf(at point: CGPoint, in window: UIWindow, root: UIView) -> AccessibilityLeaf?
}

/// The accessibility-tree refinement of an untagged SwiftUI tap (ADR 0010),
/// asked by `AnchorResolver` only for a tap that has no target or lands on a
/// list cell or scroll view with no control under it.
///
/// - **Gate.** `.off` answers nil without asking the OS anything, so the
///   tree is never read, even with VoiceOver running. Otherwise the iOS
///   major must be in `verifiedMajors` (elsewhere: as `.off`, logged once),
///   and `.sampled` must be drawn in (once per process,
///   `AccessibilityProcessState`).
/// - **Activation.** The first qualifying tap of a process schedules
///   `accessibilityActivate()` on its hosting view for the main queue's next
///   turn, after the touch sequence, and is answered nil: it resolves as
///   with the option off. Once per process, across sessions. When VoiceOver
///   or Switch Control is running the tree exists: no activation, the tap
///   reads it.
/// - **Reading.** `AccessibilityTreeReader`, from the tap's hosting view.
///
/// Main thread only.
final class AccessibilityIdentitySource: AccessibilityLeafSource {
  /// iOS majors where the tree and its cost were measured (ADR 0010: iPhone
  /// 12, iOS 18.6.2). Widened only after the iOS 17 and 26 device re-measure.
  static let verifiedMajors: Set<Int> = [18]

  private let mode: SwiftUIAccessibilityIdentity
  private let environment: AccessibilityEnvironment
  private let process: AccessibilityProcessState
  private let reader: AccessibilityTreeReader
  private lazy var isEnabled = computeEnabled()

  init(
    mode: SwiftUIAccessibilityIdentity,
    environment: AccessibilityEnvironment = .live,
    process: AccessibilityProcessState = .shared,
    reader: AccessibilityTreeReader = AccessibilityTreeReader()
  ) {
    self.mode = mode
    self.environment = environment
    self.process = process
    self.reader = reader
  }

  /// The element at `point` (window points) under `root`, the tap's hosting
  /// view, or nil for today's result.
  func leaf(at point: CGPoint, in window: UIWindow, root: UIView) -> AccessibilityLeaf? {
    guard isEnabled else { return nil }
    if process.activation == .done || environment.assistiveClientRunning() {
      let screen = window.screen.coordinateSpace
      return reader.leaf(at: point, under: root) { window.convert($0, from: screen) }
    }
    if process.activation == .none {
      scheduleActivation(of: root)
    }
    return nil
  }

  private func scheduleActivation(of root: UIView) {
    process.activation = .scheduled
    let environment = self.environment
    let process = self.process
    environment.nextTurn { [weak root] in
      // Gone before its turn: a later qualifying tap tries again.
      guard let root = root, root.window != nil else {
        process.activation = .none
        return
      }
      environment.activate(root)
      process.activation = .done
      HostLog.debug("SwiftUI accessibility tree activated for this process (ADR 0010)")
    }
  }

  private func computeEnabled() -> Bool {
    if mode == .off {
      return false
    }
    let major = environment.osMajor()
    guard AccessibilityIdentitySource.verifiedMajors.contains(major) else {
      AdapterLog.once(
        "accessibility-identity",
        "swiftUIAccessibilityIdentity is not verified on iOS \(major) (ADR 0010) and behaves as .off")
      return false
    }
    switch mode {
    case .off: return false
    case .on: return true
    case let .sampled(rate): return process.isSampledIn(rate: rate, draw: environment.draw)
    }
  }
}
#endif
