# Native capture contracts

Status: accepted for the Android CPU beta
Date: 2026-08-31

This file is the behavioral spec for native CPU capture. Dart pipeline
narrative stays in
[capture-and-fingerprint.md](../design/capture-and-fingerprint.md).
Stage *names* stay in
[cpu-capture-baseline.md](../performance/cpu-capture-baseline.md).
ADRs record *why*, not a second copy of these rules.

Stop implementation if:

- Raw pixels can cross into Dart before masking
- A failure can publish an unmasked frame
- Native and Flutter paths can publish the same capture twice
- Native capture cannot keep current session and frame semantics

## Threat model

In scope: a compromised Dart isolate or plugin channel that wants unmasked
pixels; logs and crash reporters; a failed native attempt that still
publishes; a retry that publishes native and Flutter together; coordinate
mistakes that leave private widgets unmasked.

Out of scope: a compromised OS, DRM bypass, and permissioned system-wide
recording (`MediaProjection`, ScreenCaptureKit).

## Request

Dart allocates a monotonic `requestId` (`uint64`) per plugin instance.
Native is a FIFO of one in-flight capture. Different buffers are not
processed in parallel. On Android, `capture(view, …)` and
`capture(window, …)` share that one queue and one pipeline; only the
`PixelCopy` source differs.

| Field | Type | Rule |
| --- | --- | --- |
| `requestId` | uint64 | Dart-owned. Stale ids are ignored: no publish, no fallback. |
| `pixelWidth`, `pixelHeight` | int | Exact bitmap size. Equals the Dart capturer’s scaled size for this request (`capturePixelRatio`, max bounds, degraded scale). Native must not PixelCopy device pixels and hash that. |
| `force` | bool | When true, do not dHash-skip. Required so interaction frames keep session semantics. |
| `lastDHash` | 64-char `'0'/'1'` or empty | Same encoding as `computeDHashFromRgba`. Empty means “no previous”. |
| `masks` | list of `{x,y,width,height}` | Normalized CaptureBoundary local space; on window capture, the window's decor view. See Masks. |

Capture scale stays Dart-owned. If the runtime cannot map CaptureBoundary
space onto the PixelCopy bitmap, status `processingFailed` and Flutter
fallback — do not encode.

## Result

| Field | Type | Rule |
| --- | --- | --- |
| `requestId` | uint64 | Echo. Mismatch → ignore. |
| `status` | enum | Closed list below. |
| `coverage` | enum | Closed list below. Absent on non-ok / non-skip statuses. |
| `jpeg` | bytes | Masked JPEG only. Empty on `skippedByDHash`. Never raw pixels. |
| `width`, `height` | int | Bitmap pixels. |
| `dHash` | 64-char `'0'/'1'` or empty | Bit-for-bit with `sdks/flutter/packages/tugboat/lib/src/perceptual_hash.dart` on the masked RGBA buffer. |
| `contentHash` | lowercase hex SHA-256 of JPEG | Empty on skip. |
| `timings` | int microseconds | Stages in the clock table. Missing keys are zero. |
| `renderMode` | `surfaceView` / `textureView` / `hybrid` / `unknown` | Diagnostic only. Always `unknown` on window captures. |
| `incomplete` | bool | Only meaningful for `viewHierarchy`. |

The runtime does not retain JPEG or bitmap after the reply. Dart owns
`session.frameBytes` as today.

`dHash` skip uses Hamming ≤ `dHashMatchDistance` (2) unless `force`.
dHash is defined on RGBA. BGRA8888 is *sampled* as R,G,B from the BGRA
layout; the core does not physically swizzle the buffer, so a platform
JPEG encoder still sees native channel order. The core does not infer
`Bitmap.Config`; the runtime declares RGBA8888 or BGRA8888 on the ABI call.

Invalid buffers (zero size, bad stride, overflow, over limit) are
`processingFailed`. Do not clamp silently — silent clamp plus mask clip
can leave an unmasked strip.

