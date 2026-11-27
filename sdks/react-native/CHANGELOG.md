# Changelog

## 0.0.3

- Taps carry `routeKey`, as in the Flutter SDK (needs the `tugboat-android` of this tree).
- One initial route: the first screen named by `setScreen` / `trackNavigation` is the
  session's initial route (`session_start`); the activity is no longer a route of its
  own. An app that never names a screen reports no routes.

## 0.0.2

- Early start: a content provider installs activity observation before the first
  activity, so frames and `session_start` begin at cold launch.
- `Tugboat.setScreen(name, instanceId?)` and `Tugboat.trackNavigation(navigationRef)`:
  one `route_change` per navigation, named by the focused route path.
- `testID` is the view's tag and fingerprint name; `react-native-screens`
  fragments produce no routes of their own.

## 0.0.1

- First Android-only build: start, activate, `Sensitive`, network capture.
