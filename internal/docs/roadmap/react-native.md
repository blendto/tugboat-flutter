# React Native adapter roadmap

Status: in progress · updated 2026-11-27 · not a public promise

React Native is the next SDK to ship, ahead of the remaining native toolkit
work, because clients are waiting on it. Linear project P-BLE-18 tracks it;
the release issue is BLE-668.

Architecture: [ADR 0009](../../../docs/decisions/0009-shared-session-engine.md)
(accepted). The adapter is a full SDK, not only a pixel consumer. JavaScript
computes target identity from the React tree; the native platform host
(Kotlin on Android, Swift on iOS) runs the shared session engine, transport,
masking and pixels. Raw pixels never enter JavaScript.

Design note (decisions recorded 2026-11-27):
[react-native-adapter-design-note](../plans/2026-11-27-react-native-adapter-design-note.md)
(BLE-642). Masking follows the shared privacy model in
[native-capture-contracts.md](../../../docs/architecture/native-capture-contracts.md)
(BLE-633).

## Release order

1. **0.1.0: session replay and fingerprints.** Sessions, navigation, masked
   frames, and taps, scrolls and text input with stable fingerprints that are
   identical on Android and iOS and in debug and release Hermes builds.
   New Architecture only (React Native 0.76+). Pure React Native apps
   ("React Native owns its root"); brownfield support comes later. No
   exploration scene inventory in this release.
2. **Network evidence** right after: `fetch` / `XMLHttpRequest` capture in
   JavaScript (BLE-671, BLE-648).
3. Error and crash reporting last.

## Gates and prerequisites

- **Spike first (BLE-681).** It verifies the React internals that identity and
  masks rely on, across React Native and React versions and release builds,
  before the mask (BLE-644) and fingerprint (BLE-669) work starts.
- **Native host seams:** React Native owning its root on Android
  (`ToolkitRegion`, BLE-682) and iOS (BLE-683); session restart and adopting
  an already-open Android activity on a late JavaScript start (BLE-684).
- **Publishing:** the package develops against the in-repo native SDKs; the
  release needs the Android SDK on Maven Central (BLE-638) and the Swift SDK
  on SwiftPM and CocoaPods (BLE-639).

Identifiers: npm `@tugboat-ai/react-native`, Android namespace
`com.tugboat.reactnative`. The package lives in `sdks/react-native`; there is
no npm workspace yet (BLE-643 adds it).
