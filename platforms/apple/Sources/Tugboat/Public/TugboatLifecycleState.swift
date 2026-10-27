/// Where Tugboat's capture lifecycle is (`Tugboat.lifecycleState`), with
/// the names Flutter's `TugboatLifecycleState` uses on the wire and in
/// `TUGBOAT_HEALTH`.
///
/// - `dormant`: no session; nothing is installed or recorded.
/// - `starting`: a session was requested (`activate`, or `start` with
///   `enabled: true`) and is being set up. Also the state after an
///   `activate` that came before `start`, until `start` runs it.
/// - `active`: a session is running.
/// - `stopping`: `deactivate` or `stop` was called and the session is
///   ending; `dormant` once `session.end` has been posted. Switching to a
///   new activation id goes from `active` to `starting`, never through
///   `stopping`.
public enum TugboatLifecycleState: String, Sendable {
  case dormant
  case starting
  case active
  case stopping
}
