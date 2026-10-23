/// Engine `route.overlayKind` values (stateful-engine.md 8.1; Dart
/// `TugboatOverlayKind`). A non-page route pushed on a navigator that
/// already shows a route is presented over it (`presentedOver*`).
enum OverlayKind: String {
  case page
  case sheet
  case dialog
  case popup
}

/// One route on a navigator: a `.tugboatScreen` instance, or a hosting
/// controller. `instanceId` is opaque and stable for the instance's
/// lifetime; `name` is the route name the engine reports (the screen name,
/// or the hashed hosting-controller key); `type` is the route type;
/// `overlayKind` is how it is presented (`page` unless the screen says
/// otherwise).
struct RouteEntry: Equatable {
  let instanceId: String
  let name: String?
  let type: String
  let overlayKind: OverlayKind

  init(instanceId: String, name: String?, type: String, overlayKind: OverlayKind = .page) {
    self.instanceId = instanceId
    self.name = name
    self.type = type
    self.overlayKind = overlayKind
  }
}
