# TugboatAlamofire

Versioned on its own (ADR 0008).

## 0.1.0

Unpublished. SwiftPM only (no podspec).

- `TugboatAlamofireMonitor(routeResolver:)`: an Alamofire `EventMonitor`
  that records one `network_call` per logical `Request`, with
  `attemptCount` (`retryCount + 1`). It times each request on the host
  clock, from the first attempt's `URLRequest` to the finish, and maps
  outcomes as `tugboat_dio` does: cancelled, response with its status, or
  network error.
- Error bodies for status 400 or more on `DataRequest`s, from the data
  Alamofire already holds (at most 65,537 bytes read): JSON text when
  complete and JSON, otherwise text cut within 4100 bytes.
- Requires `Tugboat` (the root package, by path) and Alamofire 5.9.0 or
  later, below 6.0.0.
