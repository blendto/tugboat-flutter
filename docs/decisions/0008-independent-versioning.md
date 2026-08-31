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

CI version-bump rules are path-aware (`tool/ci/check-version-policy.sh`).
Documentation-only and C++ test/fuzz-only changes do not bump Flutter.
Public runtime API / C ABI changes bump `capture-runtime`. Adapter source
changes bump `tugboat` and update
[compatibility.md](../releases/compatibility.md).

This `0.8.12` line is not the first native-capable public adapter; `0.9.0`
is planned after privacy and performance gates, still mapped to
`capture-runtime` `0.1.x`.