C++ core numeric limits (`tb_image_core.h`):

- width and height in `1..8192`
- `width * height` ≤ `16_777_216`
- `stride_bytes >= width * 4`, and `stride_bytes * height` must not overflow
  `uint64`
- formats: `RGBA8888`, `BGRA8888` only

The runtime maps every core failure status onto `processingFailed`.

## Masks

Fill color `(0x1a, 0x1a, 0x1a, 0xff)` matches `_maskFillR/G/B/A` in
`screenshot_encode.dart`. Fills run on the raw buffer before dHash and
before JPEG, including on dHash-skip paths. There is no encode-then-cover
path.

Flutter discovers masks from the widget tree in **CaptureBoundary local
space** (same origin as today’s mask walk) and sends normalized rects:
`x,y ∈ [0, 1]`, `width,height ∈ (0, 1]`. Empty or non-positive sizes are
dropped before conversion.

The runtime maps CaptureBoundary local space onto the PixelCopy bitmap
(boundary origin in view pixels × scale to `pixelWidth`/`pixelHeight`).
Then, privacy-expanding, same as `applyMaskRectsInPlace`:

```text
left   = floor(x * w)
top    = floor(y * h)
right  = ceil((x + width) * w)
bottom = ceil((y + height) * h)
clip to [0, w] × [0, h]
drop if right <= left or bottom <= top
```

C ABI rectangles are inclusive-start exclusive-end integers. Overlaps stay
opaque. Never round toward unmasking. A wrong origin is a privacy failure.

On Android window capture (`windowComposite`), the mask space is the
window's decor view, which is the area `PixelCopy.request(Window, …)`
copies. Callers normalize rects against the decor view's width and height.
The mapping rule above is unchanged.

With a `WindowMaskSupplier` (`capture(window, request, masks, onComplete)`),
masks are evaluated on the main thread for the frame being copied: the
supplier runs in the same main-thread task as `PixelCopy.request`, after the
committed-frame wait and the `FLAG_SECURE` re-check, and its masks replace
`request.masks`. Layout that moves between the request and the copy
(scrolling, animations, an IME resize) therefore cannot move content out of
its mask. A supplier that throws, or reports `wholeFrame`, masks the whole
frame. `CaptureResult.maskSnapshot` returns what was applied.

