# Agent prompt: tag your key flows

Give the prompt below to a coding agent (Claude Code, Cursor, Codex and
similar) in your app's repository. It adds `tugboatTag` to the controls of
your key flows, following [tagging.md](tagging.md), and reports what it
tagged for you to review. Install and start the Tugboat SDK first; the
prompt only adds tags.

Edit the "Key flows" line if you already know which flows matter.

````markdown
Add Tugboat tags to this app's key flows.

Tugboat is a capture SDK that is already installed here. A tag gives a
control a stable identity. Tags are optional; untagged controls are still
captured. Your job is to tag the controls that matter most, with small,
reviewable diffs.

Key flows: find them yourself (sign-up, log-in, onboarding, checkout or
purchase, subscribe, the primary action of each main screen, main
navigation tabs).

1. Find the UI toolkit or toolkits in use and use only this syntax, as a
   one-line suffix on the control itself:
   - Flutter: `.tugboatTag('flow.control')` on the widget
     (`import 'package:tugboat/tugboat.dart';`).
   - SwiftUI: `.tugboatTag("flow.control")` on the view (`import Tugboat`).
   - Jetpack Compose: `Modifier.tugboatTag("flow.control")` on the
     control's own modifier, appended to its existing chain
     (`import com.tugboat.android.compose.tugboatTag`).
   - Android Views: `view.tugboatTag = "flow.control"` where the view is
     bound (`import com.tugboat.android.tugboatTag`).
   If the toolkit is not one of these, stop and say so.

2. List the key flows and, for each, the screens and the controls a user
   acts on: buttons, links, toggles, text fields, tabs. Skip decorative
   views, containers and text that is not tappable.

3. Name each tag `<flow>.<control>` in lowercase with dots and
   underscores: `checkout.pay`, `onboarding.skip`,
   `settings.notifications_toggle`. A tag must be:
   - stable: never derived from type names, positions or generated ids;
   - unique per screen: two different controls on one screen get two tags;
   - not localized: never the visible label or a translated string;
   - free of user data: no names, emails, ids, amounts or other values.

4. Never build a tag from data. Do not tag inside a loop, list builder or
   `ForEach` with an interpolated id such as `"row_${item.id}"`. If every
   row has the same control, give it one constant tag
   (`cart.item_remove`), or leave it untagged.

5. Prefer tagging once in shared code:
   - If a component exists for one purpose (a `CheckoutPayButton`, the app's
     tab bar), tag the control inside that component once instead of at
     every call site.
   - If a component is generic (a `PrimaryButton` used for many actions),
     do not put a fixed tag inside it. Tag each call site in the key flows.

6. Keep every change to a one-line suffix or one added line. Do not
   reformat, reorder or rename code, change keys, layout or behaviour,
   add dependencies, or touch files outside the key flows.

7. Do not pass `accessibility: true` (Compose: `accessibility = true`)
   unless the team asked for it. Never remove or change an existing
   `accessibilityIdentifier`, `testTag`, `Semantics` identifier, `Key` or
   `android:id`. Keep existing `tugboatTag` values as they are; add
   tags, never rename them.

8. Build the app (or run its analyzer) to check that it still compiles.

9. Reply with a table of every tag you added: screen, control, tag, file
   and line. List the flows you could not find, and controls you chose
   not to tag and why.
````

## Notes for reviewers

- Check the table against the naming rules in [tagging.md](tagging.md),
  especially that no tag contains user data or is built from data.
- Tags become identity: renaming one later starts a new identity for that
  control. Settle names before release.
- The prompt tells the agent to keep existing tags, so it is safe to run
  again as the app grows.
