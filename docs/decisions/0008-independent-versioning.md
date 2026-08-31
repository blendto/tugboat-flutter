# ADR 0008: Independent artifact versions

Status: Accepted
Date: 2026-08-31

## Context

The Flutter package, Android AAR, Apple runtime, and a future npm adapter
will not ship on the same day. One repo version would force dummy bumps.

## Decision

Version each published artifact independently. The C++ core is not
published; it is owned by the runtime that compiles it. Compatibility
mapping (Flutter `0.9.0` → runtime `0.1.x`) lives with the release docs
in Phase 8, not as a second copy here.

## Consequences

CI version-bump rules must become path-aware (Phase 8). This `0.8.12` line
is not native-capable; `0.9.0` is the planned first adapter that may
depend on `capture-runtime` `0.1.x`.
