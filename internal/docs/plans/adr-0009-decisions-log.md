# ADR 0009 decisions log

Working notes, not product docs ([publishing policy](../../../docs/publishing.md)).
Decisions taken while building the shared session engine and the native
SDKs on the `adr-0009-shared-engine` branch. Rule for this milestone: when a
choice would change shipped behaviour (Flutter fingerprints, existing event
fields, the `capture-runtime` / `TugboatCaptureRuntime` ABI, Flutter
defaults), take the option that leaves it unchanged and record it here.

## Milestone

Native Android (Views + Compose) and SwiftUI SDKs on the session engine, each
with an in-repo sample app, sending real sessions to a local collector and
passing device tests on the emulator and simulator. The Flutter adapter keeps
its Dart path unchanged. No publishing and no merges to `main`.

## Log

| Date | Decision | Why |
| --- | --- | --- |
| 2026-10-12 | Stateful engine design accepted: C1–C3, C5, C6 (records; event-lane gaps opt-in, default off), C9–C12 yes; C4 later; C7 and C8 keep. Changes apply to the engine only; scenarios encoding them are `engineOnly`. | Design review of PR #80 |
| 2026-10-12 | Q1: Flutter moves onto the engine after 3d behind an opt-in flag, in a later milestone; no delivery-only mode. | Keeps one id authority; Flutter behaviour unchanged this milestone |
| 2026-10-12 | Q2 deferred; phase 3e (durable outbox) out of this milestone; native hosts deliver from memory. | Needs a collector-side idempotency key (cross-repo) |
| 2026-10-12 | Q3: 202-only acceptance stays. Q4: exploration WebSocket stays host-side and is not needed by native SDKs. Q5: limits config-driven with today's defaults; no snapshot export required on native. | Design review of PR #80 |
| 2026-10-12 | C9 redefined: event-producing facts after `session_end` are accepted and dropped (no record), symmetric with facts before the first session. A batch is never rejected because a late fact shares it with `session.end`; batch atomicity covers malformed or invalid messages only. Engine-only; approved by local orchestrator 2026-10-12. | Late facts are routine behind an asynchronous seam; rejecting them poisoned whole batches and returned errors for normal host behaviour (review of PR #82) |
| 2026-10-12 | New C13: facts stamped before their session started record `atMs` 0. Engine-only; approved by local orchestrator 2026-10-12. | Asynchronous-seam skew can deliver a fact stamped before `session.start`; this is not C1 (which is about the wall clock) |
| 2026-10-12 | Section 11 change ids live once, in `conformance/change_ids.json`, read by both the C++ and Dart fixture runners. | Two hand-kept copies drift when a change id is added |
| 2026-10-12 | Fixtures gain `runners` (`cpp`, `dart`; default both). `engineOnly` stays strictly for section 11 change ids and implies `cpp` only. The Dart runner reports an unmodelled message as a failure, never a silent skip. | Phase 3c/3d scenarios cannot drive Dart without claiming a behaviour change |
| 2026-10-12 | `legacy_projection` is rejected as an `event.record` stream; the engine accepts schema 10 streams (`semantic`, `evidence`, `diagnostic`) only. | Dart session schema 10 removed it; the collector's wider accepted set is not a reason to emit it |
| 2026-10-12 | `exploration.actionWindow` (action window events and `actionId` stamping) is deferred beyond this milestone; no engine code. | Native SDKs do not use exploration |
| 2026-10-12 | `capture-runtime` 0.2.0 (unpublished): additive window capture, `capture(window, …)` with `WindowComposite` coverage. `SecureWindow` and `WindowComposite` are appended enum values. The Flutter plugin stays pinned to 0.1.0. | Native SDKs need app-window pixels; the Flutter path is unchanged (PR #84) |
| 2026-10-12 | Flutter plugin compiles against `capture-runtime` 0.1.0 and 0.2.0: newer statuses (0.2.0 `SecureWindow`) map to the existing `cancelled`, `WindowComposite` to the existing Pigeon `windowComposite`; no Pigeon, Dart API or behaviour change (`tugboat` 0.10.11-dev.2). CI compiles the plugin against the pinned and the local runtime. | `cancelled` = no Dart fallback, no publish; a fallback status would let RepaintBoundary capture a screen the runtime refused. Keeps the automatic pin PR buildable after the main merge |
| 2026-10-12 | New C14: the engine's pointer tracker forgets every contact on every teardown cause, not only on `paused`/`hidden`/`detached` as the Flutter widget does. Engine-only; decided during the phase 3c review (PR #87). | After `session_end` facts are dropped (C9), so a contact held across a session boundary could never lift and would join the next session's gestures |

## Gates before merging to main

1. On merge to `main`, `publish-android.yml` (`tag_main`) auto-tags and
   publishes `capture-runtime` 0.2.0, then opens an automatic Flutter pin PR.
2. That pin PR compiles: the plugin maps 0.2.0's `SecureWindow` to
   `cancelled` and `WindowComposite` to the existing Pigeon value
   (`tugboat` 0.10.11-dev.2), and `android-runtime.yml` compiles the plugin
   against the pinned and the local runtime. The `main` PR description must
   still say that merging publishes `capture-runtime` 0.2.0; the owner
   decides at merge time.
3. The instrumented window-capture tests
   (`:capture-runtime-test:connectedAndroidTest`) must have run on an
   emulator or device. CI runs them on API 26 and 34
   (`android-runtime-device.yml`).

## Open cross-repo questions

- **Q2: wire idempotency.** Batches, frames and lifecycle posts need an
  idempotency key the collector deduplicates on before a durable outbox or
  retry backoff (C4) can ship.
