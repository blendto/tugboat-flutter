# Native SDK capability inventory

Status: working notes · 2026-10-08 · not a public promise

Evidence a native platform host and native toolkit adapters can produce
that the Dart-only Flutter adapter cannot. Architecture:
[ADR 0009](../../../docs/decisions/0009-shared-session-engine.md)
(proposed).

Every new event type or field here is a contract change. Ship each behind
an opt-in capability, like `captureFocusChanges` / `captureSystemInput`,
until the collector accepts it. API names below are starting points; verify
availability and API levels before scheduling.

## Ranked by value to the app graph

| # | Capability | Android source | iOS source | Graph value | Reaches Flutter / RN via native host? |
| --- | --- | --- | --- | --- | --- |
| 1 | Built-in identity aliases | View resource entry names (`R.id.*`), Compose `testTag` | `accessibilityIdentifier`, view controller class, storyboard IDs | High-confidence anchors with no developer tagging; resource names usually survive release builds, unlike Flutter structural paths | No — native toolkits only. RN gets the same from `testID`. |
| 2 | Automatic screen tracking | `ActivityLifecycleCallbacks`, `FragmentLifecycleCallbacks`, Navigation `OnDestinationChangedListener` | `UIViewController` appearance (swizzled, with opt-out), navigation / modal / tab stacks | Screen nodes and edges without observer wiring; covers nested navigation and programmatic transitions (Flutter #13/#14 gaps) | Hybrid apps: native screens around Flutter/RN views |
| 3 | Durable outbox | Disk queue + WorkManager | Disk queue + background `URLSession` | Sessions survive process death; fewer truncated graphs | Yes |
| 4 | Launch source | Launch `Intent` (deep link, notification, shortcut, widget), cold vs warm | `launchOptions` / scene connection options, `NSUserActivity`, notification response | Entry edges from outside the app | Yes |
| 5 | Exit reason | `ApplicationExitInfo` (API 30+): crash, ANR, low memory, user | MetricKit diagnostics (delivered next launch) | Separates abandonment from app death at the last node | Yes |
| 6 | OS-level network | Auto-installed OkHttp interceptor + `EventListener` timings | `URLProtocol` + `URLSessionTaskMetrics` | All clients, DNS/TLS/TTFB timings | RN yes (`fetch` uses OkHttp / `NSURLSession`). Flutter no: `dart:io` bypasses both; `tugboat_dio` stays. |
| 7 | System boundary events | Permission results, IME visibility (`WindowInsets`), outgoing intents, config changes | Authorization status changes, keyboard notifications, `openURL` / share sheet, trait changes | Edges that leave the app or wait on the OS | Yes, as events |
| 8 | Transition performance | JankStats / `FrameMetrics`, memory trim callbacks | `CADisplayLink` hitch tracking, MetricKit, memory warnings | Slow or janky annotations on edges | Yes |
| 9 | App-window composite | `PixelCopy` per app window, including dialogs | Window hierarchy render | Native overlays, maps, video, WebViews in frames (`windowComposite` coverage) | Hybrid and platform-view screens |

## Events, not pixels

Native code can observe these but cannot capture their pixels: system
permission dialogs, the soft keyboard, status bar and notification shade,
`FLAG_SECURE` / DRM content, and other apps. Represent them as events with
explicit coverage gaps, never as a substitute frame.

## Privacy rules to settle first

- OS-level network capture sees third-party SDK traffic. Default to
  first-party host allowlists; bodies stay off unless the API-error rule
  that `tugboat_dio` already follows applies.
- A persistent outbox stores evidence at rest. Needs bounds, retention,
  encryption, and wipe-on-opt-out rules.
- Launch intents and deep links can carry tokens. Record scheme, host, and
  path template; drop query values by default.
- Native text inputs expose secure or one-time-code types. Always mask
  those regions regardless of mask level.

## Suggested order

1. Native host for Flutter: durable outbox, launch source, exit reason.
   This improves existing customers before any new SDK ships.
2. First native toolkit (Compose, then SwiftUI) with identity aliases and
   automatic screen tracking.
3. React Native on the same hosts: JS identity, native network for free.
4. System boundary events and transition performance, as opt-in
   capabilities once the collector accepts them.
5. App-window composite after the coverage contract defines
   `windowComposite`.
