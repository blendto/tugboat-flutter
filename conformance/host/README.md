# Platform host fixtures

Byte-exact fixtures shared by the native platform hosts (ADR 0009): the
Android host in `platforms/android/tugboat-android` and the Apple host in
`platforms/apple/Sources/Tugboat`. They pin what the hosts put on the wire, so
both stay identical to each other and to the Flutter `CollectorHttpSink`.
The engine and Dart conformance runners read only `*.json`, so they skip
these files.

## `multipart-request.golden`

The `POST /v1/frames` body that Dart's `http.MultipartRequest` writes (every
field in order, then every file), for these inputs:

| Part | Name | Value |
| --- | --- | --- |
| field | `sessionId` | `s-1` |
| field | `frameNos` | `1,2` |
| field | `label` | `café` (non-ASCII, so the part declares `text/plain; charset=utf-8` and `binary`) |
| field | `a"b` CR LF `c` | `v` (the name is browser-encoded to `a%22b%0D%0Ac`) |
| file | `files`, filename `1.jpg`, `image/jpeg` | the ASCII bytes `JPEG` |
| file | `files`, filename `2.jpg`, `image/jpeg` | the bytes `FF D8 0D 0A FF D9` |

The boundary is `b`. Lines end in CR LF, and the file is binary
(`.gitattributes`), so git never rewrites its line endings.

Readers:

- Android: `MultipartBodyTest` (the Gradle unit tests get this directory as
  the `tugboat.hostFixtures` system property).
- Apple: `MultipartBodyTests` (path resolved from `#filePath`).
