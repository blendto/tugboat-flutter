# React Native adapter roadmap

Do not start this work before the Android CPU privacy and performance gates
pass. The Apple runtime now exists as an unpublished local CocoaPod /
SwiftPM package (`TugboatCaptureRuntime` 0.1.0); do not consume a registry
copy until that artifact is published.

Planned identifiers: Android namespace `com.tugboat.reactnative`, npm
`@tugboat/react-native`. The adapter will consume the same
`com.tugboat.sdk:capture-runtime` AAR and the Apple CocoaPod. Raw pixels
stay out of JavaScript. The first npm package is a beta behind a
compatibility-table entry.

There is no npm workspace in this repository yet. The placeholder is
`sdks/react-native/README.md`.