The native SDK adapters (Android Views, Compose, SwiftUI) build these rects
from their mask sources. A developer `tugboatSensitive` mark adds the
marked view's bounds (Views and Compose: also each view or semantics node
below it that lies outside them) in every mask mode, during the same
synchronous mask walk. It only adds rects, never removes one, and is not an
identity input ([tagging](../integration/tagging.md#sensitive-content-always-masked)).

## Coverage

Closed: `engineSurface | windowComposite | viewHierarchy`.

| Value | First milestone |
| --- | --- |
| `engineSurface` | Android `PixelCopy` of the active `FlutterSurfaceView`, or Apple rendering of the live Flutter layer. Not the final window composition. |
| `windowComposite` | Android `PixelCopy` of one app window's surface (API 26+). Not the full-screen composition. |
| `viewHierarchy` | Optional Apple `drawHierarchy` compatibility mode. Incomplete descendants set `incomplete=true`. |

The Flutter Apple plugin reports `engineSurface` on `ok` and
`skippedByDHash`. Native Apple integrations can select `viewHierarchy` when
UIKit platform-view coverage is required. Physical-device confirmation is
still required before publication.

Not guaranteed on `engineSurface`: platform views, separate video/map
surfaces, secure / DRM content, `FlutterTextureView`, hybrid composition.
Those are unsupported render modes or missing layers, never an unmasked
substitute.

`windowComposite` is one app window's surface: the views drawn into that
window, `TextureView` included. It is not the full-screen composition.
Missing from it:

- `SurfaceView` / `GLSurfaceView` layers (video players, camera previews,
  maps that render to a `SurfaceView`). Callers mask their bounds
  fail-closed.
- Every other window: dialogs, `PopupWindow`s, dropdowns, the IME.

A window flagged `FLAG_SECURE` when the copy is issued is never copied:
the result is `secureWindow`, with no frame. `PixelCopy` of a window returns
its last queued buffer, which can still hold a secure screen just after the
flag is cleared. So the runtime checks the flag on the main thread,
invalidates the window, waits until a frame drawn after that check has been
committed (`registerFrameCommitCallback` on API 29+ hardware-accelerated
windows, otherwise two animation frames), checks the flag again, and only
then copies. The wait counts toward the runtime timeout and `surfaceCopy`; a
window that draws no frame (for example, a hidden one) reports `timeout`.

## Status × fallback × publish

| Status | Fallback to Dart? | Publish native frame? |
| --- | --- | --- |
| `ok` | no | yes (JPEG) |
| `skippedByDHash` | no | no new JPEG; Dart coalesces as today |
| `unsupportedApi` | yes | no |
| `unsupportedRenderMode` | yes | no |
| `surfaceUnavailable` | yes | no |
| `timeout` | yes | no |
| `pixelCopyFailed` | yes | no |
| `processingFailed` | yes | no |
| `cancelled` | no | no |
| `disposed` | no | no |
| `secureWindow` | no | no |

`secureWindow` is reported only by Android window capture, for a window
with `FLAG_SECURE`. It carries no frame and no coverage. It is not a
failure: hosts emit a `capture_diagnostic` event instead of a frame, never
fall back to another pixel path for that window, and do not count it toward
the consecutive failure limit below. Window capture below API 26 reports `unsupportedApi`.

Fallback is one-way for that `requestId`. Do not publish native and Flutter
together. After fallback starts, a Dart failure is the outcome; do not
retry native for that id.

Native timeout is configured on the runtime, default **2000 ms**, covering
PixelCopy plus processing. It is **not** Dart’s frame-wait timeout.

After **3** consecutive native failures that would fallback, disable native
for the rest of the capture session. Reset the counter on a new session,
activity recreate, or explicit backend re-enable.

Fallback reason tokens equal the status that caused fallback
(`unsupportedApi`, `unsupportedRenderMode`, `surfaceUnavailable`,
`timeout`, `pixelCopyFailed`, `processingFailed`).

## Clock ownership

Native must not put PixelCopy into Dart `captureMicros` or mask fill into
Dart `maskMicros`. Adapters map stages into budget health without renaming
them.

| Stage | Who measures | Native PixelCopy meaning |
| --- | --- | --- |
| `frameWait` | Dart | Existing compositor wait |
| `maskCollect` | Dart | Widget-tree rects + normalize. Native emits 0 |
| `surfaceCopy` | Runtime | PixelCopy into the target bitmap. On window capture, includes the wait for one committed frame |
| `pixelReadback` | Runtime | 0 — pixels are already CPU after PixelCopy. Do not fold PixelCopy here |
| `maskFill` | C++ core | ABI timing |
| `dHash` | C++ core | ABI timing |
| `jpeg` | Runtime | 0 on dHash skip |
| `sha256` | Runtime | 0 on dHash skip |
| `platformChannel` | Dart | Pigeon `capture` round-trip. This is the Dart `encodeMicros` on the native path. |
| `dartUiIsolate` | Dart | Native path should be ~0; adapter measures |
| end-to-end | Dart | `frameWait + maskCollect + encodeMicros`. Native `encodeMicros` is only `platformChannel`. Nested native stages are diagnostics; adding them double-counts work already inside the round-trip. |

## Diagnostics

Closed vocabulary. No pixels, JPEG, paths, view dumps, or exception strings
that could include user data.

Allowed: `requestId`, `status`, `coverage`, `incomplete`, `renderMode`,
integer timings, integer width/height, dHash bit string, SHA-256 hex,
backend name, fallback reason token.
