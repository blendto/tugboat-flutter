# PMKit Capture & Fingerprint — Design

Status: Draft for review · Owner: PMKit · Scope: `pmkit` (Dart SDK) + `pmkit_cli` (ingestion)

## 1. Problem & goals

PMKit builds a **content graph** of an app by exploring it (today: a CLI + LLM driving
an emulator, with the SDK streaming events over a websocket). Separately, once the app
ships, the SDK should emit events from real usage. We want a **stable fingerprint** that
acts as a **join key** between the offline content graph and production telemetry, so we
can say "this user walked this flow" and aggregate across users.

### Hard requirements

1. **Deterministic & content-independent.** For a given app build, the same UI element
   tapped by any user produces the same `targetFingerprint`; the same screen produces the
   same `stateSignature`. Dynamic data (user content, list length, localized values) must
   not change the fingerprint.
2. **Computable by the SDK alone.** Production has no LLM. The join key must be derived
   purely from SDK signals, identical in exploration and production.
3. **No reliance on developer tags.** `PmkitTag` is an optional hardening tier, not a
   dependency. The default path must stand on its own.
4. **Keep screenshots.** Visual is the ground truth for confirming hypotheses; the work is
   making capture cheap, not removing it.
5. **Scalable ingestion without a live peer.** Production/capture sessions should not need
   a live CLI websocket. A session is activated by a capture-session id passed at runtime;
   the SDK captures everything under that id to a pluggable sink.
6. **Low overhead.** The SDK now lives inside release builds. Dormant cost ≈ 0; active cost
   bounded and self-monitored.

### Non-goals (for now)

- Cross-version fingerprint stability (handled by namespacing on build, then diffing).
- Capturing native-side networking / native analytics without per-stack adapters.
- A universal "sniff all analytics" mechanism (offered only as an experimental tier).

## 2. Current state (audit summary)

- The SDK captures rich anchors (`labelHashes`/`actionableRoles`/`iconHashes`, target
  anchors with bounds), but the consumer (`pmkit_cli`) **ignores almost all of it**.
- What actually drives decisions: the device screenshot + accessibility tree (from
  argent/adb, not the SDK), plus two thin SDK facts: route name from `route_change`, and
  before/after frame-hash change from `tap_settled`.
- **State identity is wrong for our goal:**
  - `stateSignature = hash(route + counts of {button,textField,scrollable} + flags)` —
    collides across different screens and is unstable across users (counts move with
    content).
  - `targetFingerprint = hash(role + widgetType + relativePosition + enabled + actions)` —
    identifies a *category* ("an enabled bottom button"), not *which* element; reflow
    changes `relativePosition`.
  - The CLI graph node id mixes in the **LLM's** `title`/`controls`, which production can
    never reproduce.
- A reference run (`23bac67d`) produced 106 journal records but an **empty content graph**
  and **0 events attributed to an action** — telemetry captured, zero usable yield.

Conclusion: the fingerprint must be redesigned around **structural identity**, and the CLI
graph must **join on the SDK fingerprint**.

## 3. Architecture overview

Three decoupled layers tied together by a **session capture id**:

```
[release build + dormant SDK]
        │ activate(sessionId, sink, profile)        ← intent extras / deep link / remote flag
        ▼
   CAPTURE  (pmkit) ── fingerprints, screenshots, logs, network, perf, analytics
        │
   TRANSPORT (pluggable sink) ── WebSocketSink (dev) | FileSink (pull) | HttpBatchSink (scale)
        ▼
   INGESTION (pmkit_cli / backend) ── builds content graph; joins prod events by (apkSha256, fingerprintSchemaVersion, fingerprint)
```

### Capture profiles

| Profile           | Fingerprints | Screenshots            | Logs/Net/Perf | Use                          |
| ----------------- | ------------ | ---------------------- | ------------- | ---------------------------- |
| `dormant`         | off          | off                    | off           | default in release           |
| `exploration`     | on           | full, every state*     | on            | graphing session (operator)  |
| `production-lean` | on           | sampled / thumbnails   | sampled       | real end users               |

