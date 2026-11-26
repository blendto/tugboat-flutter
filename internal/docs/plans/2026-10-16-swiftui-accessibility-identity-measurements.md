# SwiftUI accessibility identity: device measurements (ADR 0010)

Single-device measurements behind ADR 0010. They moved out of the public ADR,
the `Tugboat` README and the `TugboatConfig` doc comment after the PR #100
review (Nov 26), because `docs/publishing.md` keeps single-device numbers out
of product docs. The public text states the costs qualitatively.

Device and build: iPhone 12, iOS 18.6.2, Release build.

## Probe

- Calling `accessibilityActivate()` on the hosting view took it from 0 to 35
  accessibility elements, and 4 of 4 app-set identifiers were readable.
- The tree is built once per process and is not there after a relaunch.
- `accessibilityHitTest(_:)` still returns nil.

## Cost

- Building the tree: a one-time main-thread stall of about 85-300 ms.
- After the first tree read, for the rest of the process:
  - LazyVStack scrolling main-thread time: +104%.
  - State updates: +55%.
  - Process CPU: +31%.
  - Memory: +5 MB.
  - Scrolling in `TugboatSwiftUISample`: +27%.

Widening the OS gate beyond iOS 18 needs these measured again on iOS 17 and 26
(BLE-628).
