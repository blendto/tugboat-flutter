#if canImport(UIKit)
import UIKit

/// `focus {kind}` facts from UIKit's text editing notifications (native SDK
/// note section 5). SwiftUI `TextField`, `SecureField` and `TextEditor` are
/// backed by `UITextField` / `UITextView`, so their begin- and end-editing
/// notifications are the focus signal:
///
/// - begin editing sends `text_input`;
/// - end editing sends `none` on the next frame, unless another field began
///   editing in between (focus moving from one field to the next is one
///   `text_input`, not `none` then `text_input`);
/// - consecutive equal kinds are sent once.
///
/// Main thread only.
final class FocusObserver {
  private let clock: FactClock
  private let emit: (AdapterFact) -> Void
  private let requestFrame: () -> Void
  private var tokens: [NSObjectProtocol] = []
  private var lastKind: String?
  private var pendingNone: HostTime?

  init(clock: FactClock, emit: @escaping (AdapterFact) -> Void, requestFrame: @escaping () -> Void) {
    self.clock = clock
    self.emit = emit
    self.requestFrame = requestFrame
  }

  func start(center: NotificationCenter = .default) {
    guard tokens.isEmpty else { return }
    let began = [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification]
    let ended = [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification]
    for name in began {
      tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
        self?.didBeginEditing()
      })
    }
    for name in ended {
      tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
        self?.didEndEditing()
      })
    }
  }

  func stop(center: NotificationCenter = .default) {
    tokens.forEach { center.removeObserver($0) }
    tokens.removeAll()
    pendingNone = nil
  }

  /// Sends a pending `none` (called once per frame).
  func onFrame() {
    guard let at = pendingNone else { return }
    pendingNone = nil
    send("none", at: at)
  }

  func didBeginEditing() {
    pendingNone = nil
    send("text_input", at: clock.now())
  }

  func didEndEditing() {
    pendingNone = clock.now()
    requestFrame()
  }

  private func send(_ kind: String, at: HostTime) {
    guard kind != lastKind else { return }
    lastKind = kind
    var input = JSONObject()
    input.set("kind", kind)
    emit(AdapterFact(type: FactTypes.focus, input: input, at: at))
  }
}
#endif
