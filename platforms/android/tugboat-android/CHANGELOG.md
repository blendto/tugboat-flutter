# tugboat-android

## 0.1.0

Unpublished. Platform plumbing only, with no public API and no toolkit adapter.

- `libtugboat_engine.so`: the session engine (`core/session-engine`) built
  with `c++_static`, plus a JNI bridge (`create`, `submit`, `destroy`) that
  copies each engine response into a Java `byte[]`. No exception crosses
  JNI.
- Engine host: one handle driven from one `tugboat-engine` thread. Facts are
  posted with their own `at`. A non-`ok` status drops the message and releases
  its frame handles. Repeated `internal_error` shuts the host down.
  Shutdown first submits `engine.dispose` (the engine reports undelivered
  work), honouring its `frame.release` but starting no new IO or timers.
- Effect executors:
  - `timer.schedule` / `timer.cancel` (uptime clock);
  - `http.send` (`HttpURLConnection`, Flutter collector headers and
    multipart layout, `timeoutMs` as a total deadline, a response body of
    at most 64 KiB cut at a UTF-8 boundary, and statuses outside 100–599
    reported as `error`, so the engine never rejects a `transport.result`);
  - `frame.release` (frame handle table).
