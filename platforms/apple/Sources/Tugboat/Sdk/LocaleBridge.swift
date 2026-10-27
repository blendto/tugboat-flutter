import Foundation

/// Posts `locale.set` when the app's locale changes
/// (`NSLocale.currentLocaleDidChangeNotification`), with the same locale
/// object as `session.start.locale`, skipping a locale equal to the last
/// one sent (the session's start locale at first). The engine records
/// `locale_changed`. Locale is evidence, never identity.
///
/// The observer exists only from session start to session end: `start` adds
/// it and `stop` removes it, so a dormant SDK observes nothing. Main thread
/// only; a notification posted on another thread is handled on main.
final class LocaleBridge {
  private let center: NotificationCenter
  private let read: () -> LocaleSnapshot
  private let post: (_ inputJSON: String) -> Void
  private var token: NSObjectProtocol?
  private var last: LocaleSnapshot

  init(
    center: NotificationCenter = .default,
    initial: LocaleSnapshot,
    read: @escaping () -> LocaleSnapshot = { LocaleSnapshot.of(Locale.autoupdatingCurrent) },
    post: @escaping (_ inputJSON: String) -> Void
  ) {
    self.center = center
    self.last = initial
    self.read = read
    self.post = post
  }

  var isObserving: Bool {
    token != nil
  }

  func start() {
    guard token == nil else { return }
    token = center.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil) {
      [weak self] _ in
      if Thread.isMainThread {
        self?.localeMayHaveChanged()
      } else {
        DispatchQueue.main.async { self?.localeMayHaveChanged() }
      }
    }
  }

  func stop() {
    guard let token = token else { return }
    center.removeObserver(token)
    self.token = nil
  }

  func localeMayHaveChanged() {
    guard token != nil else { return }
    let locale = read()
    guard locale != last, !locale.language.isEmpty else { return }
    last = locale
    post(SessionMessages.localeSetInput(locale))
  }
}
