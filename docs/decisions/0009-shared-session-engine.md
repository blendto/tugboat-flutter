# ADR 0009: Shared session engine for all adapters

Status: Proposed
Date: 2026-10-08
Amended: 2026-11-26 (see "Amendment: external review")

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

## Amendment: external review (2026-11-26)

We checked this decision against how established mobile session-replay and
error-reporting SDKs are built, mostly from their public documentation.
Each finding below was checked by several independent reviewers. The
decision stands. This section records what the review confirmed, what it
could not confirm, and the rules it adds.

### What the review confirmed

- **Screenshots, masked before encoding.** Mobile replay SDKs record
  screenshots. One that offered wireframe replay removed it from its native
  SDKs and now always records masked screenshots, because Compose screens
  showed up as empty boxes under wireframe. The pixel runtime stays a core
  layer.
- **Masking on the device, everything masked by default.** The SDKs we
  reviewed mask text, images, inputs and web views by default, and none
  sends masked content off the device.
- **Masking APIs that suit each toolkit.** The SDKs we reviewed give
  Compose, SwiftUI, Flutter and React Native their own masking API over one
  privacy model. At least one ships Compose support as a separate package
  that plugs into its core.
- **A short snapshot on the UI thread, everything else elsewhere.** One SDK
  reports about 3 ms per capture on the UI thread, with all processing on a
  background thread. That is the vendor's own figure.
- **Golden fixtures in a neutral format.** Our `conformance/` suite already
  follows this pattern. It is also what makes replacing engine internals
  (for example with Rust) behind the same C ABI safe.

### What the review could not confirm

- **A shared core is uncommon.** The SDKs whose internals are documented
  ship one native SDK per OS and wrap it for Flutter and React Native. The
  only shared-core example found is a Rust core described publicly in 2020.
  Our reason for a shared engine, that one contract shipped three times
  will drift, is our own. This review neither supports nor refutes it.
- **Kotlin Multiplatform and Rust.** No verified evidence covered binary
  size, startup cost or toolchain cost. Rejecting them rests on the
  reasoning above. We measure our own release size and cold-start cost per
  ABI and per architecture before the first public native release, and
  revisit this choice if the numbers call for it.

### Rules this amendment adds

1. **One privacy model, a masking API per toolkit.** The masking levels and
   how an override inherits from the nearest ancestor are defined once, as
   a contract shared by every adapter. Each toolkit exposes it through its
   own idioms: a modifier in Compose, a view modifier in SwiftUI, a widget
   in Flutter, a component in React Native. An adapter that cannot place a
   mask masks more, never less.
2. **A time budget on the UI thread.** Each adapter's work on the UI thread
   per capture and per input event has a stated budget, held by a benchmark
   in that adapter's tests. Everything past the snapshot runs on the host's
   threads.
3. **Consent states in the outbox.** The host outbox supports three states:
   not granted (nothing is written to disk), pending (written to an area
   that is never uploaded), and granted (uploadable). Moving from pending
   to granted makes pending data uploadable, and moving to not granted
   deletes it. This is separate from activation (`activate` / `deactivate`):
   activation decides whether a session runs, and consent decides whether
   its evidence may be stored or sent. Whether outbox files are encrypted
   at rest is decided before the outbox is on by default. This is a sink
   behaviour change.
4. **React Native masks keep a native view.** The React Native mask
   components are native views that cannot be flattened (for example,
   `collapsable={false}`). React Native's view flattening can otherwise
   remove a mask view from the native hierarchy and expose what it covered.
   If a mask's native view cannot be found, the frame is masked whole.
   Device tests run with the New Architecture (Fabric) both on and off and
   check that masked regions are masked in the captured frame.
5. **Flutter reaches the engine through the host.** The Dart adapter talks
   to the native host through Pigeon, never to the engine or the pixel
   runtime through `dart:ffi`. iOS release builds can strip the symbols
   that FFI needs, so an FFI path would force apps to change their strip
   settings. If a direct FFI path is ever added, the exported symbols are
   guaranteed and CI builds and runs an iOS release archive.
6. **Toolkit adapters ship as optional artifacts.** Compose, Views, UIKit,
   SwiftUI and the HTTP-client adapters are separate packages that register
   with the host. An app pulls in only the toolkits it uses.
7. **Crash-time code never runs in the engine.** Errors that a framework
   reports to the app (Dart, Kotlin, Swift, JavaScript) are ordinary
   evidence that goes through the engine. A fatal crash is reported by the
   host on the next launch, from the OS exit-reason APIs:
   `ApplicationExitInfo` on Android, with the session id stored through
   `setProcessStateSummary`, and MetricKit on iOS. If an in-process crash
   handler is ever added, it is a separate, minimal C module that follows
   async-signal-safe rules, chains to existing handlers, leaves the OS crash
   report intact, and is off by default. Error and crash reporting gets its
   own ADR.

### Sources

The vendor-by-vendor review is kept outside this repository. Platform
references:

- Android `ApplicationExitInfo`:
  https://developer.android.com/reference/android/app/ApplicationExitInfo
- Apple Developer Forums, guidance on in-process crash reporters:
  https://developer.apple.com/forums/thread/113742
