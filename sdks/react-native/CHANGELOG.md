# Changelog

## 0.0.4

- iOS support. The same `NativeTugboat` spec is implemented over the Swift host
  (`platforms/apple`): `start`, `activate`, `deactivate`, `stop`, `setUserId`,
  `setTraits`, `setScreen`. `<Tugboat.Sensitive>` is a Fabric view that the host
  masks with its whole subtree. `fetch` and `XMLHttpRequest` are recorded through
  a request handler built on `Tugboat.instrumentedSession` (URL path as route,
  once per call). A `testID` is the view's `accessibilityIdentifier`: a named
  view is a tap target, its name the anchor's tag and alias. React Native's text
  and image views are masked whole. JavaScript names every screen: no view
  controller is a route, and the first screen named is the session's initial route
  (`session_start`, with a frame of its own), as on Android and in Flutter.
- The Swift host comes in as local pods (`TugboatSessionEngine`,
  `TugboatCaptureRuntime`, `Tugboat`, from the repository root); see the README.
- Needs the seams added to the Swift host in this tree
  (`TugboatAdapters.setScreen`, `setViewNameProvider`, `setViewRoleClassifier`,
  `markSensitive`).
- Android is unchanged.

## 0.0.3

- Anchors match Flutter (needs the `tugboat-android` of this tree): a `Switch` reports role
  `switch`, a text field reports actions `["input"]`, and a `testID` containing `%`, `#` or `/` is
  percent-escaped in the canonical path.
- Taps carry `routeKey`, as in the Flutter SDK (needs the `tugboat-android` of this tree).
- One initial route: the activity is no longer a route of its own, so the first
  route is the first screen named by `setScreen` / `trackNavigation`, reported as
  the session's initial route (`session_start`, with a frame of that screen), as
  in Flutter (it was the activity, then that screen). An app that never names a
  screen reports no routes.

## 0.0.2

- Early start: a content provider installs activity observation before the first
  activity, so frames and `session_start` begin at cold launch.
- `Tugboat.setScreen(name, instanceId?)` and `Tugboat.trackNavigation(navigationRef)`:
  one `route_change` per navigation, named by the focused route path.
- `testID` is the view's tag and fingerprint name; `react-native-screens`
  fragments produce no routes of their own.

## 0.0.1

- First Android-only build: start, activate, `Sensitive`, network capture.
