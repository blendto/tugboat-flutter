# Production replay release and acceptance

This is the release gate for changes that affect screenshot timing, route
ownership, state signatures, target anchors, or interaction outcomes. Local
tests are necessary but do not satisfy this gate. Acceptance requires manually
playing back a bounded cohort from the released SDK in the production replay
website.

The procedure is intentionally strict about build identity. Do not mix sessions
from different SDK revisions, infer the SDK revision from capture time, or use
database receipt alone as proof that a replay is correct.

## Roles and evidence

Record these people before starting:

| Role | Responsibility |
| --- | --- |
| SDK releaser | Lands the SDK stack and records the exact main commit |
| Blend releaser | Pins Blend to that commit and records the app build |
| Replay reviewer | Executes the flow matrix and inspects production replays |

The evidence record must contain:

- Tugboat package version and exact Git commit;
- Blend version, build number, and Git commit;
- device platform and OS version;
- capture start and end timestamps in UTC;
- collector session ID for every inspected replay;
- the flows present in each session;
- a per-session verdict and links to any follow-up issues.

## Entry gate

Do not start the production cohort until every item is true:

- all behavioral replay-correctness PRs are merged to `main`;
- the navigation and interaction race matrix passes on the merged commit;
- `flutter analyze` and the complete `packages/tugboat` test suite pass;
- `packages/tugboat/pubspec.yaml` and
  `packages/tugboat/lib/src/sdk_version.dart` contain the same new version;
- Blend is pinned to the exact merged SDK commit;
- the deployed Blend build is available to the reviewer;
- production collection is enabled for the test account/device;
- the production replay website can filter or otherwise identify the SDK and
  app build cohort.

The HTTP collector sends the package version as `X-Sdk-Version`. App version,
build number, app ID, and platform are sent with the same requests. Record both
the SDK version and exact Git commit because a version string alone cannot
distinguish two builds made from different commits.

## 1. Land and verify the SDK

Merge dependent PRs from the bottom of the stack upward. Never merge a child
before its parent. After the final PR lands:

```sh
git switch main
git pull --ff-only
git status --short
git rev-parse HEAD
```

The worktree must be clean. From `packages/tugboat` run:

```sh
flutter analyze
flutter test --concurrency=1 --reporter compact
```

Then verify the release identity:

```sh
sed -n '1,8p' pubspec.yaml
sed -n '1,8p' lib/src/sdk_version.dart
```

Record the main commit as `SDK_GIT_SHA`. This repository currently distributes
the package as a Git dependency; there is no separate pub.dev release whose
contents can substitute for that commit.

## 2. Pin and deploy the Blend canary

Create a Blend canary branch from its current release base. In Blend's
`pubspec.yaml`, pin the Tugboat dependency to `SDK_GIT_SHA`, not a moving
branch:

```yaml
tugboat:
  git:
    url: https://github.com/blendto/tugboat-flutter
    path: packages/tugboat
    ref: <SDK_GIT_SHA>
```

Resolve dependencies using Blend's checked-in Flutter toolchain:

```sh
flutter pub get
```

Verify `pubspec.lock` contains both the expected package version and
`resolved-ref: <SDK_GIT_SHA>`. Commit the manifest and lockfile together.

Build and deploy through Blend's normal internal canary channel. Record:

- Blend Git commit;
- version and build number;
- deployment environment/channel;
- platform artifact identifier;
- installation time on the test device.

Launch the installed artifact, not a locally patched example application.
Confirm that its production collector configuration is active. Do not use the
local exploration collector for this acceptance cohort.

## 3. Capture the manual session matrix

Use a dedicated test account where practical. Keep each session focused enough
that event order is easy to inspect, but include multiple related actions when
the race itself requires them.

| Flow | Required actions | Expected evidence |
| --- | --- | --- |
| Same-route tap | Perform one state-changing tap and one true no-op | Each tap points at its visible control; the no-op is not confused with delayed navigation |
| Slow push | Open a route with noticeable rendering or loading delay | Route event and settled tap use the rendered destination frame |
| Route replacement | Exercise a replacement-style transition | No frame or state from the replaced route is attached to the destination |
| Rapid navigation | Trigger two consecutive route changes | Only the visible successor owns destination evidence |
| Modal and sheet | Open and close a dialog and bottom sheet | Overlay events and frames describe the overlay that is actually visible |
| Immediate destination tap | Tap a control as soon as the destination appears | Destination action does not reuse the origin frame |
| Scroll then navigate | Begin/end a scroll and immediately navigate | Scroll evidence stays on its origin epoch; route capture shows the destination |
| External picker | Open a system picker, background/foreground, and return | Lifecycle cancellation/resumption is explicit and the resumed frame is current |
| Degraded capture | Reproduce budget pressure or a classified capture failure when feasible | Missing visual evidence has a bounded diagnostic outcome and never borrows a stale frame |

Record session IDs and UTC time ranges immediately after each flow. If several
flows share a session, list the event IDs or timestamps that delimit each flow.

## 4. Inspect the production website

Wait until the collector session has finalized and the replay is available in
the production website. Filter to the recorded Blend build and SDK version
`0.4.8` (or the version under test), then open every recorded session.

For each interaction, inspect the actual replay UI and verify:

- the tap marker lands on the control visible in its before-frame;
- target anchor, route, state signature, and frame describe the same screen;
- a navigation-producing tap does not emit an early unrelated
  `noVisibleChange`;
- an action on a destination screen does not reuse an origin-screen frame;
- a changed outcome has either a fresh visual frame or an explicit
  semantic-only/degraded classification;
- a route event shows the rendered destination rather than a splash, outgoing
  route, or partially advanced UI;
- reused visual evidence has an explainable capture diagnostic;
- every referenced frame opens successfully;
- taps, route changes, scroll boundaries, and lifecycle events appear in
  chronological order;
- the replay identifies the recorded app build and session.

ClickHouse, logs, or raw event payloads may help diagnose a failure, but they
cannot replace this visual inspection. A frame row returning from storage does
not prove that the replay attached it to the correct screen or action.

## 5. Record the verdict

Use one row per production session:

| Session ID | UTC range | Blend build | SDK version / SHA | Flows | Frame availability | Route/action coherence | Verdict | Follow-up |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `<collector-session-id>` | `<start> - <end>` | `<version+build>` | `0.4.8 / <sha>` | `<flows>` | pass/fail | pass/fail | accept/reject | `<issue or none>` |

The cohort passes only when:

- every required flow was inspected;
- no referenced frame is unavailable;
- no unexplained cross-route or cross-step settle is present;
- no tap marker points at UI absent from its before-frame;
- no destination action uses origin-screen pixels or signatures;
- every degraded capture is explicit and bounded;
- the user manually confirms the sampled replays look correct.

Any failure keeps the gate open. Save the session ID and timestamps, open one
narrow issue for the observed defect, and link it from the verdict. Do not
approve broad rollout based on the remaining successful sessions.

## Rollback

If the canary fails:

1. stop broad rollout;
2. retain the rejected session IDs and deployed artifact;
3. restore Blend's Tugboat ref and lockfile to the last accepted
   `resolved-ref`;
4. redeploy through the same channel;
5. open a granular SDK issue with the failed flow, event IDs, frame IDs,
   version/build identity, and production replay link.

Do not repair acceptance replays with dashboard post-processing. The SDK must
emit causally aligned evidence at capture time.
