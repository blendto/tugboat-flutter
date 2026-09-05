# Screenshots and privacy

Status: current · Last verified: 2026-09-05

**Mask-before-encode** — the privacy ordering rule: screenshots are masked
**before** any encoding/compression. The default RepaintBoundary path applies
mask fills in the Dart encode isolate after UI-isolate RGBA readback (see
`docs/design/capture-and-fingerprint.md`). The native CPU path applies masks
in native/C++ before JPEG (`docs/privacy/pipeline.md`). Encoded JPEG bytes
that leave the app are already masked.

**Default mask** — `allTextAndMedia`: all visible text and media are masked
in every screenshot by default. Hosts can select a narrower mask policy;
evidence capabilities never change the mask (see
`docs/design/capture-and-fingerprint.md`).

**Raw pixels never enter Dart** — the native capture boundary: screenshots
produced by native backends stay in native code (C++/platform) through
processing; Dart receives only encoded, already-masked images.

**Privacy device rows** — internal lab gates (per-device privacy sign-off) for
experimental native capture; not a public shipping claim (see
`docs/publishing.md`). They are not specified in
`docs/architecture/native-capture-contracts.md`.

**Privacy boundary** — the authoritative contract in
`docs/architecture/native-capture-contracts.md` covering what may be captured,
what must be masked, and what may be published as a native frame. Changing
capture cadence, activation, or sink behavior requires re-checking this
contract.
