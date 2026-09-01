# ADR 0003: Native artifact ownership

Status: Accepted
Date: 2026-08-31

## Context

Compiling the core inside the Flutter plugin would hide it from React
Native and non-Flutter hosts, and would recompile or copy it per adapter.

## Decision

Publish platform runtimes as their own artifacts. Adapters depend on them
and do not compile a private core. Coordinates and local-dev publication
are in [repository-scope.md](../architecture/repository-scope.md).

## Consequences

The Flutter plugin stays thin: Pigeon, lifecycle, mask metadata, fallback.
Public Maven/CocoaPods publication waits for privacy and performance gates.
