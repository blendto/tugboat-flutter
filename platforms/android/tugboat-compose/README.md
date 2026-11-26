# tugboat-compose

Jetpack Compose adapter for the native Android SDK
([ADR 0009](../../../docs/decisions/0009-shared-session-engine.md)).
Maven coordinates `com.gettugboat.sdk:tugboat-compose:0.1.0`, namespace
`com.tugboat.android.compose`, minSdk 24. Versioned on its own (ADR 0008, see
[CHANGELOG](CHANGELOG.md)) and unpublished: the only repository is the
untracked `.local-maven`.

It is a separate artifact so Views-only apps do not pull in Compose. It
depends on `tugboat-android`; Compose UI is `compileOnly` (the app ships
it).

## Public API

| API | Use |
| --- | --- |
| `TugboatCompose.install(composeMasking = ComposeMasking.WholeHost)` | The app must call once when it ships this module (for example from `Application.onCreate`, after `Tugboat.start` — see `tugboat-sample`). Registers the Compose region with the Views adapter. Without it, each `AndroidComposeView` is fail-closed: masked over its whole bounds and not read for semantics identity. Installing again replaces the choice. Never throws. |
| `ComposeMasking` | `WholeHost` (default) or `SemanticsBestEffort` (below). |
| `Modifier.tugboatTag("checkout", accessibility = false)` | Developer alias, like `View.tugboatTag`. A high-confidence `tagFingerprint`; the structural fingerprint is unchanged. `accessibility = true` also sets `testTag` (below). |
| `Modifier.tugboatSensitive()` | Always masks this element's bounds, and every semantics node laid out inside it at its own bounds, including under `SemanticsBestEffort`. It adds no semantics node: taps, paths, list items, scroll targets, inventory, and fingerprints are unchanged, and `clearAndSetSemantics` cannot remove it. Remove the modifier to stop masking. |

### Tags in UI tests

`Modifier.tugboatTag(tag, accessibility = true)` also sets `testTag(tag)` on
the same node, so one id serves Tugboat and UI tests: `onNodeWithTag(tag)`
finds the merged control (a `Button` with its `Text`), in the merged and the
unmerged tree. Tugboat identity (fingerprint, canonical path, alias,
structure signature) is the same as without it, and so are the node's
label, role, and actions. An empty tag sets nothing.

- Tag the control itself. `testTag` does not merge up, so on a child of a
  merged control (a `Text` inside a `Button`) it stays on the child and is
  found only with `useUnmergedTree = true`; the Tugboat alias still goes to
  the merged control.
- Test tools that read the accessibility tree (Maestro, Appium,
  UiAutomator) see a `testTag` as a resource-id only under an ancestor with
  `Modifier.semantics { testTagsAsResourceId = true }`. Tugboat does not
  set it; the app opts in.
