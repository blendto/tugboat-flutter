# tugboat_dio

Dio adapter for Tugboat network evidence. Records method, safe route template,
status, outcome, and duration into an active Tugboat session. Never captures
headers, queries, bodies, raw errors, or stack traces.

Requires `tugboat` `0.6.0` (lockstep).

## Install

```yaml
dependencies:
  tugboat: ^0.6.0
  tugboat_dio: ^0.6.0
```

## Usage

Supply a host-owned route template resolver. Unmatched routes are dropped.

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

`apiRouteTemplate` must return a safe template such as `/blend/:blendId`, never
a raw path containing entity IDs. Return `null` or `''` to drop the call.

## Interceptor ordering

| Position | Why |
| --- | --- |
| After auth/retry | Dio error handlers run FIFO; auth must recover a 401 before Tugboat emits |
| After short-circuiting cache | Requests resolved before Tugboat's `onRequest` are not observed |
| Compatible with Sentry | Follow Sentry's required init order; keep one Tugboat interceptor per `Dio` |

`install` appends to the interceptor list and is a no-op when a
`TugboatDioInterceptor` is already present. Namespaced `RequestOptions.extra`
state prevents duplicate tokens when a retry calls `dio.fetch` with the same
options.

Cached/interceptor-resolved responses are recorded when they pass through this
interceptor's response path (for example `handler.resolve(response, true)` so
following response interceptors run).

## Privacy

- Route templates only — no scheme, host, port, query, or fragment
- No request/response bodies, headers, or cookies
- No raw `DioException` messages or stack traces
- Dormant/disabled Tugboat → networking unchanged, no events
