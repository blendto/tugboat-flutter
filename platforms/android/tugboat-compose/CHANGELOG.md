# tugboat-compose

## 0.1.0

Unpublished. The Jetpack Compose adapter for the native Android SDK.

- Public API: `TugboatCompose.install(composeMasking)` (the app calls once
  when it ships this module), `ComposeMasking`, and `Modifier.tugboatTag(...)`.
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
- `ToolkitRegion.inventory` enumerates kept semantics nodes for native
  `scene.inventory` (both masking modes).
- Compose UI is `compileOnly` (floor 1.7.0); tested on 1.7.0 and 1.8.3.
- `Modifier.tugboatTag(tag, accessibility = false)`: `accessibility = true`
  also sets `testTag(tag)` on the same node, so UI tests find the control
  with `onNodeWithTag(tag)`. Identity (fingerprint, canonical path, alias,
  structure signature) and the node's label, role, and actions are
  unchanged. Off by default: a node keeps one `testTag`, the first in the
  modifier chain, so the option can replace an app's own. Test tools that
  read the accessibility tree see it as a resource-id only under
  `semantics { testTagsAsResourceId = true }`, which Tugboat does not set.
  The one-argument call is source- and binary-compatible (`@JvmOverloads`).
