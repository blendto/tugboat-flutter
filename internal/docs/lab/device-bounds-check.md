# boundsNorm device check (#136)

Status: **not yet run.** No device result has been recorded. Do not cite this
page as evidence that the acceptance criterion passed; record results below
(or in a results page beside this one) only from real Android and iOS devices.

A device-lab protocol, so it lives here and not in `docs/`
([publishing policy](../../../docs/publishing.md)). The contract it checks is
in [Bounds, viewport and scroll](../../../docs/design/capture-and-fingerprint.md#bounds-viewport-and-scroll).

## What is being checked

For every fully visible element of a scene inventory, the box computed from
`boundsNorm` and `viewport` lands within 1 device pixel of the widget's paint
box on the screen, on Android and on iOS.

    x      = (boundaryOffset.left + boundsNorm.left   * widthPx)  * devicePixelRatio
    y      = (boundaryOffset.top  + boundsNorm.top    * heightPx) * devicePixelRatio
    width  =  boundsNorm.width  * widthPx  * devicePixelRatio
    height =  boundsNorm.height * heightPx * devicePixelRatio

These are pixels of the Flutter view. They equal screen pixels only when the
view starts at the screen's top-left (edge-to-edge). Otherwise add the view's
on-screen origin, which the SDK does not report (step 5).

## Devices

- Android: one physical phone with a non-integer ratio (2.625 or 2.75 is
  ideal), edge-to-edge on (Android 15+ default). Optional second run with a
  display cutout.
- iOS: one physical iPhone at 3x. Optional 2x device.
- Emulator or simulator runs may be added, labelled as such, never in place of
  the device rows.

## Screens (`sdks/flutter/packages/tugboat/example`)

1. Home (`/`): static buttons, status bar inset, `boundaryOffset`.
2. Home, dialog open (the `showDialog` button): centred overlay surface.
3. Home, bottom sheet open (the `showModalBottomSheet` button).
4. Catalog (`/catalog`) scrolled so one row is half cut off: checks the cut
   row keeps unclipped coordinates (`visibleFraction` < 1, top < 0 or bottom
   > 1). Only fully visible rows count towards the 1 px criterion.
5. Shipping (`/shipping`) with a text field focused and the keyboard up:
   checks `keyboardInset` and that boxes do not move with the keyboard maths.
6. Optional: Home in landscape.

## Steps

1. Build a debug or profile build of `example/` with exploration on. Either
   launch with the SDK's launch input (Android:
   `adb shell am start -n <pkg>/<activity> -e tugboat_emit_scene_inventory 1`;
   iOS: launch argument `--tugboat-emit-scene-inventory`), or temporarily set
   `emitSceneInventory: true` in `example/lib/main.dart` (do not commit).
2. Add a temporary dump hook (do not commit): a sink from
   `TugboatReplayConfig.sinkFactories`, or a debug button, that writes the
   newest `scene_inventory` event's `data` as JSON to the app documents
   directory as `inventory-<routeKey>-<n>.json` (`path_provider`'s
   `getApplicationDocumentsDirectory`, a temporary dependency of the example
   only). Printing the JSON with a marker and collecting it from `adb logcat`
   or the Xcode console also works, but long lines are split and must be
   reassembled.
3. Open the screen, do the setup (scroll, open the dialog, focus the field),
   then take your hands off and wait 2 s. The inventory to use is the newest
   one for the current `routeKey` (trigger `route`, `scroll`, `tap` or
   `settled`). The screen must be static from that inventory to the
   screenshot: take two screenshots 1 s apart and require them to be
   byte-identical (or pixel-identical after decode). If not, redo the step.
4. Screenshot and dumps:
   - Android screenshot: `adb exec-out screencap -p > shot.png`
   - Android accessibility: `adb shell uiautomator dump /sdcard/ui.xml &&
     adb pull /sdcard/ui.xml` (bounds `[l,t][r,b]` in screen pixels)
   - Android inventory: `adb exec-out run-as <pkg> cat
     app_flutter/inventory-*.json` (path per the dump hook)
   - iOS screenshot: Xcode > Devices and Simulators > Take Screenshot, or
     `idevicescreenshot shot.png` (libimobiledevice) on a physical device;
     simulator only: `xcrun simctl io booted screenshot shot.png`
   - iOS accessibility: an XCUITest that prints `XCUIElement.frame` (points;
     multiply by `UIScreen.main.scale`) for the labels on screen
   - iOS inventory: Xcode > Devices and Simulators > the app > Download
     Container, or `xcrun devicectl device copy from --device <udid>
     --domain-type appDataContainer --domain-identifier <bundle-id>
     --source Documents --destination ./out`
5. View origin. Android: in `ui.xml` find the node whose class is the Flutter
   view (`io.flutter.embedding.android.FlutterView` / the root
   `FrameLayout` content); its bounds' left/top is the origin. Edge-to-edge:
   (0, 0). iOS full-screen Flutter view: (0, 0).
6. For each element in the inventory with no `visibleFraction` (fully
   visible), compute the expected box with the formula above plus the origin.
7. Compare against:
   - Screenshot pixels (primary, it is the paint box): within a search window
     of the expected box plus 8 px, find the element's painted edges. For a
     `FilledButton`, the bounding box of pixels matching its fill colour
     (tolerance 8 per channel for antialiasing); for text-only elements, the
     bounding box of non-background pixels. Edge error = |expected - found| for
     left, top, right, bottom.
   - Accessibility rect (secondary): only for elements whose semantics rect is
     their paint box (plain `Text`, list rows, cards). Material buttons pad
     their tap target to 48 dp (`MaterialTapTargetSize.padded`), and their
     semantics rect can include that padding while `boundsNorm` is the paint
     box, so a 4 to 8 dp difference there is expected and not a failure; judge
     buttons by the screenshot.
8. Draw the expected boxes on the screenshot (one-pixel outline) and keep the
   overlay image with the numbers, so a reviewer can see misses.

## Pass and report

- Pass: every fully visible element has all four edge errors <= 1 device px,
  on each device and screen.
- Report per device and screen: device model, OS, `devicePixelRatio`,
  `viewport` JSON, and per element: `canonicalPath`, expected box, found box,
  max edge error in px, method (screenshot or accessibility).
- A miss larger than 1 px: record which edge, whether all elements shift by the
  same amount (an origin or inset problem) or scale with position (a ratio
  problem: compare `devicePixelRatio` with the screenshot width divided by the
  view's logical width).

## Helper (optional)

A ~40-line Python script with Pillow can do steps 6 to 8 from `shot.png`,
`ui.xml` and the inventory JSON: compute expected boxes, search the colour
bounding box, print the table and save `overlay.png`.

## Results

| Date | Device | OS | Ratio | Screen | Max edge error (px) | Pass |
| --- | --- | --- | --- | --- | --- | --- |
| | | | | | | |
