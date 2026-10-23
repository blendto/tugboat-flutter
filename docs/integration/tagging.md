# Tagging controls

A tag gives a control a stable name that Tugboat uses as its identity. It is
optional. Without tags, Tugboat identifies controls by their place in the UI
tree (the structural fingerprint). Tags are for the controls you most want to
follow reliably.

Every SDK uses the same name, `tugboatTag`.

## Why tag

The structural fingerprint changes when the UI tree around a control changes.
A tag does not. Tags keep a control's identity stable across:

- releases that move or restyle the control;
- refactors that wrap it in new layout or components;
- obfuscated or minified builds, where type names are scrambled.

A tag gives the target a `tagFingerprint` at `high` confidence. It does not
change the structural fingerprint, which is still recorded alongside it. See
[Capture and fingerprint architecture](../design/capture-and-fingerprint.md).

## What to tag

Tag the controls of your key flows, not everything:

- sign-up, log-in and onboarding steps;
- checkout, purchase, subscribe and other conversion controls;
- the primary action on each important screen;
- navigation you analyse (tab bar items, main menu entries).

Untagged controls are still captured and fingerprinted. Tag more later when
you find a control whose identity is not stable enough.

## Naming rules

- **Stable.** The tag must not change between builds. Don't derive it from
  type names, positions or generated ids.
- **Unique per screen.** Two different controls on one screen need two
  tags. One control repeated on every row of a list can share one constant
  tag, for example `cart.item_remove`.
- **Not localized.** Never use the visible label. `checkout.pay`, not
  `"Pay now"` or a translated string.
- **No user data.** Tags are sent as telemetry. Never put names, emails,
  ids, amounts or any other data value in a tag. Never build a tag from
  data, for example `"row_\(item.id)"`.
- **Readable.** Use lowercase `<flow>.<control>`: `checkout.pay`,
  `onboarding.skip`, `settings.notifications_toggle`.

## Syntax per platform

Add the tag as a one-line suffix on the control itself.

### Flutter

```dart
import 'package:tugboat/tugboat.dart';

ElevatedButton(onPressed: pay, child: const Text('Pay')).tugboatTag('checkout.pay'),
```

`widget.tugboatTag('id')` is the same as `TugboatTag('id', child: widget)`.
The extension needs `tugboat` 0.10.11-dev.4 or later; the `TugboatTag`
widget works in earlier versions.

### SwiftUI

```swift
import Tugboat

Button("Pay", action: pay)
  .tugboatTag("checkout.pay")
```

### Jetpack Compose

```kotlin
import com.tugboat.android.compose.tugboatTag

Button(onClick = pay, modifier = Modifier.tugboatTag("checkout.pay")) { Text("Pay") }
```

Put the tag on the control's own modifier. A tag on a child of a merged
control (a `Text` inside a `Button`) is attributed to the control.

### Android Views

```kotlin
import com.tugboat.android.tugboatTag

binding.payButton.tugboatTag = "checkout.pay"
```

Setting `null` or an empty string removes the tag.

### React Native

There is no React Native SDK yet. It will use the same `tugboatTag` name.

## The `accessibility` option

UI test tools (XCUITest, Espresso, Maestro, Appium) and Tugboat's own
exploration runs find controls through the accessibility tree. With
`accessibility: true`, the tag is also published there, so one id serves
Tugboat and your UI tests. It is off by default because apps often set
their own test identifiers, and the option can replace them. Identity is
the same whether it is on or off.

| Platform | What `accessibility: true` sets | Caveats |
| --- | --- | --- |
| Flutter | `Semantics(identifier:)` around the control (Android resource-id, iOS `accessibilityIdentifier`) | Use it on a single control, not a container. On Material buttons the identifier lands on a label-less parent node above the labelled button. |
| SwiftUI | `.accessibilityIdentifier(tag)` on the tagged view | Use it on a single control: on a container, SwiftUI gives every element inside the container's identifier. When a view has two identifiers the outermost wins: an app `.accessibilityIdentifier` applied after `.tugboatTag` keeps yours, one applied before it is replaced by the tag. Leave the option off on controls that already have one. |
| Compose | `testTag(tag)` on the same node | A node keeps one `testTag`, the first in the modifier chain: a `testTag` before `.tugboatTag(..., accessibility = true)` keeps yours, one after it is replaced by the tag (the opposite order from SwiftUI). Leave the option off on nodes that already have one. Put the tag on the control itself: a `testTag` does not merge up from a child. Test tools that read the accessibility tree see a `testTag` as a resource-id only under an ancestor with `Modifier.semantics { testTagsAsResourceId = true }`, which Tugboat does not set. |
| Views | No option | Test tools read the resource-id from `android:id`, which Tugboat already uses (see below). Tugboat installs no `AccessibilityDelegate`. |

