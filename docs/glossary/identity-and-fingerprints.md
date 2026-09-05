# Identity and fingerprints

Status: current · Last verified: 2026-09-05

**Fingerprint** — the deterministic identifier of a screen state or an
interaction target. The core contract: identity is reproducible within one app
build and one fingerprint schema version.

**`fingerprintSchemaVersion`** — currently **6**. Namespaces the fingerprint
algorithm; a change here means identities are not comparable across versions.
Consumers (Context Graph) match evidence within the same schema version.

**Identity invariants** (`docs/design/capture-and-fingerprint.md`):

- State and target identity are deterministic within one build and fingerprint
  schema version — same input, same identity.
- **Locale is evidence, never identity** — emitted on sessions and events, but
  never mixed into fingerprints.
- **Developer tags strengthen matching but are optional** — matching must work
  without them.
- **Cross-build stability is not promised.** Renaming/remapping identities
  across app builds is downstream (Context Graph) work; this repo only
  guarantees the within-build contract.

**Structural anchor** — the resolved route/target anchor for an event
(see the controller's "structural anchor resolver"); carries the fingerprint
into the event stream.

**Mask coordinates** (ADR 0006) — normalized CaptureBoundary mask rects sent to
native capture, mapped with privacy-expanding integer conversion (see
`docs/architecture/native-capture-contracts.md`). Visible text is not
structural identity — that rule is in
`docs/design/capture-and-fingerprint.md`.
