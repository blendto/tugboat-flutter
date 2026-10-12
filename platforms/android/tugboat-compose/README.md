# tugboat-compose

Jetpack Compose adapter for the native Android SDK
([ADR 0009](../../../docs/decisions/0009-shared-session-engine.md)).
Maven coordinates `com.gettugboat.sdk:tugboat-compose:0.1.0`, namespace
`com.tugboat.android.compose`, minSdk 24. Versioned on its own (ADR 0008, see
[CHANGELOG](CHANGELOG.md)) and unpublished: the only repository is the
untracked `.local-maven`.

It is a separate artifact so Views-only apps do not pull in Compose. It
depends on `tugboat-android` and Compose UI.

## Public API

Two entry points, nothing else:

| API | Use |
| --- | --- |
| `TugboatCompose.install()` | Called by the SDK facade when the app ships this module. Registers the Compose region with the Views adapter. Idempotent; never throws. |
| `Modifier.tugboatTag("checkout")` | Developer alias, like `View.tugboatTag`. A high-confidence `tagFingerprint`; the structural fingerprint is unchanged. |

## How it plugs into the Views adapter

`tugboat-android`'s Views adapter owns the window: the single
`Window.Callback` wrapper (pointer and key facts), batching, hashing, and
mask normalization. Compose content lives inside one View, the
`AndroidComposeView`, which the Views adapter cannot read. This module
implements the adapter's **toolkit-region seam**
(`com.tugboat.android.toolkit.ToolkitRegion`, opt-in
`@TugboatToolkitApi`, see the `tugboat-android` README). The adapter asks
the region first, for every `AndroidComposeView`:

| Seam call | Compose answer |
| --- | --- |
| `targetAt` | Semantics hit-test at the **down** position: the nearest actionable node, else the nearest kept node; its path, token, role, actions, alias. A point on `AndroidView` interop is a `Miss`, so the Views rules resolve the interop View. |
| `masks` | Text, editable text, `Role.Image`, and content-description nodes from the unmerged tree; `AndroidView` interop bounds fail-closed. |
| `scrollables` | Nodes with a `ScrollAxisRange`, diffed per frame during and after gestures. |
| `focus` | `TextInput` when a focused node is editable. |
| `routeKey` | The `trackNavigation` route pattern without arguments. |

The region keeps no listeners; the Views adapter drives it, so it is inert
once the adapter stops.

## Identity

`docs/design/capture-and-fingerprint.md`, "Compose canonicalization".
In short:

- Source: the merged semantics tree from `ViewRootForTest.semanticsOwner`,
  reached through `runCatching` (the only Compose internal used).
- Token: `Role` (`Button`, `Checkbox`, `Switch`, `RadioButton`, `Tab`,
  `Image`, `DropdownList`), then `TextField`, `Scrollable`, `Node`.
- Path: the host's Views path (the host is the token `Compose`) followed by
  the node path, for example `Compose#0/Scrollable#0/[item:3]/Node#0`.
- Lists: `CollectionItemInfo`, else traversal order on screen.
- Route key: the `trackNavigation` route pattern, arguments stripped
  (`checkout/{id}?step={s}` is `checkout`), else the host's Views route
  (the hosting activity, or the fragment around a `ComposeView`).
- Alias: `Modifier.tugboatTag`, then `testTag`. Text is never in identity.
- `toolkit: "compose"`, including the fallback below.

**Semantics unavailable.** If the owner cannot be reached (a Compose
version that moved it, or any throw), a tap anchors the hosting View
(`Compose#0`, `toolkit: "compose"`) and the whole frame is masked.

## Navigation hook

There is no Navigation Compose dependency. The SDK facade connects
`Tugboat.trackNavigation(navController)` with:

```kotlin
navController.addOnDestinationChangedListener { _, destination, _ ->
    viewsAdapter.onDestinationChanged(activity, destination.route, destination.id)
}
```

The Views adapter keeps the destination for Views route keys and forwards
the plain route string to every region; Compose strips its arguments.

## Compose versions

| | Compose UI |
| --- | --- |
| Compiled against (floor, `require`) | 1.7.0 |
| Unit tests in CI | 1.8.3 (BOM `2025.06.01`) |
| Also verified locally | 1.7.7 (BOM `2025.01.01`) |
| Tested range | 1.7.x to 1.8.x |

The dependency is a floor, not a strict pin, so the app's newer Compose
wins. Outside the tested range every semantics read still goes through
`runCatching`: a failure falls back to the host identity and whole-frame
masks, never an unmasked frame. Re-run the tests against another release
with `./gradlew :tugboat-compose:test -Ptugboat.composeBom=<bom>`.

## Known gaps

- Scroll offsets are per-frame samples, so they are approximate. Lazy
  layouts report Compose's own estimate (500 per item plus the first item's
  pixel offset) and no extent. Scrolls without a touch (wheel,
  programmatic) and overscroll are not reported.
- Lazy layout items carry no `CollectionItemInfo`, so their `[item:n]`
  counts from the first item on screen. Apps make it stable with
  `Modifier.semantics { collectionItemInfo = ... }` or a `tugboatTag`.
- Items without a semantics node of their own (a `Row` of a text and a
  button) are separate children of the list, so each takes its own index.
- Masks cover semantics nodes. Text drawn on a `Canvas` without semantics
  is not masked.
- Mask bounds ignore `graphicsLayer` scale beyond the clipped bounds.
- Interop masking tells Compose's own views apart by package name; the
  consumer R8 rules keep those names. A renamed class over-masks.
- Compose dialogs and popups are separate windows, which the Views adapter
  does not wrap (the same gap as Views dialogs).

## Build and test

From `platforms/android`:

```sh
./gradlew :tugboat-compose:test   # Robolectric + Compose UI test
```

The tests drive `tugboat-android`'s internal Views adapter end to end, so
the unit-test compilation is a Kotlin friend of `tugboat-android`'s classes
(test-only, see `build.gradle.kts`). `bash tool/ci/build-android-runtime.sh`
from the repository root runs them and builds the release AAR.
