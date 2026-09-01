# Public documentation policy

This repository is public and AGPL-licensed. Treat `docs/` as customer-facing
product documentation, not a notebook.

## Publish in `docs/`

Pages a host app or integrator needs to use the SDK correctly:

- Privacy and capture **invariants** (raw pixels never enter Dart, mask before
  JPEG, fallback, coverage limits)
- Wire meaning and public API (`route_change`, backends, collector events)
- How to build and opt in to experimental native capture
- Accepted architecture decision records
- Compatibility, license, and third-party notices

## Do not publish as product docs

Pages only Blend/Tugboat engineering needs to decide whether to ship:

- Agent or execution plans with checkboxes and local SHAs
- Device-lab protocols, incomplete sign-off matrices, emulator A/B diaries
- Customer canaries (host app ids, session ids, machine paths, unreleased pairings)
- PR review transcripts and Cursor session notes
- Roadmap sketches that are not a public promise

Those notes live in [`internal/docs/`](../internal/docs/README.md). They remain
in this git history until they move to a private wiki. Do not link them from
the SDK README or from `docs/` getting-started lists. Do not cite emulator
numbers or open device rows as shipping claims.

## How to classify a new page

If a host engineer needs it to integrate or to trust the privacy boundary, it
belongs in `docs/`. If only we need it to run a lab, accept a Blend build, or
sequence a milestone, it belongs in `internal/docs/` (or a private store).

Accepted ADRs stay public even when they mention deferred work. Dated plans
that drove an agent do not.

See the [keep / move inventory](../internal/docs/INVENTORY.md).
