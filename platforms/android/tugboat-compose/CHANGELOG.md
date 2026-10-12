# tugboat-compose

## 0.1.0

Unpublished. The Jetpack Compose adapter for the native Android SDK.

- Public API: `TugboatCompose.install()` (the SDK facade's entry point) and
  `Modifier.tugboatTag(...)`.
- Registers a Compose region with `tugboat-android`'s toolkit-region seam,
  read through `ViewRootForTest.semanticsOwner` (`runCatching`).
- Identity: semantics hit-test at the down position, role tokens,
  `[item:n]` from `CollectionItemInfo` or traversal order, paths below the
  host's Views path, `tugboatTag` / `testTag` aliases, route keys from the
  `trackNavigation` route pattern without arguments, `toolkit: "compose"`.
  Text is never in identity.
- Masks under `allTextAndMedia`: text, editable text, `Role.Image`, and
  content-description nodes; `AndroidView` interop bounds fail-closed; the
  whole frame when the semantics owner is unavailable.
- Scroll facts by per-frame diff of semantics scroll ranges during and
  after gestures (approximate offsets); `focus` from the focused editable
  node.
- Compiled against Compose UI 1.7.0; tested on 1.7.x and 1.8.x.
