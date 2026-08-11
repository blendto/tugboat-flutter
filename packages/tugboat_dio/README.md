# tugboat_dio

Dio adapter for Tugboat network evidence. Records method, bounded route path,
status, outcome, and duration into an active Tugboat session. HTTP error
responses additionally retain bounded JSON/text bodies. Successful response
bodies, headers, queries, raw transport errors, and stack traces are omitted.

Requires `tugboat` `0.9.0` (lockstep).

## Install

```yaml
dependencies:
  tugboat: ^0.9.0
  tugboat_dio: ^0.9.0
```

## Usage

Supply a host-owned route path resolver. Unmatched routes are dropped.

```dart
import 'package:dio/dio.dart';
import 'package:tugboat_dio/tugboat_dio.dart';

final dio = Dio();

// Configure auth/retry/cache interceptors first, then install Tugboat last.
// Dio runs error interceptors in FIFO order, so retry handlers must recover
// before Tugboat finishes the observation token.
TugboatDioInterceptor.install(
  dio,
  routeResolver: (request) => apiRouteTemplate(request.path),
);
```

`apiRouteTemplate` must return a bounded absolute path. Dynamic identifier
segments are allowed. Return `null` or `''` to drop the call. The adapter also
drops resolver output that contains a scheme, query, fragment, percent-encoded
data, a network-path prefix, backslash, or whitespace/control character. Route
paths can contain user or tenant identifiers. Hosts must apply their own
privacy and retention policy.

## Interceptor ordering

| Position | Why |
| --- | --- |
| After auth/retry | Dio error handlers run FIFO; auth must recover a 401 before Tugboat emits |
| After short-circuiting cache | Requests resolved before Tugboat's `onRequest` are not observed |
| Compatible with Sentry | Follow Sentry's required init order; keep one Tugboat interceptor per `Dio` |

`install` appends to the interceptor list and is a no-op when a
`TugboatDioInterceptor` is already present. Namespaced `RequestOptions.extra`
state prevents duplicate tokens when a retry calls `dio.fetch` with the same
options. The state is owned by a private typed envelope and is removed after a
terminal response or error. If the host already owns the reserved
`tugboat.network_call` key, observation is skipped and that value is preserved.

Cached/interceptor-resolved responses are recorded when they pass through this
interceptor's response path (for example `handler.resolve(response, true)` so
following response interceptors run).

Before invoking the route resolver or attaching request state, the adapter
checks whether the SDK is accepting evidence. Dormant, disabled, deactivating,
not-yet-started, and ended sessions therefore leave networking and
`RequestOptions.extra` unchanged. A lifecycle change inside the resolver is
checked again before any state is attached.

## Privacy

- Route templates only — no scheme, host, port, query, or fragment
- Invalid route outputs are dropped before a call is started
- No request bodies, successful response bodies, headers, or cookies
- HTTP status `>= 400`: JSON/text response body only, deep-copied and bounded
  to 16 KiB; binary and unsupported bodies are omitted
- No raw `DioException` messages or stack traces
- Dormant/disabled/deactivating/ended Tugboat → resolver not called, networking
  unchanged, no events
