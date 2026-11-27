# ADR 0011: Error and crash reporting

Status: Proposed
Date: 2026-11-26

## Context

Tugboat records sessions, interactions, navigation, masked frames, network
calls and external events. It records no errors and no crashes on any
platform. A crash is often the moment a product team most wants to replay,
and we already hold what leads up to it: the taps, screens, network calls
and frames.

Error reporting covers several different failures, and they differ a lot in
how reliably an SDK can see them:

- **Handled errors** that the app reports itself.
- **Unhandled errors that a runtime reports to the app**: Dart
  (`FlutterError.onError`, `PlatformDispatcher.onError`, isolate errors),
  Kotlin and Java (the default uncaught-exception handler), Objective-C
  exceptions, and JavaScript in React Native.
- **Fatal native crashes**: signals in C, C++ or the runtimes, and Swift
  traps. The process is already in an undefined state when they happen.
- **Terminations with no crash**: Android ANRs, iOS hangs, and iOS
  out-of-memory and watchdog kills, which leave no crash report at all.

Catching fatal crashes in-process is the hard part. Code that runs during
the crash must be async-signal-safe (no allocation, no Objective-C or
Swift), must leave the OS crash report intact, and must share signal
handlers with ART, the Dart VM, Hermes and any crash reporter the app
already ships. The order of installation decides which one sees a crash.
Apple's developer-support guidance advises against new in-process
reporters and points to MetricKit instead.

The operating systems now report most of this after the fact:

- Android 11 (API 30) and later record why each process ended in
  `ApplicationExitInfo`: Java and Kotlin crashes, native crashes and ANRs.
  From Android 12 (API 31), `getTraceInputStream()` returns the native
  tombstone (every thread, registers, memory maps) or the ANR thread dump.
  `setProcessStateSummary(byte[])` attaches up to 128 bytes of app state to
  the process's future exit record. Established crash reporters have
  started reading tombstones this way.
- iOS 14 and later deliver `MXCrashDiagnostic` and `MXHangDiagnostic`
  through MetricKit, in batches, after the fact. At least one established
  crash reporter plans to replace its own hang detector with MetricKit.

Readable stacks need symbols on the server: R8 mapping files, NDK symbols,
dSYMs, Dart `--split-debug-info` symbols and Hermes source maps. We have no
symbol upload or symbolication today.

## Decision

1. **Errors are evidence.** A new `error` event goes through the session
   engine like `network_call` and `external_event`. It carries the error
   kind, whether it was handled or fatal, the type name, a stack in the
   runtime's raw form, and an optional message under a parameter policy
   (`names_only` by default, as for event parameters), because messages can
   contain user data. Limits and policies are applied once, in the engine
   for native SDKs and in Dart for Flutter until it moves onto the engine,
   and both are held to shared fixtures in `conformance/evidence/`. The
   session's own events are the breadcrumbs; no separate breadcrumb
   buffer is kept.
2. **Each adapter catches its runtime's errors.** Dart, Kotlin, Swift and
   JavaScript hooks chain to any handler the app already installed and
   never replace it. Recording an error never throws and never changes
   whether the app crashes.
3. **Fatal crashes come from the OS, on the next launch.** The native host
   reads them when the app starts again and sends them through the outbox:
   - Android: `ApplicationExitInfo` from API 30, with the tombstone or ANR
     trace from API 31. The host writes the current session id with
     `setProcessStateSummary` whenever the session changes, so each exit
     record names its session.
   - iOS: MetricKit crash and hang diagnostics, plus a small on-disk
     marker (session id, foreground state, clean exit, app and OS version)
     that lets the host infer an out-of-memory or watchdog termination by
     ruling out every other cause, as established crash reporters do.
4. **No in-process crash handler by default, and never in the engine.** If
   one is added later, it is a separate, minimal C module under `core/`,
   built on an existing open-source crash-capture library, off by default,
   that chains to existing handlers and
   leaves the OS report intact. That decision gets its own ADR, with
   evidence that customers need it.
5. **Integrate before we compete.** Apps that already run a crash reporter
   can attach the Tugboat session id to its events, so a crash there links
   to our replay.
6. **Rollout is opt-in** until the collector accepts the new events,
   following ADR 0005.

## Considered options

- **Full in-process crash capture now** (our own signal and Mach handlers).
  Closest to a full crash reporter and the only way to see crashes before
  Android 11. Rejected for now: the highest-risk code in the SDK, it can break the
  app's existing crash reporter, and Android's own exit records already
  give more context on Android 12 and later.
- **Integration only** (session id on an existing crash reporter's events). Cheap
  and safe, but leaves apps without those tools with nothing, and keeps the
  errors out of Tugboat's own evidence.
- **Errors in a separate pipeline** beside sessions. Rejected: errors are
  most useful in the session's timeline, and the engine already bounds and
  delivers evidence.

## Consequences

- A new evidence event and its collector mapping. This is a capture
  contract change in the sense of `AGENTS.md`: the collector and Context
  Graph must accept `error` before it is on by default.
- Coverage depends on OS version. Below Android 11 there are no native
  crash or ANR reports (ANRs could be detected with SIGQUIT interception, a
  separate decision). Android 11 gives the reason and signal without a
  stack. iOS reports arrive late and are tied to a session only through our
  own marker.
- Release stacks are unreadable until symbols are uploaded and applied.
  Symbol upload tooling and symbolication are tracked as their own work,
  with the option of handing that part to an existing service.
- iOS out-of-memory and watchdog terminations are inferred, not observed,
  and are labelled that way.
- The native hosts gain launch-time work: reading exit records and
  MetricKit payloads. It runs off the main thread, within the UI-thread
  budget from ADR 0009.

## Sources

The vendor-by-vendor review is kept outside this repository. Platform
references:

- Android `ApplicationExitInfo`:
  https://developer.android.com/reference/android/app/ApplicationExitInfo
- Apple Developer Forums, guidance on in-process crash reporters:
  https://developer.apple.com/forums/thread/113742
