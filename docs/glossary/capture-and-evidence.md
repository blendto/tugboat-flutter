# Capture and evidence

Status: current · Last verified: 2026-09-05

**Capture** — the SDK's recording of what happens in the host app: routes,
interactions, screenshots, and metadata, assembled for downstream analysis.

**Evidence** — the umbrella for everything the SDK emits. Optional evidence
kinds ("capabilities"), each independently togglable and **false by default**:

- **scene inventory** — the widget/element inventory of a screen;
- **semantic-map** — structural screen evidence;
- **action-context** — extra context attached to user actions;
- **diagnostic** — SDK health/debug evidence.

Core capture (routes, interactions, masked screenshots) is not optional when
enabled; capabilities are additive.

**`TugboatReplay`** — the integration surface: `TugboatReplay.wrapApp` installs
the controller, repaint boundary, input capture, scroll listener, and lifecycle
observer; `TugboatReplay.navigatorObserver` supplies route changes. **Both are
required** — either alone gives incomplete capture.

**`TugboatReplayController`** — the in-app orchestrator feeding the in-memory
session; hosts three sub-systems: viewport semantic session, masked screenshot
capturer, structural anchor resolver.

**Session JSON schema 10** — the current wire schema version of the emitted
session evidence (see `docs/README.md` "Current compatibility").

**Sink hub** — the failure-isolated dispatch point for evidence; consumers are
the exploration WebSocket and the HTTP Collector. Sink failures must never
break the host app.

## SDK layers (ADR 0009, proposed)

**Session engine** — the I/O-free, single-threaded state machine that owns
the session, event sequencing, dedup decisions, collector record mapping,
and delivery policy. One implementation in the C++ core, shared by every
adapter.

**Platform host** — the native per-OS layer (Kotlin, Swift) that drives the
session engine and executes its effects: threads, timers, lifecycle, the
durable outbox, and network I/O. Flutter and React Native adapters forward
their facts to it.

**Toolkit adapter** — the per-UI-toolkit layer that turns a view tree into
identity parts, route keys, mask geometry, and input targets.

**Toolkit** — the UI framework an anchor came from: `flutter`, `view`,
`compose`, `uikit`, `swiftui`, or `react-native`. Namespaces identity; never a
hash input.

**Conformance fixture** — a reviewed JSON case under `conformance/` pairing
engine inputs (identity parts, recorded events, session facts) with the exact
expected output. Every engine implementation must match them; tests read
them and never regenerate them.
