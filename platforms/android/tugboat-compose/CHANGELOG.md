# tugboat-compose

## 0.1.0

Unpublished. The Jetpack Compose adapter for the native Android SDK.

- Public API: `TugboatCompose.install(composeMasking)` (the SDK facade's
  entry point), `ComposeMasking`, and `Modifier.tugboatTag(...)`.
- Registers a Compose region with `tugboat-android`'s toolkit-region seam,
  read through `ViewRootForTest.semanticsOwner` (`runCatching`).
- Masks under `allTextAndMedia`: every Compose host whole by default
  (`ComposeMasking.WholeHost`). The opt-in `SemanticsBestEffort` masks
  text, editable text, `Role.Image`, and content-description nodes, and
  `AndroidView` interop bounds fail-closed; it leaves content without
  semantics unmasked (documented) and is ignored outside the tested Compose
  UI range. The whole frame when the semantics owner is unavailable.
- Identity: semantics hit-test at the down position, role tokens,
  `[item:n]` from `CollectionItemInfo` (`[item]` without it), paths below
  the host's Views path, `tugboatTag` / `testTag` aliases, the Views route
  key, `toolkit: "compose"`. Text is never in identity.
- Scroll facts from the scrollables under the touch, read live per frame
  during and after gestures (approximate offsets); `focus` from the focused
  editable node.
- Compose UI is `compileOnly` (floor 1.7.0); tested on 1.7.0 and 1.8.3.
