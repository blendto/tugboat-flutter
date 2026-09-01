# ADR 0002: C++ for the portable core

Status: Accepted
Date: 2026-08-31

## Context

Mask fill, dHash, and buffer validation must be identical on Android and
Apple. Rust is a plausible later internals language. The first requirement
is NDK + Objective-C++ without a second packaging story.

## Decision

C++17 behind a versioned C ABI. Not Rust for the first release. What the
core may own is in
[repository-scope.md](../architecture/repository-scope.md). Behavioral
rules are in
[native-capture-contracts.md](../architecture/native-capture-contracts.md).

## Consequences

The ABI is the stability boundary. A later Rust or GPU implementation can
replace the internals without changing Kotlin or Swift adapters.
