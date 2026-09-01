# ADR 0005: Opt-in Flutter native CPU backend

Status: Accepted
Date: 2026-08-31

## Context

The long-term architecture must not depend on Flutter for screenshot
pixels. The `TugboatCaptureBoundary` path is the tested default. Native
capture is unproven on coverage, lifecycle, and performance.

## Decision

Default backend remains `flutterRepaintBoundary`. Native CPU is
`nativeCpuExperimental`. Keep the boundary mounted. Fallback, cancellation,
and duplicate-publication rules are in
[native-capture-contracts.md](../architecture/native-capture-contracts.md).

## Consequences

Integrators opt in explicitly. The experimental backend can be disabled
without a package rollback. Native does not become default until Android
and Apple gates in the plan pass.
