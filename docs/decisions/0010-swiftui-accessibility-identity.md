# ADR 0010: Opt-in accessibility-tree identity for SwiftUI taps

Status: Proposed
Date: 2026-10-15

## Context

SwiftUI draws most controls without a UIKit view of their own. The SwiftUI
adapter resolves a tap to a `.tugboatTag` marker when one is under the
point. Otherwise it walks UIKit hit-testing up to the nearest target kind
(text input, list cell, scroll view, representable). A tap on an untagged
`Button` drawn directly in a hosting view has no target kind, so it is
reported as `no_actionable_candidate`, and a tap on a button inside a list
row resolves to the row. Tags fix this for the flows an app tags, but
untagged screens stay weak evidence.

SwiftUI does keep an accessibility tree with each control's identifier,
traits and frame. iOS builds that tree only while an assistive client
(VoiceOver, Switch Control, Voice Control, XCUITest) is reading it.
Calling the public `accessibilityActivate()` on the hosting view builds it
in-process with no client attached. A probe of that technique, which at
least one commercial analytics SDK ships, found:

- iPhone 12, iOS 18.6.2: the hosting view went from 0 to 35 accessibility
  elements, and 4 of 4 app-set identifiers were readable.
- The tree is built once per process and is not there after a relaunch.
- `accessibilityHitTest(_:)` still returns nil, so a tap has to be matched
  to an element by its frame.
- It is not free. In one Release-build benchmark, once the tree was first
  read: LazyVStack scrolling main-thread time +104%, state updates +55%,
  process CPU +31%, memory +5 MB. In the SwiftUI sample, scrolling was
  +27%. There is no public way to turn the tree off again for the life of
  the process.
- The host app's `@Environment(\.accessibilityEnabled)` becomes true, so an
  app that changes its UI for assistive users changes it for everyone in
  that process.
- One vendor documents a hang in lazy stacks on iOS 26 with the tree built
  (Apple FB21851974).

These numbers come from one device and one OS, and are the reason for this
decision, not a performance claim.

## Decision

Add an **opt-in** identity fallback that reads the SwiftUI accessibility
tree for untagged taps. It is off by default, and nothing in the default
configuration builds the tree.

### Configuration

```swift
public enum SwiftUIAccessibilityIdentity {
  case off                    // default
  case sampled(rate: Double)  // 0...1, drawn once per process launch
  case on
}
TugboatConfig.swiftUIAccessibilityIdentity = .off
```

- The sample is drawn once per **process launch**, not per session or per
  tap, because the cost cannot be undone once the tree exists. A process
  that is not sampled in never reads the tree, including in later sessions.
- No remote gating in this ADR. Remote config could only turn the feature
  off for future processes, never for one that has already built the tree.
- A per-OS-version gate is a precondition of shipping (see Consequences),
  not a configuration knob.

### When it runs

Only for a tap that resolves today to `no_actionable_candidate`, or to a
container target (list cell or scroll view) with no control under it. It
never runs when a `.tugboatTag` marker is under the point or the nearest
UIKit target is a control (a UIKit control, text input or
representable). Tagged and
UIKit-resolved taps keep exactly today's anchors.

### Activation

- The tree is built lazily, on the first qualifying tap of a sampled-in
  process, by calling `accessibilityActivate()` on that tap's hosting view.
  Measured at about 85–300 ms of main-thread time, once per process.
- Activation runs on the main queue's next turn after the touch ends, not
  inside the touch sequence, so the stall never lands between down and up.
  That first tap is resolved as it would be with the feature off.
- When `UIAccessibility.isVoiceOverRunning`, `isSwitchControlRunning` or
  another public "assistive client running" signal is true, the tree
  already exists: the adapter skips activation and reads it directly.
- With `.off`, the adapter never reads the tree, **even when VoiceOver is
  running**. Otherwise one user's anchors would depend on whether they use
  an assistive client.

### Reading

