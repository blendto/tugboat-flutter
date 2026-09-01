# ADR 0006: Mask coordinates

Status: Accepted
Date: 2026-08-31

## Context

Dart today scales logical mask rects by `capturePixelRatio` into the
`toImage` bitmap. A PixelCopy bitmap can differ in origin, size, and
format. Sending Flutter logical pixels or raw bitmap pixels on the channel
would couple every adapter to one rasterizer.

## Decision

Send normalized rectangles in CaptureBoundary local space. The runtime
maps that space onto the capture bitmap with privacy-expanding integer
conversion. The C ABI sees only clipped integer rects.

The mapping, rounding, and failure rule (cannot map → `processingFailed`,
do not encode) are specified in
[native-capture-contracts.md](../architecture/native-capture-contracts.md).

## Consequences

A wrong origin or round-toward-unmask is a privacy failure. Phase 6 tests
must cover edges, rotation, scale, density, keyboard, and insets.
