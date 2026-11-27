## 0.12.9

### Changed

- Compatibility release for `tugboat` 0.12.9 (tap target actions fix). No
  `tugboat_dio` change; its `tugboat` floor is now `^0.12.9`.

## 0.12.8

### Changed

- Compatibility release for `tugboat` 0.12.8 (screenshot masking fix). No
  `tugboat_dio` change; its `tugboat` floor is now `^0.12.8`.

## 0.12.7

### Changed

- Compatibility release for `tugboat` 0.12.7 (sink failures stay inside the
  SDK). The Dio adapter has no runtime behavior change; its `tugboat` floor is now `^0.12.7`.

## 0.12.6

### Changed

- Compatibility release for `tugboat` 0.12.6 (dot-notation markers and an
  opt-in accessibility identifier on tags). The Dio adapter has no runtime
  behavior change; its `tugboat` floor is now `^0.12.6`.

## 0.12.5

### Changed

- Compatibility release for `tugboat` 0.12.5 (iOS `device.model` is the
  hardware identifier). The Dio adapter has no runtime behavior change; its
  `tugboat` floor is now `^0.12.5`.

## 0.12.4

### Changed

- Compatibility release for `tugboat` 0.12.4 (production taps carry
  `routeKey`). The Dio adapter has no runtime behavior change; its `tugboat`
  floor is now `^0.12.4`.

## 0.12.3

### Changed

- Compatibility release for `tugboat` 0.12.3 (session and event IDs are
  UUID-scoped). The Dio adapter has no runtime behavior change.

## 0.12.2

- Updated interceptor setup, event verification, retry guidance, and error-body privacy examples.

## 0.12.0

### Changed

- Compatibility release for `tugboat` 0.12.0 (loading-state detection and
  the `TugboatLoading` marker removed). Requires `tugboat` `^0.12.0`. The Dio
  adapter has no runtime behavior change.

## 0.11.6

### Changed

- Compatibility release for `tugboat` 0.11.6 (opt-in tap press duration).
  The Dio adapter has no runtime behavior change.

## 0.11.5

### Changed

- Compatibility release for `tugboat` 0.11.5 (`session_start` sends an
  SDK-minted `appInfo.installationId`). The Dio adapter has no runtime
  behavior change.

## 0.11.4

### Changed

