# Screenshots and privacy

Status: current · Last verified: 2026-09-05

**Mask-before-encode** — the privacy ordering rule (`docs/privacy/pipeline.md`):
screenshots are masked **before** any encoding/compression. The mask owner is
the masked screenshot capturer inside `TugboatReplayController`; encoded JPEG
bytes that leave the app are already masked.

**Default mask** — `allTextAndMedia`: all visible text and media are masked in
every screenshot. This default is always on; capabilities never weaken it.

**Raw pixels never enter Dart** — the native capture boundary: screenshots
produced by native backends stay in native code (C++/platform) through
processing; Dart receives only encoded, already-masked images.

**Privacy device rows** — the per-device privacy facts (mask coverage, rows
exposed to privacy review) that gate experimental capture backends; see
`docs/architecture/native-capture-contracts.md`.

**Privacy boundary** — the authoritative contract in
`docs/architecture/native-capture-contracts.md` covering what may be captured,
what must be masked, and what may be published as a native frame. Changing
capture cadence, activation, or sink behavior requires re-checking this
contract.
