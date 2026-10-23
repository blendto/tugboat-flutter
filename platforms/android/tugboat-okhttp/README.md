# tugboat-okhttp

OkHttp adapter for the native Android SDK: it records each logical OkHttp
call as `network_call` evidence, as Flutter's `tugboat_dio` does for Dio.
Maven coordinates `com.gettugboat.sdk:tugboat-okhttp:0.1.0`, namespace
`com.tugboat.android.okhttp`, minSdk 24. Versioned on its own (ADR 0008, see
[CHANGELOG](CHANGELOG.md)) and unpublished: the only repository is the
untracked `.local-maven`.

It depends on [`tugboat-android`](../tugboat-android/README.md) and goes
through its public `Tugboat.beginNetworkCall` API. OkHttp is `compileOnly`:
the app ships it (see [OkHttp versions](#okhttp-versions)).

## Install order

Add the interceptor **first**, with `addInterceptor`, so that it wraps every
other application interceptor:

```kotlin
val client = OkHttpClient.Builder()
    .addInterceptor(TugboatOkHttpInterceptor { request -> routeOf(request) })  // first: outermost
    .addInterceptor(authInterceptor)    // the app's auth
    .addInterceptor(retryInterceptor)   // the app's retries
    .build()
```

Why first:

- OkHttp runs application interceptors in the order they were added. Each one
  wraps the ones added after it: it sees the request before them and the
  response after them.
- OkHttp's own retries, redirects, and follow-ups (auth challenges, 408,
  503 `Retry-After: 0`) run below all application interceptors.
- So the outermost interceptor sees exactly one request and one final
  response or failure per call. An interceptor added before it that calls
  `chain.proceed` twice (a retry) would make two events.

The native evidence spec says to install the adapter **after** auth and
retry interceptors. That is Dio's wording: Dio runs error interceptors in
the order they were added, so its adapter must come after the retry handlers
to finish the call only once they have recovered. In OkHttp the same
guarantee comes from wrapping: the adapter finishes the call after the auth
and retry interceptors inside it have returned. "After" means "wrapping",
which in OkHttp is added first.

Never install it with `addNetworkInterceptor`: a network interceptor sees
each redirect and retry hop. Installed that way it records nothing (it has a
connection, which application interceptors never have). Installed twice in
one chain (for example a client built with `newBuilder()` from one that has
it), only the outer instance records.

## What it records

| OkHttp | `network_call` |
| --- | --- |
| `chain.proceed` returns a response | `complete(statusCode)`, outcome `response`; for status 400 or more, a bounded error body (below) |
| An `IOException`, timeouts included (connect, read, write, and the call timeout) | `fail(NETWORK_ERROR)` |
| A cancelled call (`Call.cancel()`, before or during the call) | `fail(CANCELLED)` |
| Any other throwable (a bug in an interceptor below) | nothing |

- The exception is always rethrown unchanged, and the request and response
  are passed on unchanged: the app sees exactly what it would see without
  the interceptor.
- **Cancel or timeout.** OkHttp cancels the call when its call timeout fires,
  so the interceptor sees a cancelled call either way. A call that fails
  within 20 ms of its call timeout, or later, is a timeout
  (`NETWORK_ERROR`); an `InterruptedIOException` is always a timeout.
- **Method** is the request's; the engine trims and upper-cases it.
- **Route** comes only from the resolver (below).
- **Timing.** The start is taken when the interceptor runs (before the app's
  interceptors inside it); the end when the response headers arrived (plus
  the peek of an error body) or the call failed. The engine computes
  `durationMs`.
- **`attemptCount` is not recorded.** Outermost, the interceptor makes one
  `chain.proceed` call; retries by the app's interceptors and OkHttp's own
  retries happen inside it and are not visible to it. A `priorResponse`
  chain shows redirects and auth follow-ups, which are not retries, and
  OkHttp's connection-failure retries leave no trace on the response.
  Counting any of them would be a guess, so the field is left out (the
  engine omits it, as for a manual call without one). Dio's adapter records
  it because Dio replays the whole interceptor chain for each retry.
- **Threads.** It runs on OkHttp's calling thread (`execute`) or dispatcher
  thread (`enqueue`). The SDK's network-call API is callable from any thread.

### The route resolver

`TugboatOkHttpInterceptor(routeResolver: (Request) -> String?)` is required.
It maps a request to a route path you choose: an absolute path, which may
hold dynamic ids (`/orders/123`) or a template (`/orders/{id}`), never a full
URL, query, or fragment.

- Its result is trimmed as Dart's `String.trim` trims (as `tugboat_dio`
  does). Null, blank, or a resolver that throws records nothing, and the
  call goes on untouched.
