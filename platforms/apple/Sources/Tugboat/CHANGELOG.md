# Tugboat (Swift host)

The version is `TugboatVersion.current` in `TugboatVersion.swift`; the newest
entry here must match it.

## 0.1.0

Unpublished. Platform plumbing and the SwiftUI adapter. The only public API
is the `.tugboatTag(_:)` and `.tugboatScreen(_:)` view modifiers.

- SwiftUI adapter (internal): `input.pointer` (window points, unique contact
  ids, tap evidence at the down position), `scroll`, `navigation`, and
  `focus` facts, batched once per frame; SwiftUI identity (`.tugboatTag`
  frames, UIKit roles, list index paths, `.tugboatScreen` route keys,
  `toolkit: "swiftui"`); mask rectangles for `allTextAndMedia` from UIKit
  views and a per-iOS-major SwiftUI layer allowlist (iOS 26), fail-closed
  elsewhere.

- `EngineBridge`: calls the session engine's C ABI directly through the
  `TugboatSessionEngine` SwiftPM target and copies each engine-owned
  response into `Data`.
- Engine host: one handle driven from one serial `tugboat.engine` queue.
  Facts are posted with their own `at`. A non-`ok` status drops the message
  and releases its frame handles. Three `internal_error`s in a row shut the
  host down. Shutdown first submits `engine.dispose` (the engine reports
  undelivered work), honouring its `frame.release` but starting no new IO
  or timers.
- Effect executors:
  - `timer.schedule` / `timer.cancel` (`DispatchSourceTimer` on the uptime
    clock, saturating deadlines);
  - `http.send` (ephemeral `URLSession`, the Flutter collector headers and
    multipart layout, `timeoutMs` as a total deadline, no redirects, a
    response body of at most 64 KiB cut at a UTF-8 boundary, and statuses
    outside 100–599 reported as `error`);
  - `frame.release` (frame handle table).
