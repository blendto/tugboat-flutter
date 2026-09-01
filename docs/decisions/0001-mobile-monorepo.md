# ADR 0001: Mobile monorepo

Status: Accepted
Date: 2026-08-31

## Context

Native capture needs a C++ core, an Android AAR, later an Apple package,
and the Flutter SDK. Those ship through Maven, SwiftPM/CocoaPods, and pub.
Keeping native sources inside `packages/tugboat` would either put them in a
pub archive or fork copies per adapter.

## Decision

Restructure into a mobile monorepo. Trees, identifiers, and compile
ownership are specified in
[repository-scope.md](../architecture/repository-scope.md).

## Consequences

CI, Melos, and pub paths change in Phase 2. The GitHub rename to
`tugboat-mobile` needs administrator access.