- It runs once per call, on the calling thread, and only while Tugboat takes
  evidence (started, not stopped or disabled).
- The engine drops a route with a scheme, query, fragment,
  percent-encoding, backslash, or whitespace; the call still goes on. Route
  paths can hold user or tenant ids: apply your own privacy policy.

## Error bodies

Read only for status 400 or more, by the rules of section 4.5 of
[`evidence-messages.md`](../../../core/session-engine/docs/evidence-messages.md)
("a byte-reading adapter"):

- `response.peekBody(65_537)`. The real body is never consumed: peeking
  buffers the first bytes, and the app reads them later as usual. The body
  is complete if and only if at most 65,536 bytes came back; `Content-Length`
  is not trusted.
- The media type is JSON when `Content-Type`, compared case-insensitively
  with its parameters ignored, is `application/json`, `text/json`, or any
  `+json` subtype (`application/problem+json`): Dio's rule.
- Bytes are decoded as UTF-8, each maximal ill-formed subsequence replaced
  by one U+FFFD (the Unicode "maximal subpart" practice of Dart and Swift).
  The decoder is the module's own: the JVM's `REPLACE` decoder gives one
  U+FFFD for an encoded surrogate (`ED A0 80`) where the practice gives
  three.
- Complete and JSON: the decoded body goes to the engine whole, as
  `jsonText`; the engine parses it as Dart's `jsonDecode` does and bounds it
  to 4 KiB. Text that is not valid JSON is recorded as text.
- Otherwise: text, cut to the whole characters within the first 4100 bytes
  (the engine keeps 4096 bytes). A JSON body over 64 KiB is therefore text,
  where Dio would record a JSON `serialized_prefix`; both are cut to 4 KiB.
- Peeking reads up to 64 KiB of an error body before the call returns. A
  read error while peeking drops the body (the status is still recorded);
  the app sees the same error when it reads the body.
- OkHttp decompresses gzip bodies below the application interceptors, so the
  peek sees the decoded bytes, unless the app set `Accept-Encoding` itself.

## Never read

URLs (other than through the resolver), query strings, headers (other than
`Content-Type`, to classify an error body), cookies, request bodies, success
response bodies, and exception messages. Nothing Tugboat does throws into
the call: every failure on the evidence path is swallowed.

## OkHttp versions

OkHttp is `compileOnly`, so the module never changes the app's OkHttp
version. It compiles against the floor, **3.14.9** (the last 3.x, still
pulled in by Retrofit 2.9), so it calls no newer API. Every call it makes
(`Chain.call()`, `Chain.connection()`, `Call.timeout()`, `peekBody`) exists
from 3.14 through 5.x. The unit tests run on 5.3.2 by default;
`-Ptugboat.okhttpTest=3.14.9` and `-Ptugboat.okhttpTest=4.12.0` run them on
the floor and the last 4.x (CI runs all three). OkHttp
versions below 3.14.9 are not tested or supported.

## Build and test

From `platforms/android`:

```sh
./gradlew :tugboat-okhttp:test                                          # OkHttp 5.3.2
./gradlew -Ptugboat.okhttpTest=3.14.9 :tugboat-okhttp:testDebugUnitTest  # the floor
./gradlew -Ptugboat.okhttpTest=4.12.0 :tugboat-okhttp:testDebugUnitTest
./gradlew :tugboat-okhttp:assembleRelease
```

- `TugboatOkHttpInterceptorTest` (Robolectric, MockWebServer): 200, 404 with
  a JSON body, 500 with a text body, JSON over 64 KiB, the 64 KiB boundary,
  read and call timeouts, cancels, async calls, a redirect (one event), an
  app retry interceptor inside (one event, no `attemptCount`) and outside
  (two events), no query, header, or request body in the engine message,
  the request reaching the server unchanged, the app reading the full body,
  resolver no-ops, network-interceptor and duplicate installs, and nested
  calls. Messages are captured on the evidence path
  (`TugboatAdapters.tapEvidenceForTesting`: the real recorder and encoder,
  with the engine replaced by a list).
- `TugboatOkHttpFixturesTest` serves each
  `conformance/evidence/network_call/*json-text*` fixture's body as UTF-8
  bytes and checks that the engine input carries it unchanged.
  `EvidenceFixturesDeviceTest` in `tugboat-android` runs the same inputs
  through the real engine on emulators.
- `Utf8Test`: the maximal-subpart examples of Unicode section 3.9, including
  `ED A0 80` as three U+FFFD. `ErrorBodiesTest`: media types, completeness,
  and the text cut.

`bash tool/ci/build-android-runtime.sh` from the repository root runs all of
these.
