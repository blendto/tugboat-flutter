# ADR 0009: Shared session engine for all adapters

Status: Proposed
Date: 2026-10-08

## Context

Tugboat will ship full capture SDKs for native Android (Views, Compose),
native iOS (UIKit, SwiftUI), and React Native, not only the Flutter
adapter. Today the native runtimes are pixel pipelines for the Flutter
engine surface. Everything else — session model, interaction transactions,
frame dedup, collector mapping, batching, flush, delivery-gap accounting,
health — is about 8k lines of Dart inside `package:tugboat`, and it is the
part that changes most often (0.10.8 dedup, 0.10.9 delivery gaps).
Porting it to Kotlin and Swift would mean every engine change ships three
times and drifts.

Target identity cannot be shared: each UI toolkit has its own tree, so
canonicalization is per toolkit regardless of where the engine lives.

## Decision

Split every SDK into four layers:

| Layer | Owns | Implemented |
| --- | --- | --- |
| Session engine | Session model, event sequencing, interaction transactions, frame dedup decisions, collector record mapping and serialization, batching and delivery-gap policy, fingerprint hashing of supplied identity parts | Once, in the C++ core behind a versioned C ABI |
| Platform host | Threads, timers, lifecycle and launch signals, durable outbox, HTTP and WebSocket I/O, device metadata | Kotlin and Swift only, for every adapter |
| Toolkit adapter | Canonical identity parts, route key, mask geometry, input hit-testing | Per toolkit: Flutter, View, Compose, UIKit, SwiftUI, React Native |
| Pixel runtime | Surface capture, mask fill, dHash, JPEG, SHA-256 | Existing core and platform runtimes |

The session engine is single-threaded and performs no I/O. The host drives
it through one serialized queue; the engine returns records and effect
requests (send this batch, schedule a flush) for the host to execute. This
keeps the existing invariant that capture and sink failures never reach the
host app, and makes the engine testable without a device.

The platform host is native for every adapter, including Flutter and
React Native. Process lifecycle, launch source, exit reasons, and
background-capable delivery are only reliable from the OS layer, and one
host per OS gives hybrid apps (native screens hosting Flutter or RN views)
one session and one outbox. The outbox persists to disk so evidence
survives process death within its bounds.

The Flutter adapter moves onto the engine. Dart keeps only the Flutter
toolkit adapter (anchor resolution, masks, pointer and scroll input,
navigator events) and forwards its facts to the native host;
`TugboatReplayController` is decomposed accordingly and the Dart HTTP and
WebSocket sinks retire.

React Native computes target identity in JavaScript from the React tree
(component type, `testID`, navigation route), so an RN app's iOS and
Android builds produce the same fingerprints. JavaScript sends identity
parts and mask rectangles to native. Raw pixels, the engine, and transport
stay native; raw pixels never enter JavaScript.

Anchors gain a `toolkit` field (`flutter`, `view`, `compose`, `uikit`,
`swiftui`, `react-native`). It is not a hash input, so existing Flutter
fingerprints are unchanged. Consumers namespace identity by build metadata,
`fingerprintSchemaVersion`, and `toolkit`.

Cross-language golden fixtures (event inputs to expected collector records,
identity parts to fingerprints) are the conformance gate for the engine and
every adapter.

## Considered options

- **Port per platform** (Kotlin and Swift engines beside Dart). Fastest to
  start; three implementations of a fast-moving contract held together
  only by fixtures.
- **Kotlin Multiplatform.** Because every adapter reaches the engine
  through a native host, KMP could also serve Flutter and RN. Rejected
  because it adds a Kotlin/Native runtime and toolchain to every iOS app
  and a second packaging story beside the C++ core that both runtimes
  already ship (ADR 0002). Revisit if the engine grows I/O or concurrency
  that C++ makes costly.
- **Rust behind a C ABI.** Better ergonomics for JSON and state machines,
  but a second native toolchain. ADR 0002 already allows Rust to replace
  core internals later without changing the ABI.

## Consequences

- The C ABI grows from pixel processing into the session contract. It
  becomes the main compatibility boundary, and ABI changes are contract
  changes in the sense of `AGENTS.md`.
- The engine ships inside the platform runtimes; adapters still never
  compile the core (ADR 0003). Engine changes bump the runtime and then
  each adapter, so the compatibility table carries more weight than under
  ADR 0008.
- The adapter-to-host seam (Pigeon for Flutter, the RN bridge for
  JavaScript) carries every pointer, scroll, navigation, and anchor fact.
  It is batched and asynchronous and stays off the UI thread's critical
  path.
- `package:tugboat` host tests need the core built for the host OS, or an
  engine fake behind the adapter-to-host seam.
- Public Dart extension points keep working: `TugboatCaptureSinkFactory`
  sinks receive engine records forwarded from the host, and `tugboat_dio`
  submits network evidence to the host instead of the Dart controller.
- The native host outlives a Flutter hot restart or a recreated RN bridge;
  the adapter must re-attach to, or explicitly end, the running session.
- A persistent outbox changes sink behavior (in-memory queues no longer
  vanish on process death). It is a contract change and needs its own
  bounds, retention, and privacy rules before it ships.
- Native SDKs are new artifacts distinct from `capture-runtime` and
  `TugboatCaptureRuntime`, which stay pixel-only. Coordinates are decided
  when the first native SDK is scheduled.
- `docs/design/capture-and-fingerprint.md` gains one canonicalization
  section per toolkit; the hash function and confidence levels stay shared.
- Hybrid apps produce anchors from more than one toolkit in one session;
  the `toolkit` field keeps them separable.
- Evidence the native host enables — launch source, exit reason, OS-level
  network, system events, transition performance — reaches Flutter and RN
  apps too. Each new event type is opt-in until the collector accepts it.
