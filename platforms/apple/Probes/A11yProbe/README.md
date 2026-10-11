# SwiftUI accessibility probe (spike, not product code)

Answers native SDK design note §6.3: **without VoiceOver**, can in-process
code read the SwiftUI accessibility tree, see `accessibilityIdentifier`s,
and hit-test elements? It also shows which UIKit views carry text. The
answers decide how much the SwiftUI adapter relies on `tugboatTag` frames,
and when masks must fail closed.

The screen has a heading, a button (`probe.button`), a text field
(`probe.field`), an image, and a 20-row list (`probe.list`). On appear the
probe walks the key window twice, at 0.5 s and 2 s, and prints lines that
start with `A11YPROBE`:

| Prefix | Content |
| --- | --- |
| `V` | One line per UIView: type, frame, `isAccessibilityElement`, element count, identifier, label, any UIKit-held text, and the cell index path |
| `E` | One line per accessibility leaf, found by VoiceOver-style traversal: traits, label, value, identifier, frame |
| `HIT` | For each `probe.*` element, which leaf a frame-based hit test at its centre picks |
| `L` | Pass 2: the CALayer tree under each SwiftUI hosting view: class, frame, contents type, sublayer count. Layers that back another UIView are marked `[view …]` and not descended. |
| `L-CLASS` | Pass 2: a histogram of layer classes, with how many have `contents` |
| `MATCH` | Pass 2: for each ground-truth element frame (`text.*`, `image.star`, `field`, recorded by SwiftUI `GeometryReader`), the best-overlapping layer and its IoU |
| `LAYER-VERDICT` | Pass 2: `textSeparable` / `imageSeparable` (every text or image truth matched with IoU ≥ 0.5) and the layer classes that matched |
| `SUMMARY` / `VERDICT` | Counts, plus `treePopulatedWithoutVoiceOver` and `identifiersVisible` |

## Run (Mac with Xcode)

```sh
brew install xcodegen   # if missing
cd platforms/apple/Probes/A11yProbe
xcodegen generate
xcodebuild -project A11yProbe.xcodeproj -scheme A11yProbe \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath build build
xcrun simctl boot "iPhone 16" 2>/dev/null || true
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/A11yProbe.app
xcrun simctl launch --console-pty --terminate-running-process booted com.gettugboat.probe.a11y \
  | grep A11YPROBE | tee a11y-probe.log
```

Wait about 3 s after launch, then stop. Leave VoiceOver off.

Output is flushed after each pass and mirrored to `Documents/a11y-probe.log`
in the app container, so both passes survive even if the console cuts off:

```sh
cat "$(xcrun simctl get_app_container booted com.gettugboat.probe.a11y data)/Documents/a11y-probe.log"
```

Run on the latest iOS runtime. If you have one, also run on an iOS 15 or 16
runtime: SwiftUI `List` is backed by `UITableView` on iOS 15 and by
`UICollectionView` from iOS 16.

## What to send back

- the `SUMMARY`, `VERDICT`, `HIT`, `L-CLASS`, `MATCH` and `LAYER-VERDICT` lines for each runtime;
- the `Documents/a11y-probe.log` file, which holds both passes;
- the full log, if it is short enough;
- any build errors, verbatim. This was written without a Mac.