- It is off by default because a node keeps one `testTag`, the one first in
  the modifier chain:

  | Modifier chain | `testTag` in the semantics tree | Tugboat alias |
  | --- | --- | --- |
  | `.testTag("app").tugboatTag("pay", accessibility = true)` | `app` | `pay` |
  | `.tugboatTag("pay", accessibility = true).testTag("app")` | `pay` (the app's tag is gone) | `pay` |

  Keep `accessibility = false` on nodes that already have a `testTag`.

## Masking

Under `allTextAndMedia`:

| `ComposeMasking` | What is masked |
| --- | --- |
| `WholeHost` (default) | Every Compose host (each `ComposeView`, `setContent`) over its whole bounds. Nothing Compose draws can leak. |
| `SemanticsBestEffort` (opt-in) | Only what the semantics tree describes: `Text` and `EditableText` nodes (password fields included), `Role.Image`, nodes with a content description, and `AndroidView` interop bounds (fail-closed). The whole frame when the semantics owner is unavailable. |

**Residual leak of `SemanticsBestEffort`.** Content without semantics is
not masked and is captured as drawn:

- `Image`, `Icon`, and `AsyncImage` with `contentDescription = null`;
- `drawText`, and anything drawn on a `Canvas`, in `drawBehind` /
  `drawWithContent`, or by `Modifier.paint`.

Opt in only for apps whose screens draw nothing private that way. Outside
the tested Compose UI range (below) the opt-in is ignored and hosts are
masked whole. Identity, scroll, and focus are the same in both modes.

Every capture reports which masking applied: `WindowMasks` returns a
`MaskCoverage {mode: precise | wholeHost | wholeFrame, reasons}`
(`composeDefault`, `composeVersionUnverified`, `composeOwnerUnavailable`,
`interop`, ...) that the host forwards on `capture.result`.

Mask bounds are the union of a node's semantics bounds and the unclipped
root bounding box of its layout coordinates, so `graphicsLayer` transforms
and content drawn outside a non-clipping parent are covered. Compose lays
out every frame, so masks follow animations.

## How it plugs into the Views adapter

`tugboat-android`'s Views adapter owns the window: the single
`Window.Callback` wrapper (pointer and key facts), batching, hashing, route
keys, and mask normalization. Compose content lives inside one View, the
`AndroidComposeView`. This module implements the adapter's
**toolkit-region seam** (`com.tugboat.android.toolkit.ToolkitRegion`,
opt-in `@TugboatToolkitApi`, see the `tugboat-android` README):

| Seam call | Compose answer |
| --- | --- |
| `targetAt` | Semantics hit-test at the **down** position: the nearest actionable node, else the nearest kept node. A point on `AndroidView` interop is a `Miss`, so the Views rules resolve the interop View. |
| `masks` | Per `ComposeMasking` and the version gate, above. |
| `scrollablesAt` | The nodes with a `ScrollAxisRange` under the touch, resolved once per gesture; their ranges read live state, so frames read offsets without walking the tree. |
| `focus` | `TextInput` when a focused node is editable. |
| `inventory` | Kept semantics nodes for `scene.inventory`, with their tap targets and paths (both masking modes; unindexed lazy items collapse to one `[item]` entry; large text is measured against the window). At most `limit` entries; the rest are counted. |

The region keeps no listeners; the Views adapter drives it, so it is inert
once the adapter stops.

## Identity

`docs/design/capture-and-fingerprint.md`, "Compose canonicalization":

- Source: the merged semantics tree from `ViewRootForTest.semanticsOwner`,
  reached through `runCatching` (the only Compose internal used).
- Token: `Role` (`Button`, `Checkbox`, `Switch`, `RadioButton`, `Tab`,
  `Image`, `DropdownList`), then `TextField`, `Scrollable`, `Node`.
- Path: the host's Views path (the host is the token `Compose`) followed by
  the node path, for example `Compose#0/Scrollable#0/[item:3]/Node#0`.
- Lists: `[item:<CollectionItemInfo index>]`; without it (lazy layouts set
  none) `[item]`, at `low` confidence, because the order on screen changes
  as the list scrolls. Set `Modifier.semantics { collectionItemInfo = ... }`
  or a `tugboatTag` for distinct rows.
- Route key: the host's Views route: the `trackNavigation` route pattern
  without arguments (`checkout/{id}?step={s}` is `checkout`, normalized
  once by the Views adapter for every toolkit), else the hosting activity
  (or the fragment around a `ComposeView`).
- Alias: `Modifier.tugboatTag`, then `testTag`. Text is never in identity.
- `toolkit: "compose"`. If the semantics owner cannot be reached, a tap
  anchors the hosting View (`Compose#0`, still `compose`).

## Compose versions

| | Compose UI |
| --- | --- |
| Compiled against (`compileOnly`, floor) | 1.7.0 |
| Tested range (runtime gate) | 1.7.0 up to, not including, 1.9.0 |
| CI | 1.8.3 (BOM `2025.06.01`) and 1.7.0 (BOM `2024.09.00`) |

`compileOnly` keeps this module from upgrading an app's Compose. The
runtime gate reads `META-INF/androidx.compose.ui_ui.version`, which every
Compose UI release ships (Android Studio's Layout Inspector reads it too).
A version outside the range, or an app that strips that file, masks every
host whole and ignores the opt-in. Any other failure falls back as
described above, never to an unmasked frame.

## Navigation hook

There is no Navigation Compose dependency. The SDK facade's
`Tugboat.trackNavigation(navController)` registers
`navController.addOnDestinationChangedListener` and passes
`destination.route` to the Views adapter's `onDestinationChanged`, whose
`DestinationTracker` strips the arguments.

## Known gaps

- Scroll offsets are per-frame samples, so they are approximate. Lazy
  layouts report Compose's own estimate (500 per item plus the first item's
  pixel offset) and no extent. Scrolls without a touch (wheel,
  programmatic) and overscroll are not reported.
- Lazy rows without `CollectionItemInfo` share one structural fingerprint.
  Items without a semantics node of their own (a `Row` of a text and a
  button) are separate children of the list.
- Interop masking tells Compose's own views apart by package name; the
  consumer R8 rules keep those names. A renamed class over-masks.
- Compose dialogs and popups are separate windows, which the Views adapter
  does not wrap (the same gap as Views dialogs).

## Build and test

From `platforms/android`:

```sh
./gradlew :tugboat-compose:test                                   # region-level tests
./gradlew :tugboat-android:test --tests 'com.tugboat.android.views.compose.*'  # end to end
./gradlew :tugboat-compose:test -Ptugboat.composeBom=2024.09.00   # the floor of the range
```

The end-to-end tests (identity, masks, scroll, focus, routes, through the
Views adapter) live in `tugboat-android`'s test source set, which depends on
this module test-only. `bash tool/ci/build-android-runtime.sh` from the
repository root runs both ends of the range and builds the release AAR.
