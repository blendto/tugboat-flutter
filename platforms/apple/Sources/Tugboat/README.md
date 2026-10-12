# Tugboat (Swift host)

Native Apple host for the session engine
([ADR 0009](../../../../docs/decisions/0009-shared-session-engine.md)).
SwiftPM product and module `Tugboat` in the root `Package.swift`, iOS 15+,
depending on the internal `TugboatSessionEngine` target. Unpublished: no
podspec yet (it will be `TugboatSDK`, module `Tugboat`).

Status: platform plumbing only. There is no public API and no toolkit adapter
yet; every Swift type is internal. It mirrors the Android host in
`platforms/android/tugboat-android`.

## What it contains

| Piece | Where | Role |
| --- | --- | --- |
| Bridge | `Engine/EngineBridge` | Owns one `tb_session_engine` handle and calls the C ABI directly (no Objective-C++). `submit` copies the engine-owned response into `Data` before returning. `EngineStatus` mirrors `tb_session_status`. |
| Host | `Host/EngineHost` | Owns the bridge and one serial `DispatchQueue` (`tugboat.engine`). See the threading notes below. |
| Messages | `Host/EngineMessage`, `HostMessages` | Envelopes built by concatenation around the caller's `input` JSON, which is never parsed or re-encoded. |
| Clock | `Host/HostClock` | `monoUs` from `ProcessInfo.systemUptime` (the clock of `UIEvent.timestamp`), `wallUs` from `Date()`. |
| Effects | `Host/Effect`, `EffectParser`, `EffectDispatcher` | Each response is decoded once (`JSONSerialization`) into typed effects, run in order. `capture.request` is known but not handled until the toolkit adapters land; it and unknown types are logged once per type. |
| Timers | `Host/TimerExecutor` | One `DispatchSourceTimer` per id on the engine queue, deadline `DispatchTime(uptimeNanoseconds:)` from `atMonoUs`. Rescheduling replaces. |
| Frames | `Host/FrameHandleTable` | Thread-safe store of JPEG bytes behind never-reused opaque handles. |
| HTTP | `HTTP/HTTPExecutor`, `HTTPSessionDelegate`, `MultipartBody` | Ephemeral `URLSession` with its delegate queue on `tugboat.io`. Same collector headers and multipart bytes as the Android host and the Flutter `CollectorHttpSink`. `jsonBody` is sent byte for byte. `timeoutMs` is a total deadline (watchdog), redirects are reported and not followed, and the response body is capped at 64 KiB. |

`EngineHost` threading and failure rules:

- `post(type:inputJSON:at:frameHandles:)` and `postBatch(_:)` can be called
  from any thread. Callers pass the time the fact happened.
  `postUntimed(type:inputJSON:)` is for `engine.configure`, queries, and
  stateless messages.
- Submits, responses, and effects run serialized on the engine queue, in post
  order. Transport results and timer fires come back as messages on it.
- A non-`ok` status is logged. The message is dropped and its frame handles
  are released.
- Three `internal_error`s in a row shut the host down: timers cancelled, IO
  closed, handle destroyed, frames freed. Posts after that (or after `close`)
  release their frame handles.
- Nothing force-unwraps external data, and no input reaches a precondition.

## Build and test

Requires Xcode. From the repository root on a Mac:

```sh
swift build --target Tugboat
xcodebuild test -scheme TugboatCaptureRuntime-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:TugboatTests
```

`TugboatTests` runs the bridge against the real engine (the
`fingerprint.labelHash` conformance fixture), the host with a fake engine and
transport, real timers, the multipart golden bytes shared with the Android
host, and the HTTP executor against a `URLProtocol` stub.
