# Changelog

## 0.0.3

- Anchors match Flutter (needs the `tugboat-android` of this tree): a `Switch` reports role
  `switch`, a text field reports actions `["input"]`, and a `testID` containing `%`, `#` or `/` is
  percent-escaped in the canonical path.
- Taps carry `routeKey`, as in the Flutter SDK (needs the `tugboat-android` of this tree).
- One initial route: the activity is no longer a route of its own, so the first
  route is the first screen named by `setScreen` / `trackNavigation` (it was the
  activity, then that screen). An app that never names a screen reports no routes.

## 0.0.2

- Early start: a content provider installs activity observation before the first
  activity, so frames and `session_start` begin at cold launch.
- `Tugboat.setScreen(name, instanceId?)` and `Tugboat.trackNavigation(navigationRef)`:
  one `route_change` per navigation, named by the focused route path.
- `testID` is the view's tag and fingerprint name; `react-native-screens`
  fragments produce no routes of their own.

## 0.0.1

- First Android-only build: start, activate, `Sensitive`, network capture.