\* **CLI WebSocket exploration (2026-06-24):** when `explorationCollectorUrl` is set and no
HTTP collector is configured, frame capture is suppressed after the WebSocket connects — the
CLI records ADB `before.jpg` / `after.jpg` per gesture instead. HTTP collector and production
profiles are unchanged.

Dormant must be truly zero-cost. **This is not true today** and is real work, not a flag:
`wrapApp` unconditionally creates the controller, schedules `controller.start(...)` in a
post-frame callback, installs `InputCapture`, and always wraps the child in a
`RepaintBoundary` + `NotificationListener` (`lib/src/pmkit.dart`, `initState` /
`_scheduleSessionStart` / `build`). Activation gating must make `dormant` a pass-through:
no capture controller/session/input capture/render layers; only a tiny activation shell may
remain — capture paths are constructed only after `activate(sessionId, sink, profile)`.

## 4. Fingerprint v2

The raw Flutter element tree is **not** a stable substrate: wrapper churn (`Padding`,
`Center`, `MouseRegion`, `DefaultSelectionStyle`, `Semantics`, …), lazy/sliver lists,
route-transition double-trees, conditional rendering, and `--obfuscate` all perturb it.
We therefore never fingerprint the raw tree. We first derive a **canonical fingerprint
tree**, then compute keys from that, and we treat structure-only matches as
**confidence-weighted**, not truth.

### 4.1 The canonical fingerprint tree

A normalization pass converts the live element tree into a stable, reduced tree before any
hashing:

