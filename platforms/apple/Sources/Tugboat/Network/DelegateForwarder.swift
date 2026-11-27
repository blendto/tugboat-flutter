#if canImport(ObjectiveC)
import Foundation

/// An Objective-C proxy for the app's `URLSession` delegate.
///
/// URLSession asks its delegate `responds(to:)` for each optional method
/// and then sends the message. This object answers yes for exactly the
/// methods the app's delegate implements, plus the ones a subclass
/// implements to observe (which forward the call themselves), and hands
/// every other message to the app's delegate unchanged
/// (`forwardingTarget(for:)`). So URLSession sees the same set of methods,
/// and makes the same decisions (auth challenges, redirects, caching,
/// response dispositions, download and stream callbacks, background
/// events), as with the app's delegate alone.
///
/// The app's delegate is held strongly, as URLSession holds its delegate:
/// it is released when the session is invalidated and releases this proxy.
class DelegateForwarder: NSObject {
  /// The app's delegate; nil when it passed none.
  let target: NSObjectProtocol?

  init(target: NSObjectProtocol?) {
    self.target = target
    super.init()
  }

  override func responds(to aSelector: Selector!) -> Bool {
    if super.responds(to: aSelector) {
      return true
    }
    return target?.responds(to: aSelector) ?? false
  }

  override func forwardingTarget(for aSelector: Selector!) -> Any? {
    if let target = target, target.responds(to: aSelector) {
      return target
    }
    return super.forwardingTarget(for: aSelector)
  }

  override func conforms(to aProtocol: Protocol) -> Bool {
    super.conforms(to: aProtocol) || (target?.conforms(to: aProtocol) ?? false)
  }
}
#endif
