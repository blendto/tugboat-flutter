# tugboat_dio

Dio adapter for Tugboat network evidence. Records method, bounded route path,
status, outcome, and duration into an active Tugboat session. HTTP error
responses additionally retain bounded JSON/text bodies. Successful response
bodies, headers, queries, raw transport errors, and stack traces are omitted.

Versions move in lockstep with `tugboat`: use the same version of both packages.

## Install

```yaml
dependencies:
  tugboat: ^0.8.16
  tugboat_dio: ^0.8.16
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
  routeResolver: (request) => request.path,
);
```

`routeResolver` must return a bounded absolute path. Dynamic identifier
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

## Choosing which URLs may keep an error body

By default every HTTP error (status `>= 400`) response body is retained,
bounded, for every URL the interceptor observes. Error bodies can contain user
data (for example "no account for someone@example.com"), so two opt-in lists
let a host stop keeping bodies for chosen endpoints:

```dart
TugboatDioInterceptor.install(
  dio,
  routeResolver: (request) => request.path,
  // Never keep a body from these URLs. List the collection URL and its items
  // separately: `/v1/accounts/*` does not match `/v1/accounts`.
  errorBodyDenyUrls: [
    'api.example.com/v1/accounts',
    'api.example.com/v1/accounts/*',
    // Any host, any path containing "password" (the path part is anchored at
    // its start, so a leading `*` is needed to match `/v1/password/reset`).
    '*/*password*',
  ],
  // Optional: keep bodies only from these URLs (default null = every URL).
  errorBodyUrls: ['api.example.com'],
);
```

**Mistyped patterns drop bodies.** A pattern that is not accepted (see
"What a pattern may contain" below) fails an `assert` in debug builds that
names it. In release builds it is never silently ignored in the unsafe
direction: if any `errorBodyDenyUrls` entry is unusable (for example one that
includes the scheme, `https://api.example.com/v1/accounts/*`), the interceptor
drops **every** error body, because it cannot tell what you meant to exclude.
An `errorBodyUrls` list with no usable pattern keeps no bodies; an unusable
entry among usable `errorBodyUrls` entries is skipped. Run a debug build to
catch these early. Nothing here ever throws while requests run.

- Defaults: `errorBodyDenyUrls` is empty and `errorBodyUrls` is `null`, which
  means every URL, so behavior is unchanged unless you set one.
- A pattern is `host` or `host/path`, with `*` as the only wildcard. It is
  matched case-insensitively against the whole host and the whole path of the
  request URL (`baseUrl` + `path`), for example `api.example.com/v1/accounts/42`.
- The pattern is split at its first `/`. In the host part `*` matches within
  the host and never reaches into the path, so `*.example.com/*` does not match
  `https://other.test/x/api.example.com/y`. In the path part `*` matches any
  run of characters, including `/`. A pattern with no `/` is a host pattern
  that matches that whole host with any path. An empty URL path counts as `/`,
  so `api.example.com/*` also matches `https://api.example.com`.
- A bare `*` in the host is a real wildcard: `api.example.com*` also matches
  `api.example.com.evil.test`. Write `api.example.com` to match only that host.
- The request path is compared after dot segments are resolved and runs of `/`
  are collapsed to one, so `//v1/accounts/42` is checked as
  `/v1/accounts/42`.
- Ports are not matched, so `api.example.com` covers every port. The scheme,
  port, user-info, query string, `queryParameters` and fragment are never read,
  so queries that carry personal data are never inspected or logged.
- A deny match always wins over an allow match. When `errorBodyUrls` is set,
  only matching URLs keep a body, and an empty list keeps none.
- Redirects: a redirected response is checked at its request URL and at
  every redirect hop (host and path only). Hops are resolved one after another,
  so a relative `Location` is read against the hop before it. Any URL matching
  a deny pattern drops the body, and with `errorBodyUrls` set every URL must be
  allowed. This relies on the HTTP adapter filling `Response.redirects`: the
  default IO adapter does, and an adapter that does not report redirects only
  gets the request-URL check.
- An excluded URL still records its method, route path, status, outcome and
  duration. Only the body is left out. If a URL cannot be parsed while either
  list is set, the body is left out too.
- Matching is a small iterative glob matcher, not a regular expression, so
  patterns with many `*` cannot slow down request handling.

### What a pattern may contain

`host` or `host/path`, with `*` wildcards, compared case-insensitively. A
pattern is not accepted (see above) if it:

- is blank, or starts with `/`;
- contains whitespace, a control character or a non-ASCII character;
- contains `?` or `#` (no query or fragment);
- has a host part with `:` (no scheme or port), `@` (no user-info) or `[` /
  `]` (no IPv6 literal);
- has a path part with any of `[ ] { } | ^ " < >`, a backtick or a backslash.
  Dart rewrites these in request paths (for example `[` becomes `%5B`), so
  they could never match. The request path is compared in its percent-encoded
  form: write `%5B`, not `[`; hex digits are matched case-insensitively, so
  `%5b` works too;
- has a path part the compared path can never contain. Request paths have
  runs of `/` collapsed, dot segments resolved and percent-escapes normalised,
  so these could never match: `//` (as in `api.example.com//v1/*`), a `.` or
  `..` segment (as in `api.example.com/v1/../admin/*`), and an escape of an
  unreserved character (`%7E`, `%41`, `%2D` and the like; write `~`, `A`, `-`
  instead);
- has a `%` that is not followed by two literal hex digits. A bare `%` becomes
  `%25` in a request path, and a `*` is not accepted in place of the digits
  (`host/a%*` is rejected even though a wildcard could in principle stand for
  them), so write each escape out in full, for example `%2F`.

## Privacy

- Route templates only — no scheme, host, port, query, or fragment
- Invalid route outputs are dropped before a call is started
- No request bodies, successful response bodies, headers, or cookies
- HTTP status `>= 400`: JSON/text response body only, deep-copied and bounded
  to 4 KiB; binary and unsupported bodies are omitted. Retained for every URL
  unless you set `errorBodyDenyUrls` or `errorBodyUrls` (see above)
- No raw `DioException` messages or stack traces
- Dormant/disabled/deactivating/ended Tugboat → resolver not called, networking
  unchanged, no events