1. **Wrapper filtering.** Collapse "structural noise" widgets so they never appear in a
   path. This is an explicit, versioned **denylist** of layout/decoration/a11y wrappers
   (e.g. `Padding`, `Center`, `Align`, `SizedBox`, `DecoratedBox`, `MouseRegion`,
   `Semantics`, `DefaultSelectionStyle`, `RepaintBoundary`, `Builder`, animation/opacity
   wrappers). Capture-chrome widgets (the SDK's own `RepaintBoundary`/`Listener`) are
   already filtered. The denylist is part of `fingerprintSchemaVersion` (see §4.7) so it
   evolves deliberately.
2. **Salient-node retention.** Keep nodes that carry identity: actionable widgets (the
   roles already detected in `_roleForWidget`), declared keys/tags, named routes, and
   `PmkitSubView` boundaries.
3. **Ordinal assignment.** Within a parent, ordinal counts **retained siblings of the same
   canonical type** — computed *after* filtering, so wrapper churn doesn't shift ordinals.
4. **Confidence downgrade.** Each normalization that loses information (deep wrapper
   collapse, ambiguous repeated siblings, fallback route key) records a downgrade. The
   element's final `confidence` is the floor of its contributing steps (see §4.6).

A path token is `canonicalType#ordinal`, optionally annotated with a tag or a safe static
discriminator. Example:

```
routeKey · Scaffold#0 · Row#0 · [item] · Button#0 {label:"Continue"}
```

> Open item (tracked in §11): the exact denylist/allowlist of canonical types. It must be
> pinned and versioned before implementation, because changing it changes every fingerprint.

### 4.2 Route key (mandatory, deterministic fallback chain)

`routeKey` anchors every path, so it is **not** optional. `Route.settings.name` is null in
most real apps, so we define a fixed resolution order and take the first that yields a
stable value:

1. `Route.settings.name`, when non-empty and not a default/anonymous value.
2. **Structural route signature:** the canonical fingerprint tree of the route's top-level
   actionable skeleton, hashed. Deterministic for a given screen on a given build; this is
   the default for unnamed routes and replaces today's brittle `runtimeType`/name fallback.

The chosen tier is recorded and feeds the confidence floor (a structural route key caps the
route at `medium`). `modalOpen`/`keyboardOpen` remain state attributes, not part of
`routeKey`.

### 4.3 List/scroll collapse — index-collapsing, discriminator-preserving

Collapse only the **positional index**, never meaningful content. A descendant of a
`Scrollable`/`Sliver*`/`ListView`/`GridView` becomes the token `[item]` (so row number and
list length don't matter), **but** any safe static discriminator inside that item (§4.4) is
preserved on the token:

```
[item:<hash of "Pro plan">]    ≠   [item:<hash of "Basic plan">]
[item]                         ==   [item]            // no safe discriminator → same identity, low confidence
```

This keeps product selectors, menus, and onboarding option lists distinguishable while
still aggregating "tapped a feed card." A pure `[item]` with no discriminator is explicitly
**low confidence** — ingestion must not treat such collapsed taps as a unique choice.

### 4.4 Static discriminator (conservative)

Fold a normalized label/icon into a token **only when very likely static** (must pass all):

- short (≤ ~24 chars), single line;
- not purely/dominantly numeric; no digits-with-separators (dates, money, counts, ids);
- no dynamic markers (emails, urls, `@handles`, UUID-like);
- not inside a `PmkitSensitive` subtree.

Labels and icons are inspected transiently only for this discriminator decision and are
never retained in anchors or telemetry. Rationale for conservative: a false "static"
classification fragments one element across users (breaks aggregation); a missed-but-static
label only weakens uniqueness, which structure usually still resolves.

### 4.5 `PmkitTag` — new public API

`PmkitTag` is a public marker in `markers.dart` and the package exports:

```dart
class PmkitTag extends StatelessWidget {
  const PmkitTag(this.id, {required this.child, super.key});
  final String id;          // stable, developer-owned identity
  final Widget child;
}
```

A `PmkitTag` (or a `ValueKey<String>`) on/above an element emits a separate
`tagFingerprint`. It never enters the canonical path, route key, target fingerprint, or
state signature. This makes tags purely additive and safe to add after sessions exist.

### 4.6 Confidence model (matches are weighted, not truths)

Every fingerprint carries a `confidence`, and ingestion treats it as a weight, never as
ground truth:

- **high** — an explicit `PmkitTag`/`ValueKey<String>` alias.
- **medium** — clean structural path + safe static discriminator; or structural route key.
- **low** — structure only, ambiguous repeated siblings, or `[item]` with no discriminator.

The final confidence is the **floor** across the element's route key, path normalization,
and discriminator availability. Low-confidence fingerprints are still emitted and joined,
but the ingestion side may require corroboration (screenshot dedup, neighbor agreement)
before asserting a unique state/flow.

### 4.7 Keys and metadata (kept separate)

Three distinct fields — deliberately not conflated:

- **`apkSha256`** — the *build* identity. Already in the run manifest. Defines which content
  graph a production event may join against.
- **`fingerprintSchemaVersion`** — the *algorithm* version (canonical-tree denylist,
  tokenization, discriminator rules, hashing). Bumped whenever the computation changes.
- **Join key fields** on each event: `{ stateSignature, targetFingerprint, confidence }`.

Derived/emitted shape:

```
event.meta      = { apkSha256, fingerprintSchemaVersion, platform, sessionId }
targetFingerprint = hash(routeKey | canonicalPath)
tagFingerprint    = hash(routeKey | tag) // optional alias
stateSignature    = hash(routeKey | sorted(set of actionable canonicalPaths))
```

`fingerprintSchemaVersion` is serialized as metadata but intentionally excluded from both
hashes. A collector can decide whether identities from a given algorithm version remain
compatible instead of treating every algorithm revision as a UI identity change.

`PmkitTag` is transparent to canonical paths and route fallback. Adding one therefore does
not change an existing target fingerprint or state signature; it only adds `tagFingerprint`
as a durable alias for future matching.

Note: the safe static discriminator is hashed before being embedded in the path token
(`[item:<labelHash>]`, see §4.3/§4.4), so it propagates to every descendant of a list row
without retaining or transmitting the source label.

### 4.8 Serialized payload — the skeleton is hash-only (schema v4)

The canonical target path and the full actionable-path skeleton are *determinants* of
identity. The full state skeleton can be kilobytes per event and adds no information the
hash doesn't already encode, so since `fingerprintSchemaVersion = 3` it is computed in-SDK
for the hash only and never serialized. The target path is sent separately as
`targetAnchor.canonicalPath` to make individual interactions debuggable. Each event ships:

- `signature` / `fingerprint` — the 16-char hashes (the join key).
- `signatureConfidence` / `fingerprintConfidence`.
- `signatureParts` / `fingerprintParts` — slimmed to `{ schemaVersion, routeKey }` plus
  `tag` (when an element is tagged) and the `keyboardOpen`/`modalOpen`/`subLabel` flags.
- `targetAnchor.canonicalPath` — the target's canonical structural path, retained as
  diagnostic evidence even when an explicit tag supplies the fingerprint identity.

This keeps `tap_settled` events compact while exposing the path for the single interacted
target. If the full state skeleton is ever needed for debugging, it should be gated behind
an explicit verbose capture profile (§3), not shipped by default.

The enclosing session telemetry uses schema v6. It removes all state/target label arrays,
stores navigation strings only in `route_change.data` as `fromRoute`, `route`, and
`navigation`, and removes the session route dictionary. v6 readers reject missing or older
session schema versions; there is no compatibility normalization or dual writing.

**v3 corrected two list-collapse defects found in real captures:**

1. `[item]` was emitted once *per retained level*, producing `[item]/[item]/[item]…` chains.
   It now collapses to a single token per row; descendants resume normal tokenization and
   only a *nested* scrollable re-enters list mode.
2. The denylist matched raw `runtimeType.toString()`, so generic widgets
   (`BlocProvider<AuthBloc>`, `BlocBuilder<…>`, `PopScope<Object>`) and common
   layout/transition/scroll-plumbing wrappers (`Container`, `Row`, `Stack`, `SlideTransition`,
   `Viewport`, `Sliver*`, `AutomaticKeepAlive`, `IndexedSemantics`, …) leaked into the path.
   Generic args are now stripped before matching, the denylist is expanded, and only the
   `Scrollable` primitive arms list mode (so its own token isn't mistaken for an `[item]`).

The full correlation key is `(apkSha256, fingerprintSchemaVersion, signature)`. Build
identity and schema version live **beside** the hash; neither is mixed into the hash input.
Ingestion
joins only across matching `apkSha256` **and** `fingerprintSchemaVersion`, and diffs/remaps
across builds rather than churning.

**v4 makes capture reflect the currently usable UI:** each resolution builds a
fresh canonical tree, drops offstage/hidden/zero-opacity/off-viewport nodes,
and uses `BlockSemantics` at the owning overlay to discard routes obscured by a
modal. It also accepts an optional generated `Map<Type, String>` so public
source-level widget names can replace obfuscated runtime names. These changes
alter fingerprints, so v3 and v4 evidence are never joined directly.

**Obfuscation invariant:** with `--obfuscate`, canonical type names are renamed but stay
consistent within a build, so paths still match as long as the graph was built from the
*same* APK (`apkSha256`). Ingestion enforces this.

### 4.8 CLI graph join (`pmkit_cli`)

- State node id becomes `stateSignature` (not LLM title/controls).
- Transition identity becomes `(fromSig, targetFingerprint, toSig)`.
- LLM `title`/`controls`/`summary` demoted to human-readable decoration on the stable node.
- A production event `{apkSha256, fingerprintSchemaVersion, stateSignature, targetFingerprint, confidence}`
  maps directly onto a graph node/edge, weighted by `confidence` → "user walked this flow."

## 5. Screenshots — keep, but cheap

- **Cadence:** capture on settled **state change** only (new `stateSignature`), not on
  every scroll sample / pointer event.
- **Codec & size:** adaptive low pixel ratio; encode WebP/JPEG (or ship raw RGBA and encode
  off-device) instead of PNG on the UI isolate.
- **Dedup:** cheap perceptual/structural hash (downsampled grayscale dHash) before encode;
  skip identical screens.
- **Two tiers:** thumbnails inline with events for hypothesis checks; full-res only for
  new/unique states.
- **Off the UI isolate** where possible; never block input. The capture queue already
  serializes — it must also yield to frames.

## 6. Performance hardening

Concrete hot paths in the current code and the fixes:

- `AnchorResolver._elementForRenderObject` does a **full widget-tree walk per hit-test
  entry on every pointer-down** (O(tree × path)) — on the input path. Replace with ancestor
  traversal from the hit RenderObject, or a render→element cache.
- `buildStateAnchor` walks the **entire on-stage tree on every settle/route/state refresh**
  — make incremental/budgeted, cache per-frame, bail past a node cap.
- `ScreenshotCapturer` PNG encode + sha256 on the UI isolate — see §5.
- `_collectMaskRects` is another full-tree walk — fold into the single traversal used for
  the state anchor.
- **Dormant ≈ 0 (real work, not a flag):** today's `wrapApp` always builds the controller,
  schedules `start()`, installs `InputCapture`, and adds a `RepaintBoundary` +
  `NotificationListener` even with no session. Activation gating must construct none of these
  until `activate(...)`; dormant is a pass-through of `child`.
- **Self-instrumentation:** the SDK measures its own per-interaction time and frame impact
  (via `SchedulerBinding.addTimingsCallback`), emits a `pmkit.overhead` signal, and
  auto-sheds to a leaner profile if it exceeds a budget. This is how we continuously "keep
  an eye on it" instead of guessing.

## 7. New signals

All feasible with standard Dart/Flutter hooks; caveats noted. Each is keyed to
`(sessionId, stateSignature, actionId)` so it lines up with the interaction and graph node.

- **Logs.** Wrap startup in `runZonedGuarded` with a `ZoneSpecification.print` override to
  capture `print`/`debugPrint`; hook `FlutterError.onError` + `PlatformDispatcher.onError`
  for crashes. Ring-buffered, redacted. (Won't auto-capture `dart:developer.log` without a
  shim.)
- **Network.** Install `HttpOverrides.global` around `dart:io` `HttpClient` — transparently
  covers `package:http` and Dio on mobile. Capture method/host/path/status/timing/sizes;
  **bodies off by default**. Optional first-class Dio/Chopper interceptors for richer data.
  Caveat: native-side HTTP / gRPC needs per-stack adapters.
- **Performance.** `SchedulerBinding.addTimingsCallback` → per-frame build/raster durations
  (jank, dropped frames, slow screens), attributable to a `stateSignature`. Coarse memory
  via `dart:developer` / `ProcessInfo`; optional Timeline spans. Doubles as the
  self-overhead budget (§6).
- **Analytics tap-in**, recommended in order:
  1. `NavigatorObserver` for route/screen events (formalize what we already have).
  2. Bridge API `Pmkit.recordAnalytics(name, props)` + thin adapters for
     Firebase/Segment/Amplitude/PostHog (one-line mirroring of existing events).
  3. *Experimental:* intercept the platform `BinaryMessenger` to passively sniff plugin
     channels (e.g. Firebase Analytics' method channel). Possible but version-fragile —
     prototype, do not depend on it.

## 8. Production activation & transport

- **Activation config** (runtime, since released APKs can't take `--dart-define`):
  - Android: `adb am start -n <pkg>/.MainActivity --es pmkit_session <id> --es pmkit_sink <endpoint> --es pmkit_profile exploration`. A small native hook (bundled in the SDK) reads intent extras and calls `Pmkit.activate(...)`.
  - Alternative: deep link (`app://pmkit/capture?...`) handled by the same hook.
  - In-the-wild: activated by the app's own remote config / feature flag with
    `production-lean`.
- **Sinks** (pluggable, replace hard websocket dependency):
  - `WebSocketSink` — keep for interactive dev exploration (current behavior).
  - `FileSink` — append-only NDJSON + blob files under the session id, mirroring the CLI
    run-store layout; pulled via `adb pull`.
  - `HttpBatchSink` — batched, gzipped uploads with retry/backpressure for at-scale prod.
- **Backpressure & sampling:** bounded queues; drop/sample under load (lean profile);
  never grow unbounded or block the app.

## 9. Privacy & safety

- Screenshots: `PmkitSensitive` always masks. Exploration otherwise remains
  explicit-only; `productionLean` defaults to masking text, editable fields,
  and images. Configurable policies can narrow this to sensitive inputs or
  leave actionable labels visible.
- Network: allowlist-based; headers/bodies off by default; redact tokens.
- Logs: redaction pass before buffering.
- Fingerprints: never include raw user text (by design — conservative discriminator).
- Body/PII capture is explicit opt-in per customer.

## 10. Phasing

Phase 1 is deliberately **narrow**: prove the join key is stable and cheap before adding any
new signal streams. Do **not** mix in logs/network/analytics until phase 1 passes its
measurement gate (§10.1).

1. **Fingerprint v2 + join (narrow)** in `pmkit` + `pmkit_cli`:
   - canonical fingerprint tree (versioned wrapper denylist, ordinal-after-filter);
   - mandatory `routeKey` with the §4.2 fallback chain (incl. structural route signature);
   - index-collapsing, discriminator-preserving `[item]` (§4.3);
   - conservative static discriminator (§4.4);
   - `PmkitTag` new public API (§4.5);
   - separated metadata: `apkSha256`, `fingerprintSchemaVersion`, join-key fields (§4.7);
   - confidence on every fingerprint (§4.6);
   - `pmkit_cli/graph.ts` joins on `stateSignature` / `(fromSig, target, toSig)`.
   - **Excludes** logs, network, analytics, new sinks, screenshot overhaul, perf rework.
2. **Activation gating + perf hardening** — real dormant-zero (rebuild `wrapApp`), remove
   full-tree walks, capture profiles, self-overhead signal.
3. **Pluggable sinks + session-id activation** — intent-extras/deep-link hook, `FileSink`,
   `HttpBatchSink`; keep websocket for dev.
4. **Screenshot cost overhaul** — cadence, codec, dedup, off-isolate.
5. **New signals** — perf → logs → network → analytics bridge/adapters.

### 10.1 Phase-1 measurement gate (acceptance criteria)

Phase 1 is not "done" until, on a **single released APK**:

- Running the same flow **twice** produces **identical** `stateSignature` and
  `targetFingerprint` for the same screens/elements.
- Stability holds across **dynamic data and varied list sizes** (different feed content,
  different item counts) — signatures must not change.
- A known set of **distinct** elements/screens produce **distinct** fingerprints (no
  collisions at `medium`+ confidence).
- `--obfuscate` build: signatures are self-consistent within that build, and an offline
  graph built from the same APK joins production-style events.
- Confidence is assigned correctly: tagged → high, structural+discriminator → medium, bare
  `[item]`/ambiguous → low.

Measure churn on real `mobile_app` screens; only then decide how hard to push tags.

## 11. Open questions

- **Canonical-type denylist/allowlist** (§4.1): exact set to pin and version. Highest-risk
  open item — changing it changes every fingerprint.
- **Cross-build remap** in ingestion: graph-diff granularity when `apkSha256` changes.
- **Stable ordinal under conditional rendering**: quantify churn on real screens; how
  aggressively to recommend tags for high-value targets.
- **`[item]` choices that matter but lack a safe discriminator** (icon-only options,
  image-only cards): per-item tag, or accept low confidence + screenshot corroboration?
- **Route key for nested navigators / tabs / dialogs**: confirm the §4.2 chain covers
  `PmkitSubView`, modal routes, and tabbed shells.
