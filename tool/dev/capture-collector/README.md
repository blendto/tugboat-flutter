# Local capture collector

A development tool that shows exactly what an SDK sends. One Python 3 file,
standard library only, no install.

It answers the endpoints every SDK uses, with `202` like the real collector,
and records everything it receives:

| Endpoint | Body | Response |
|---|---|---|
| `POST /v1/sessions` | JSON session lifecycle (`session_start`, `session_end`, ...) | `202 {"sessionId": <posted id>}` |
| `POST /v1/events/batch` | JSON `{"events": [...]}` | `202 {}` |
| `POST /v1/frames` | multipart: `sessionId`, `frameNos`, `frameMetadata` (JSON), `files` (JPEGs) | `202 {}` |
| `GET /health` | | `200` |

Anything else gets `404`; a malformed body gets `400` (and is still logged).
The Flutter, Android and Apple SDKs all use these three paths.

## Run

```sh
python3 tool/dev/capture-collector/capture_collector.py --port 3000 --out run-flutter
```

It listens on `127.0.0.1` only, because it logs every payload. `adb reverse`
reaches it there. For an emulator at `10.0.2.2` or a phone over the LAN, pass
`--host 0.0.0.0` (anyone on the network can then post to it).

Output folder:

- `requests.jsonl`: one JSON line per request (`time`, `method`, `path`,
  `headers`, parsed `body`). API key and `Authorization`/`Cookie` header values
  are replaced with `[redacted]`.
- `frames/<sessionId>/<frameNo>.jpg`: the decoded frame images.

Stdout gets one line per request, for example
`events   session-... interactionx3 route_changex1`.

## Android phone

```sh
adb reverse tcp:3000 tcp:3000
```

Then give the SDK the collector URL `http://localhost:3000`. (An emulator can
also use `http://10.0.2.2:3000`.)

## Summarise one run

```sh
python3 tool/dev/capture-collector/capture_collector.py summarise run-flutter
```

Prints the sessions, event types with counts, the JSON key paths seen per event
type (the "shape"; nested keys are dotted, e.g. `payload.route`), the frame
count and sizes, and the `network_call` events.

## Compare two runs

```sh
python3 tool/dev/capture-collector/capture_collector.py compare run-flutter run-rn
```

For each event type, lists key paths present in one run but not the other, so a
React Native run can be checked against a Flutter run. Run the same flow in
both. Optional keys that did not occur in a run show up as differences.
