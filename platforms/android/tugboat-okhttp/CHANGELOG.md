# tugboat-okhttp

## 0.1.0

Unpublished. The OkHttp adapter for the native Android SDK: automatic
`network_call` evidence, the counterpart of Flutter's `tugboat_dio`.

- Public API: `TugboatOkHttpInterceptor(routeResolver: (Request) -> String?)`,
  an application interceptor. Install it first (`addInterceptor`, outermost),
  wrapping the app's auth and retry interceptors; as a network interceptor it
  records nothing. A second instance in the same chain records nothing.
- The resolver's result is trimmed as Dart's `String.trim`; null, blank, or
  a throwing resolver records nothing. It runs only while Tugboat takes
  evidence.
- A response is `complete(statusCode)`; an `IOException` is
  `fail(NETWORK_ERROR)` (timeouts, the call timeout included) and a cancelled
  call `fail(CANCELLED)`, with the exception rethrown unchanged. Other
  throwables are rethrown and record nothing. `attemptCount` is not recorded:
  retries are not observable from the outermost interceptor.
- Error bodies (status 400 or more) follow section 4.5 of
  `core/session-engine/docs/evidence-messages.md`: `peekBody(65_537)` (never
  consumed), JSON by media type (`application/json`, `text/json`, `+json`, as Dio), a
  maximal-subpart UTF-8 decoder, the complete JSON body as `jsonText`, and
  anything else as text cut to 4100 bytes.
- Never read: query strings, headers (except `Content-Type`), request bodies,
  success bodies, and exception text.
- OkHttp is `compileOnly`, compiled against the floor 3.14.9; tested on
  3.14.9, 4.12.0, and 5.3.2.
- Depends on `tugboat-android` 0.1.0 and its opt-in HTTP-adapter seam
  (`com.tugboat.android.adapter`).
