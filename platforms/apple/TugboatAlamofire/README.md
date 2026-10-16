# TugboatAlamofire

An optional Alamofire `EventMonitor` that records each logical request as
Tugboat `network_call` evidence. It is the Alamofire counterpart of
`tugboat_dio` and `tugboat-okhttp`, with the same payload as
`Tugboat.beginNetworkCall`.

- Its own SwiftPM package (this directory's `Package.swift`), so the root
  package never makes `Tugboat` users fetch Alamofire. It depends on the
  root package by path and on Alamofire `5.9.0..<6.0.0`. 5.9.0 is the first
  release with Alamofire's privacy manifest; the events used here exist
  since 5.0.
- SwiftPM only: there is no podspec, because `Tugboat` has none yet.
- iOS 15+ (macOS 12+ builds). Versioned on its own (ADR 0008): 0.1.0,
  unpublished ([CHANGELOG](CHANGELOG.md)).

```swift
import Alamofire
import TugboatAlamofire

let session = Session(
  interceptor: authAndRetry,
  eventMonitors: [TugboatAlamofireMonitor { request in
    router.route(for: request)          // "/orders/123"; nil records nothing
  }])
```

## What it records

- **One event per `Request`**, however many attempts it took. Alamofire's
  retries (`RequestRetrier`, `RetryPolicy`, `AuthenticationInterceptor`)
  reuse the `Request`, so `attemptCount` is `retryCount + 1`. Redirects
  happen inside one attempt.
- **Timing**: the call begins when Alamofire makes the first attempt's
  `URLRequest` (after `RequestAdapter`s run, as a Dio interceptor installed
  after auth sees it) and ends when the request finishes. Both times come
  from the host clock.
- **Outcome**, as `tugboat_dio` maps Dio's:
  - a cancelled request (`cancel()` or `URLError.cancelled`) is `cancelled`;
  - a request with an HTTP response is `response` with its status code,
    validation and serialization failures included;
  - anything else (transport errors, timeouts, adaptation or retry
    failures) is `network_error`.
- **Error body**, for a status of 400 or more on a `DataRequest` (uploads
  included): taken from the `Data` Alamofire already holds, never re-read.
  Only its first 65,537 bytes are looked at.
  - Complete (64 KiB or less) with a JSON `Content-Type` (`application/json`
    or `+json`, any case, parameters ignored): sent whole as JSON text, and
    the session engine decodes and bounds it as Dart does.
  - Otherwise: text, decoded as UTF-8 with U+FFFD replacement and cut to
    whole characters within 4100 bytes (evidence-messages.md section 4.5).
  - Download and stream requests, and empty bodies, record no body.
- **Route**: only from the resolver. It runs once per request, with the
  first attempt's `URLRequest`, and only while Tugboat takes evidence. Its
  result is trimmed as Dart's `String.trim` trims. Nil, empty, or a throw
  records nothing. Query strings, headers (except `Content-Type`, to
  classify an error body), request bodies, and error text are never read.

## Limits

- Alamofire reports a request finished before its response serializers
  run. A retry that a serializer asks for (for example an
  `AuthenticationInterceptor` refresh after a 401 that was not
  `validate()`d) comes after the call was recorded. The first finish is
  kept, and later attempts of that `Request` are ignored. Call
  `validate()` so retries are decided before the request finishes.
- Requests whose adapter fails before any `URLRequest` exists record
  nothing, as a Dio request rejected by an earlier interceptor does.
- The monitor sees only the `Session`s it is passed to.
- Events arrive on the monitor's own serial `queue`. Nothing it does throws
  or traps into the app, and requests and responses are unchanged.

## Build and test

Needs Xcode and network access (to fetch Alamofire). From the repository
root:

```sh
bash tool/ci/test-apple-alamofire.sh     # resolve, then xcodebuild test on an iOS simulator
```

CI runs it as the `alamofire` job of `.github/workflows/apple-host.yml`.
The tests run real Alamofire `Session`s over a test-only `URLProtocol` and
tap the SDK's evidence (`TugboatAdapters.tapEvidenceForTesting`). They
check the message the engine would receive for 200, a 404 JSON body, a 500
text body, a JSON body over 64 KiB, timeout, cancel, redirect, a retried
request (one event, `attemptCount` 2), retries that run out, and the
resolver and admission no-ops. They also check that no query, header, or
request body reaches the message, and that the app's response data is
intact.
