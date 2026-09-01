# Documentation keep / move inventory

Policy: [docs/publishing.md](../../docs/publishing.md).

Classification is for the **default public story**, not git history. Files
listed as move now live under `internal/docs/`. Architecture pages were not
rewritten.

## Keep in `docs/` (public)

| Path | Why |
| --- | --- |
| `docs/publishing.md` | This policy |
| `docs/architecture/*` | Capture contracts, coverage, fallback, repo map |
| `docs/decisions/0001`–`0008` | Accepted ADRs |
| `docs/design/capture-and-fingerprint.md` | Implemented identity / screenshot model |
| `docs/privacy/pipeline.md` | Mask-before-encode ownership |
| `docs/privacy/README.md` | Index into public privacy pages |
| `docs/integration/collector.md` | Public wire behavior |
| `docs/integration/native-cpu-experimental.md` | Opt-in flag and fallback rules |
| `docs/integration/common-build.md` | Host build commands |
| `docs/integration/android-development.md` | Integrator / contributor build |
| `docs/integration/apple-development.md` | Integrator / contributor build |
| `docs/integration/flutter-development.md` | Integrator / contributor build |
| `docs/performance/cpu-capture-baseline.md` | Public comparison contract (stage names, JPEG envelope). Not a device gate. |
| `docs/releases/compatibility.md` | Adapter ↔ runtime versions |
| `docs/releases/process.md` | How versions bump |
| `docs/releases/repository-migration.md` | GitHub rename note |
| `docs/releases/third-party-notices.md` | License notices |
| `docs/exploration/example-brief.md` | Demo app constraints (no customer data) |
| Package READMEs / CHANGELOGs | Public API |

## Move to `internal/docs/` (working notes)

| Old path | New path | Why |
| --- | --- | --- |
| `docs/plans/2026-08-31-001-native-capture-cpu-plan.md` | `internal/docs/plans/` | Agent sequencing, local SHAs |
| `docs/plans/2026-07-28-001-sdk-interaction-consolidation-plan.md` | `internal/docs/plans/` | Dated execution plan |
| `docs/plans/2026-07-16-001-feat-sdk-lifecycle-durable-capture-plan.md` | `internal/docs/plans/` | Dated execution plan |
| `docs/plans/2026-07-08-001-feat-semantic-map-scroll-production-plan.md` | `internal/docs/plans/` | Dated execution plan |
| `docs/performance/cpu-capture-method.md` | `internal/docs/lab/` | Device-lab protocol |
| `docs/performance/cpu-capture-results.md` | `internal/docs/lab/` | Emulator A/B; not a ship gate |
| `docs/privacy/native-cpu-signoff.md` | `internal/docs/lab/` | Open host vs device matrix |
| `docs/integration/blend-gesture-check-2026-08-26.md` | `internal/docs/canaries/` | Host-app canary (identifiers redacted) |
| `docs/integration/production-replay-acceptance.md` | `internal/docs/canaries/` | Internal release gate procedure |
| `docs/integration/production-replay-acceptance-0.4.15.md` | `internal/docs/canaries/` | Dated acceptance log |
| `docs/integration/production-replay-acceptance-0.4.13.md` | `internal/docs/canaries/` | Dated acceptance log |
| `docs/integration/production-replay-run-2026-07-27-sdk-0.4.12.md` | `internal/docs/canaries/` | Dated run log |
| `docs/integration/gesture-pr-review-2026-08-27.md` | `internal/docs/reviews/` | Cursor / PR transcript |
| `docs/roadmap/README.md` | `internal/docs/roadmap/` | Uncommitted public promise |
| `docs/roadmap/react-native.md` | `internal/docs/roadmap/` | Competitive sequencing |
| `docs/roadmap/gpu.md` | `internal/docs/roadmap/` | Competitive sequencing |

## Still public git history

Moving a file does not erase GitHub history. Session ids and machine paths in
the Blend canary were redacted in the current tree. Treat leftover copies in
old commits as sensitive.

Next step (not this PR): copy `internal/docs/` to a private wiki and stop adding
lab/canary notes to this repository.
