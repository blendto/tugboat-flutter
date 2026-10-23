/// How a `.tugboatScreen` is presented, reported as the route's
/// `overlayKind`. A non-page screen shown over another screen of the same
/// navigator is recorded as presented over it (`presentedOverRoute`), with
/// the nearest page below as its host page.
public enum TugboatScreenPresentation: Equatable, Sendable {
  /// Tugboat decides. Today it is `.page`; a later release may read the
  /// presentation from UIKit. Pass an explicit value to keep a screen's
  /// route identity fixed.
  case automatic
  /// A full screen: a `NavigationStack` destination, a tab, or a full-screen
  /// cover.
  case page
  /// A `.sheet` (also a popover that iPhone shows as a sheet, if you prefer
  /// `.sheet` to `.popup` for it).
  case sheet
  /// An alert or confirmation dialog the app draws as a screen.
  case dialog
  /// A popover or another small overlay.
  case popup
}

extension TugboatScreenPresentation {
  /// The route's `overlayKind`; `.automatic` is `page` in this release.
  var overlayKind: OverlayKind {
    switch self {
    case .automatic, .page: return .page
    case .sheet: return .sheet
    case .dialog: return .dialog
    case .popup: return .popup
    }
  }
}
