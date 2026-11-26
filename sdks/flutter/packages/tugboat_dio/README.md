# Tugboat for Dio

See which API calls finished, failed, or were cancelled during a Flutter
session. Install one interceptor on the Dio client your app already uses.
Each observed call adds a `network_call` event to the active Tugboat session
with its method, route, duration, outcome, and HTTP status when available.

## Install and record your first call

Set up [Tugboat capture](https://pub.dev/packages/tugboat) in your app, then
add the adapter from your app directory. For Tugboat 0.12.x, use
`tugboat_dio` 0.12.x. The adapter requires Dio 5.4 or newer within 5.x.

```sh
flutter pub add tugboat_dio
```

Call this function when configuring your existing client, after its auth,
retry, and cache interceptors. This example records the orders endpoint
and keeps only network metadata, including on HTTP errors.

```dart
import 'package:dio/dio.dart';
import 'package:tugboat_dio/tugboat_dio.dart';

void observeOrders(Dio dio) {
  TugboatDioInterceptor.install(
    dio,
    routeResolver: (request) => request.path == '/orders' ? '/orders' : null,
    errorBodyUrls: const [],
  );
}
```

**Verify it.** With capture active, make a request through that client using
`dio.get('/orders')`. After it finishes, inspect
`TugboatReplay.controller?.session?.events` in the debugger. Look for
`type == 'network_call'`, `stream == TugboatEventStream.evidence`, and
`data['route'] == '/orders'`. A request that receives an HTTP response also
has `data['statusCode']`. Use the interceptor once per client and skip manual
`beginNetworkCall` instrumentation for the same requests.

## Choose which calls to record

`routeResolver` returns the path written into session evidence. Use stable,
app-owned paths. For example, map requests for individual orders to the
literal `/orders/:id` to keep actual order IDs out of the recorded route.
Return `null` or an empty string to skip the entire observation. The
resolver runs only while Tugboat accepts evidence.

A valid route starts with a single slash. The SDK rejects routes containing
a scheme, query, fragment, percent escape, backslash, or embedded whitespace
or control characters. Dynamic identifier segments are accepted, so the
resolver determines whether those IDs appear in evidence.

## Choose which error bodies to keep

**By default, observed HTTP responses with status 400 or higher can include
up to 4 KiB of JSON or text from the response body.** Error messages can
contain user data. Choose the policy when installing the interceptor:

| Desired behavior | Install option |
| --- | --- |
| Keep metadata only for all requests | `errorBodyUrls: const []` |
| Keep error bodies only from the orders endpoint | `errorBodyUrls: const ['api.example.com/orders']` |
| Allow a host but exclude accounts and their descendants | `errorBodyUrls: const ['api.example.com']` and `errorBodyDenyUrls: const ['api.example.com/accounts', 'api.example.com/accounts/*']` |

These filters examine the actual request host and path, independently of the
route returned by your resolver. A deny match wins. Excluding a body still
records the call. Request bodies, successful response bodies, headers,
cookies, raw transport errors, and stack traces are omitted.

### URL pattern reference

- Write `host` or `host/path`, without a scheme, port, query, or fragment.
  Matching is case-insensitive. A host alone covers every path and port on
  that exact host.
- `*` is the only wildcard. A host wildcard stays within the host. A path
  wildcard can span slashes. Use an exact host for an allow list:
  `api.example.com*` also matches `api.example.com.evil.test`.
- Paths are matched in normalized, percent-encoded form. Use one slash
  between segments, omit dot segments, and write escapes in full.
- With redirect information from the HTTP adapter, the policy checks the
  initial URL and every reported hop. All must pass the policy. The default
  IO adapter reports redirects. With an adapter that omits redirect history,
  only the initial request URL can be checked.
- Invalid patterns assert in debug builds. In release, an invalid deny
  pattern suppresses all bodies. Only valid allow patterns can permit a body.
  An unparseable URL suppresses its body whenever a filter is configured.

## Retries, caches, and missing events

| Symptom | What to check |
| --- | --- |
| A recovered 401 appears as the final status | Install Tugboat after the auth and retry interceptors so they can recover first. Retries using the same `RequestOptions` share an observation and increment its attempt count. |
| A cache hit has no event | A cache that resolves the request before Tugboat sees it can bypass observation. Check whether the interceptor’s request and response handlers ran. |
| No calls appear | Check that the client making the request is instrumented, Tugboat has an active session, and the resolver returns a valid route. The adapter also skips observations if the host already owns `RequestOptions.extra['tugboat.network_call']`. |
| Changing the body policy has no effect | `install` returns `false` if that client already has a Tugboat interceptor. Set the policy on the original installation. |
