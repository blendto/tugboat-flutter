/// One route on a navigator: a `.tugboatScreen` instance, or a hosting
/// controller. `instanceId` is opaque and stable for the instance's
/// lifetime; `name` is the route name the engine reports (the screen name,
/// or the hashed hosting-controller key); `type` is the route type.
struct RouteEntry: Equatable {
  let instanceId: String
  let name: String?
  let type: String
}
