# ADR 0007: GPU processing is deferred

Status: Accepted
Date: 2026-08-31

## Context

PixelCopy and CPU JPEG may still dominate after Dart is removed from the
pixel path. GPU shading only pays off if pixels stay in a GPU buffer.

## Decision

No GPU processing in the first release. Revisit Metal / Vulkan / OpenGL ES
only after Phase 7 identifies the remaining CPU stage. Mask-on-GPU plus a
full-resolution readback is not a sufficient win.

## Consequences

The first Android path is PixelCopy → CPU mask/dHash → platform JPEG.
The C ABI stays stable so a GPU internals swap does not fork adapters.
The CPU path remains the fallback if GPU ever ships.
