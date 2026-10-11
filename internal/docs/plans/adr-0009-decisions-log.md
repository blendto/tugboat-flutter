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
| 2026-10-12 | `capture-runtime` 0.2.0 (unpublished): additive window capture, `capture(window, …)` with `WindowComposite` coverage. `SecureWindow` and `WindowComposite` are appended enum values. The Flutter plugin stays pinned to 0.1.0. | Native SDKs need app-window pixels; the Flutter path is unchanged (PR #84) |

## Gates before merging to main

1. On merge to `main`, `publish-android.yml` (`tag_main`) auto-tags and
   publishes `capture-runtime` 0.2.0, then opens an automatic Flutter pin PR.
2. That pin PR will not compile until `TugboatPlugin.kt`
   `CaptureStatus.toPigeon()` / `CaptureCoverage.toPigeon()` handle
   `SecureWindow` and `WindowComposite`, and Pigeon/Dart decide what
   `secureWindow` maps to. Someone must own that change, with a `tugboat`
   version bump, before or together with the `main` merge.
3. The instrumented window-capture tests
   (`:capture-runtime-test:connectedAndroidTest`) must have run on an
   emulator or device.

## Open cross-repo questions

- **Q2: wire idempotency.** Batches, frames and lifecycle posts need an
  idempotency key the collector deduplicates on before a durable outbox or
  retry backoff (C4) can ship.
