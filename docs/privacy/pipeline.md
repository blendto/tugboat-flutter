# Privacy pipeline

1. Dart walks the widget tree in CaptureBoundary local space.
2. Dart sends **normalized** mask rects only. No RGBA.
3. Native maps those rects onto the PixelCopy bitmap with floor/ceil
   expansion, then clips.
4. The C++ core paints `(0x1a, 0x1a, 0x1a, 0xff)` in place **before** dHash
   and **before** JPEG, including on dHash-skip paths.
5. Dart receives masked JPEG bytes and bounded metadata.

There is no encode-then-cover path. A failure must not publish an unmasked
frame. Coordinates, fill color, and stop conditions are in
[native-capture-contracts.md](../architecture/native-capture-contracts.md).
Device-lab sign-off is an internal gate, not a public shipping claim.
