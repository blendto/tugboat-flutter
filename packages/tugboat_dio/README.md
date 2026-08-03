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

// Install at the start of the interceptor chain, before auth/retry handlers,
// so interceptor-level retries resolve before Tugboat emits.
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
| Before auth/retry | Auth can recover a 401 and resolve the final response before Tugboat finishes the token |
| Before/independent of cache | Cached or interceptor-resolved responses still emit one logical observation |
| Compatible with Sentry | Follow Sentry's required init order; keep one Tugboat interceptor per `Dio` |

`install` inserts at index `0` and is a no-op when a `TugboatDioInterceptor`
is already present.

## Privacy

- Route templates only — no scheme, host, port, query, or fragment
- No request/response bodies, headers, or cookies
- No raw `DioException` messages or stack traces
- Dormant/disabled Tugboat → networking unchanged, no events