```dart
ElevatedButton(onPressed: pay, child: const Text('Pay'))
    .tugboatTag('checkout.pay', accessibility: true),
```

```swift
Button("Pay", action: pay)
  .tugboatTag("checkout.pay", accessibility: true)
```

```kotlin
Button(onClick = pay, modifier = Modifier.tugboatTag("checkout.pay", accessibility = true)) { Text("Pay") }
```

## Identifiers Tugboat reads without a tag

When a control has no `tugboatTag`, some SDKs use an identifier the app
already has as the alias. A `tugboatTag` always wins.

| Platform | Fallback | Notes |
| --- | --- | --- |
| Flutter | A `ValueKey<String>` on the widget | Any string `ValueKey` is used, including keys built from data in lists. Avoid data-derived string keys on controls, or tag the control. |
| SwiftUI | None by default; opt-in accessibility-tree identity ([ADR 0010](../decisions/0010-swiftui-accessibility-identity.md)) | By default nothing is read. With `swiftUIAccessibilityIdentity` on or sampled in (iOS 18 only), untagged taps read the element's `accessibilityIdentifier` and traits as path evidence only (`AXIdentified#<k>`, `AX<Role>#<k>`): never as an alias, and the identifier's value is never sent. It has a lasting scroll, CPU and memory cost per process; see the [SDK README](../../platforms/apple/Sources/Tugboat/README.md#accessibility-tree-identity-opt-in-adr-0010) before turning it on. |
| Compose | `testTag` | Any `testTag` is used, including tags built from data, such as `testTag("row_${item.id}")`. Avoid data-derived test tags, or tag the control. |
| Views | The entry name of the view's `android:id` | Only when no other view under the screen's root has the same id, and only for ids from the app's resources (not generated ids). Skipped when resource names look obfuscated. |

The same naming rules apply to these identifiers when Tugboat reads them:
a data value in a `ValueKey` or `testTag` is sent like a data value in a
tag.

## Sensitive content (always masked)

Use `tugboatSensitive` when pixels must be hidden in every screenshot mask
level, including the most permissive: Compose `SemanticsBestEffort`, and
SwiftUI's verified layer allowlist, where plain colour fills stay visible.
A mark only adds mask coverage; it never removes any. It is not a tag:
it masks pixels only, and taps, canonical paths and fingerprints are the
same with or without it.

| Platform | What is masked | Notes |
| --- | --- | --- |
| Flutter | The widget's subtree | `TugboatSensitive(child: ...)` or `.tugboatSensitive()`. |
| SwiftUI | The view's layout frame | Masked by the same view walk as every other mask, so in every mask mode. Drawing outside the frame (an offset overlay, a shadow) is not covered by the mark. Applied to a hosting controller's root view, it changes that controller's type and so its route key (like any modifier there): apply it inside the root view's body, or name the screen with `.tugboatScreen`. |
| Compose | The element's bounds at its place in the modifier chain, and every semantics node laid out inside it, each at its own unclipped bounds | It adds no semantics node, so list items, scroll targets and scene inventory are unchanged too, and `clearAndSetSemantics` on the same element does not remove it. Under the default `WholeHost` the host is already masked whole. Drawing with no semantics node of its own that lands outside the marked bounds is not covered. |
| Views | The view and every view below it, each at its own bounds | A subview drawn outside its marked parent is masked at its own bounds. |

There is no un-mark on Views: a marked view stays marked for its lifetime,
including a recycled `RecyclerView` row. That fails safe: it over-masks.
On SwiftUI and Compose, remove the modifier to stop masking.

### Flutter

```dart
Text('Do not show in replay').tugboatSensitive(),
```

### SwiftUI

```swift
TextField("Card", text: $number)
  .tugboatSensitive()
```

### Jetpack Compose

```kotlin
import com.tugboat.android.compose.tugboatSensitive

Text("•••• 4242", modifier = Modifier.tugboatSensitive())
```

### Android Views

```kotlin
import com.tugboat.android.tugboatSensitive

binding.cardNumber.tugboatSensitive()
```

From Java: `TugboatViews.tugboatSensitive(view)`.

## Tagging with a coding agent

[tagging-agent-prompt.md](tagging-agent-prompt.md) is a prompt you can give
a coding agent to find your key flows and tag them with these rules.
