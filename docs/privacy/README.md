Privacy rules for native capture live in
[native-capture-contracts.md](../architecture/native-capture-contracts.md).

Mask-before-encode ownership is summarized in [pipeline.md](pipeline.md).
Phase 6 host-side checks and the remaining device gate are in
[native-cpu-signoff.md](native-cpu-signoff.md).

The host path captures through the native CPU backend with a Pigeon fake
that applies the runtime mask mapping and JPEG encode. PixelCopy on a
physical device remains in the sign-off table.