- No full-tree walk. From the hosting view, descend only into accessibility
  containers whose `accessibilityFrame` contains the tap point, and take the
  smallest element (`isAccessibilityElement`) whose frame contains it.
  Frames are converted from screen to window coordinates.
- The adapter reads the element's `accessibilityIdentifier` and
  `accessibilityTraits`. Nothing else.
- **Labels are not read or sent.** `accessibilityLabel` and `Value` carry
  visible, localized and often user-specific text ("Message from Ada",
  "Pay $42.10"). The identity contract
  (`docs/design/capture-and-fingerprint.md`, "What is and is not retained")
  and `TargetAnchor` both exclude accessibility labels from anchors, and
  this ADR keeps that boundary. Sending labels as evidence would be a
  separate privacy decision.

### Anchors

The fallback changes only the tap anchor. There is no new wire field and no
engine change.

- **With an identifier**, the identifier is the alias, as `testTag` is for
  Compose: a `tagFingerprint` (`routeKey` + identifier), `tag` in
  `fingerprintParts`, `high` path confidence. The structural path is the
  base path plus `AXIdentified#<k>`, where `k` is the element's ordinal
  among identified elements on the descent. `widgetType` is
  `SwiftUIView` and `role`, `actions` and `enabled` are omitted, as for a
  `.tugboatTag`.
- **Without an identifier**, the path is the base path plus `AX<Role>#<k>`,
  with `k` the element's ordinal among siblings of that role. `Role` comes
  from traits, mapped onto the role names anchors already use (`button`,
  `textField`, `link`, `image`, `adjustable`; `toggle` where the OS
  exposes it); anything else is `AXElement`. Traits that map to no role
  give no `role` field. Confidence is `low`, or
  `medium` inside a list cell, the same rules as other structural paths.
- `toolkit` stays `swiftui` and `fingerprintSchemaVersion` is unchanged.
  The `AX` path tokens tell consumers which anchors came from the tree.
  Taps that anchored on a list cell or a scroll view get a deeper path,
  and so a different structural fingerprint, in sampled-in processes. That
  is why the feature is opt-in and documented as an identity-source change.

The identifier carries the same data-derived-ID risk as Compose's
`testTag` fallback and Flutter's `ValueKey<String>`: apps often write
`accessibilityIdentifier("row_\(item.id)")`. Identifiers pass through the
same filter that the planned `ValueKey`/`testTag` follow-up defines. If
that filter is not settled first, they are not used as an alias at all
(the element still gives an `AXIdentified` path segment, without its
value).

## Considered options

- **Always on.** Rejected: the measured scroll, CPU and memory cost and the
  `accessibilityEnabled` side effect apply to every user of the host app.
- **Activate at session start.** Rejected: every sampled-in process pays,
  including ones with no untagged taps.
- **Read only when VoiceOver is running.** Free, but identity then depends
  on the user's assistive settings, and VoiceOver users are a small,
  unrepresentative slice. Kept only as the "skip activation" shortcut
  inside the opt-in.
- **Private SwiftUI introspection.** Rejected: not public API, breaks
  between OS releases.
- **Send labels as evidence.** Deferred: a privacy-boundary change that
  needs its own decision.

## Consequences

- Before implementation, re-measure on iOS 17 and iOS 26 (Release, real
  devices, the same scroll, state-update, CPU and memory benchmarks), and
  reproduce or rule out the iOS 26 lazy-stack hang. The results set a
  built-in OS-version gate; on an OS outside the gate the feature behaves
  as `.off`.
- The SDK README and the integration tagging guide document the costs, the
  `accessibilityEnabled` side effect and the iOS 26 risk next to the
  option, and say that `.tugboatTag` (optionally with
  `accessibility: true`) is the recommended path.
- XCUITest cannot test the activation path, because the test runner is
  itself an assistive client and the tree always exists under it. Tests
  split into unit tests of the descent and anchor rules against a built
  tree, and a no-client simulator test that activation happens once,
  lazily, and only when sampled in.
- The option is a minor, additive API on the Swift `Tugboat` package,
  versioned on its own (ADR 0008).