- Compatibility release for `tugboat` 0.11.4 (a navigating tap on a button's
  padding records the button's `GestureDetector` again). The Dio adapter has
  no runtime behavior change.

## 0.11.3

### Added

- Privacy-boundary option, default unchanged: `TugboatDioInterceptor` (and
  `install`) accept `errorBodyDenyUrls` and `errorBodyUrls` to control which
  request URLs may keep an HTTP error response body. Both default to "no
  restriction" (`errorBodyDenyUrls` empty, `errorBodyUrls` null), so every
  HTTP error body is retained exactly as in 0.11.2 unless a host opts in.
  A pattern is a case-insensitive `host` or `host/path` glob with `*` as the
  only wildcard. It is split at its first `/`: in the host part `*` never
  reaches into the path, in the path part `*` matches any run of characters,
  and a pattern with no `/` matches that whole host with any path. An empty
  URL path counts as `/`; dot segments are resolved and runs of `/` collapse
  before matching. Only the host and path of `baseUrl` + `path` are compared;
  the scheme, port, user-info, query, `queryParameters` and fragment are never
  read, and ports are not matched. A redirected response is checked at its
  request URL and at every redirect hop, each resolved against the hop before
  it (this relies on the HTTP adapter reporting `Response.redirects`, as the
  default IO adapter does): any URL matching a deny pattern drops the body, and
  an allow list must allow every URL. A deny match always drops the body;
  when `errorBodyUrls` is set, only matching URLs keep one (an empty list keeps
  none). An excluded URL, or one that cannot be parsed while a list is set,
  still records its method, route, status, outcome and duration, without the
  body.
- Unusable patterns fail closed. Patterns that are not accepted (blank,
  starting with `/`, or containing a scheme, port, user-info, IPv6 brackets,
  query, fragment, whitespace, non-ASCII, or a path character Dart rewrites
  such as `[ ] { } | ^ " < >`, a backtick or a backslash; paths are matched in
  percent-encoded form; or a path that the compared path can never contain:
  `//`, a `.` or `..` segment, or an escaped unreserved character such as
  `%7E`; or a `%` not followed by two literal hex digits, where a `*` is not
  accepted in place of the digits) fail an `assert` in debug builds that names
  them and never throw while requests run. In release builds, if any
  `errorBodyDenyUrls` entry is unusable the interceptor drops every error body
  (for example a deny entry that includes the scheme), and an `errorBodyUrls`
  list with no usable pattern keeps none; an unusable entry among usable
  `errorBodyUrls` entries is skipped.
- Matching uses an iterative glob matcher with no regular expressions, so
  adjacent `*` cannot cause slow matching.

### Fixed

- README: error response bodies are bounded to 4 KiB each (it said 16 KiB,
  which is the collector's whole `network_call` payload cap).

## 0.11.2

### Changed

- Compatibility release for `tugboat` 0.11.2 (collector sink health counts and
  monotonic lifecycle durations). The Dio adapter has no runtime behavior
  change.

## 0.11.1

### Changed

- Compatibility release for `tugboat` 0.11.1 (collector frame delivery under
  stalled or failing uploads). The Dio adapter has no runtime behavior change.

## 0.11.0

### Changed

- Compatibility release for `tugboat` 0.11.0 (fingerprint schema 7, exploration
  inventory metadata, exploration WebSocket removed). Requires `tugboat`
  `^0.11.0`. The Dio adapter has no runtime behavior change.

## 0.10.11

### Changed

- Compatibility release for `tugboat` 0.10.11 (a tap whose handler navigates
  keeps its target). The Dio adapter has no runtime behavior change.

## 0.10.10

### Changed

- Compatibility release for `tugboat` 0.10.10 (the visible navigator route is
  seeded at session start with one `route_change`, `navigation: session_start`).
  The Dio adapter has no runtime behavior change.

## 0.10.9

### Changed

- Compatibility release for `tugboat` 0.10.9 (collector frame upload
  isolation and bounded `capture_diagnostic` delivery events). The Dio
  adapter has no runtime behavior change.

## 0.10.8

### Changed

- Compatibility release for `tugboat` 0.10.8 (structure-aware perceptual
  frame coalescing; opt-in `focus_changed` / `system_input` evidence). The
  Dio adapter has no runtime behavior change.

## 0.10.7

### Changed

- Compatibility release for `tugboat` 0.10.7 (API error `network_call`
  events carry a bounded `errorResponseBody`). The Dio adapter has no
  runtime behavior change.

## 0.10.6

### Changed

- Compatibility release for `tugboat` 0.10.6 (`frameMetadata` on collector frame
  uploads). The Dio adapter has no runtime behavior change.

## 0.10.5

### Changed

- Compatibility release for `tugboat` 0.10.5 (iOS accepts the launch inputs from
  launch arguments as well as the process environment). The Dio adapter has no
  runtime behavior change.

## 0.10.4

### Changed

- Compatibility release for `tugboat` 0.10.4 (canonical `interaction`
  `targetAnchor` includes `canonicalPath` on collector payloads). The Dio
  adapter has no runtime behavior change.

## 0.10.3

### Changed

- Compatibility release for `tugboat` 0.10.3 (non-secret automation run
  correlation id on the launch plumbing). The Dio adapter has no runtime
  behavior change.

## 0.10.1

### Fixed

- Cancelled Dio calls no longer forward an HTTP status code. Cancelled is not
  an HTTP response.

## 0.10.0

### Changed

- Compatibility release for `tugboat` 0.10.0. The Dio
  adapter has no runtime behavior change.

## 0.9.0

### Changed

- Compatibility release for the mode-free `tugboat` 0.9.0 API. The Dio
  adapter has no runtime behavior change.

## 0.8.17

### Changed

- Compatibility release for `tugboat` 0.8.17. The Dio adapter has no runtime
  behavior change.

## 0.8.16

### Changed

- Compatibility release for `tugboat` 0.8.16. The Dio adapter has no runtime
  behavior change.

## 0.8.15

### Changed

- Compatibility release for `tugboat` 0.8.15. The Dio adapter has no runtime
  behavior change.

## 0.8.14

### Changed

- Compatibility release for `tugboat` 0.8.14. The Dio adapter has no runtime
  behavior change.

## 0.8.13

### Changed

- Compatibility release for `tugboat` 0.8.13. The Dio adapter has no runtime
  behavior change.

## 0.8.12

### Changed

- Compatibility release for `tugboat` 0.8.12. The Dio adapter has no runtime
  behavior change.

## 0.8.11

### Changed

- Refactor interceptor control flow to keep cyclomatic complexity at or below
  10 without changing network evidence behavior.
- Require `tugboat` 0.8.11.

## 0.8.10

### Changed

- Compatibility release for `tugboat` 0.8.10. The Dio adapter has no runtime
  behavior change.

## 0.8.9

### Changed

- Compatibility release for `tugboat` 0.8.9. The Dio adapter has no runtime
  behavior change.

## 0.8.8

This release follows `0.8.0` and stays on the `0.8.x` line as `0.8.8`.

### Changed

- Compatibility release for `tugboat` 0.8.8. The Dio adapter has no runtime
  behavior change.

## 0.8.7

This release follows `0.8.0` and stays on the `0.8.x` line as `0.8.7`.

### Changed

- Compatibility release for `tugboat` 0.8.7. The Dio adapter has no runtime
  behavior changes.

## 0.8.6

This release follows `0.8.0` and stays on the `0.8.x` line as `0.8.6`.

### Changed

- Compatibility release for `tugboat` 0.8.6. The Dio adapter has no runtime
  behavior changes.

## 0.8.5

This release follows `0.8.0` and stays on the `0.8.x` line as `0.8.5`.

### Changed

- Compatibility release for `tugboat` 0.8.5. Route resolvers may retain
  dynamic identifier segments in bounded absolute paths.

## 0.8.0

### Changed

- Compatibility release for `tugboat` 0.8.0. The Dio adapter has no runtime
  behavior changes.

## 0.7.1

### Changed

- Compatibility release for `tugboat` 0.7.1. The Dio adapter has no runtime
  behavior changes.

## 0.7.0

### Changed

- Compatibility release for `tugboat` 0.7.0. The Dio adapter has no runtime
  behavior changes.

## 0.6.0

### Added

- Initial `TugboatDioInterceptor` that maps Dio request lifecycle callbacks to
  the core Tugboat network observation token.
- `TugboatDioInterceptor.install` appends to the interceptor chain (after
  auth/retry) and rejects duplicate installation on the same `Dio` instance.

### Fixed

- Inactive or ended capture no longer invokes the host route resolver or
  mutates `RequestOptions.extra`.
- Adapter-owned request state is cleaned up after terminal callbacks without
  deleting colliding host metadata.
