# ADR 0004: Platform JPEG codecs

Status: Accepted
Date: 2026-08-31

## Context

Vendoring `libjpeg-turbo` in the C++ core adds SwiftPM, CocoaPods, and AAR
packaging before Android CPU capture is proven.

## Decision

JPEG stays out of the C++ core for the first release. Android platform JPEG
and Apple ImageIO, quality 80, matching `screenshotJpegQuality`. SHA-256
stays in each runtime, over JPEG bytes.

## Consequences

Codec speed and size are Phase 7 measurements against
[cpu-capture-baseline.md](../performance/cpu-capture-baseline.md). A later
codec can sit behind the same runtime encode interface without an ABI
change.
