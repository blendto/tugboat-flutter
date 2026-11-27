#!/usr/bin/env python3
"""Local capture collector for SDK development (stdlib only).

  capture_collector.py [serve] [--port 3000] [--out capture-out]
  capture_collector.py summarise <out-dir>
  capture_collector.py compare <out-dir-a> <out-dir-b>

Serves the three endpoints the SDKs use, answers 202 like the real collector,
and writes everything received to <out>/requests.jsonl and <out>/frames/.
"""
import argparse, gzip, json, os, re, sys, time
from collections import Counter, defaultdict
from email.parser import BytesParser
from email import policy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = {"authorization", "cookie", "x-pmkit-api-key", "x-tugboat-api-key"}
SAFE = re.compile(r"[^A-Za-z0-9_.-]")


def clean(s):
    return SAFE.sub("_", str(s))[:100] or "unknown"


# ---------------------------------------------------------------- serve

def parse_multipart(ctype, raw):
    msg = BytesParser(policy=policy.HTTP).parsebytes(
        b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + raw)
    fields, files = {}, []
    for part in msg.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if part.get_filename():
            files.append((part.get_filename(), part.get_payload(decode=True)))
        else:
            fields[name] = part.get_content().strip()
    return fields, files


def make_handler(out):
    os.makedirs(os.path.join(out, "frames"), exist_ok=True)
    log = open(os.path.join(out, "requests.jsonl"), "a", buffering=1)

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def reply(self, code, obj=None):
            data = json.dumps(obj if obj is not None else {}).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self.reply(200 if self.path == "/health" else 404, {"ok": True})

        def do_POST(self):
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if self.headers.get("Content-Encoding") == "gzip":
                raw = gzip.decompress(raw)
            path = self.path.split("?")[0]
            ctype = self.headers.get("Content-Type", "")
            now = time.time()
            rec = {"time": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)) + ".%03dZ" % (now % 1 * 1000),
                   "method": "POST", "path": path,
                   "headers": {k: ("[redacted]" if k.lower() in SECRET else v) for k, v in self.headers.items()}}
            resp, line = {}, ""
            try:
                if path == "/v1/frames":
                    rec["body"], line = self.frames(ctype, raw)
                elif path in ("/v1/sessions", "/v1/events/batch"):
                    body = json.loads(raw or b"{}")
                    rec["body"] = body
                    if path == "/v1/sessions":
                        sid = body.get("sessionId")
                        resp = {"sessionId": sid}
                        line = f"session  {sid} {body.get('eventType')}"
                    else:
                        evs = body.get("events", [])
                        sids = sorted({str(e.get("sessionId")) for e in evs})
                        types = Counter(e.get("eventType") for e in evs)
                        line = f"events   {','.join(sids)} " + " ".join(f"{t}x{n}" for t, n in types.items())
                else:
                    self.reply(404, {"error": "not found"})
                    print(f"404      {path}", flush=True)
                    return
            except Exception as e:  # malformed body: still record it
                rec["error"] = repr(e)
                rec["rawBytes"] = len(raw)
                self.reply(400, {"error": "bad request"})
                log.write(json.dumps(rec) + "\n")
                print(f"400      {path} {e!r}", flush=True)
                return
            log.write(json.dumps(rec) + "\n")
            print(line, flush=True)
            self.reply(202, resp)

        def frames(self, ctype, raw):
            fields, files = parse_multipart(ctype, raw)
            sid = fields.get("sessionId", "unknown")
            d = os.path.join(out, "frames", clean(sid))
            os.makedirs(d, exist_ok=True)
            saved = []
            for name, data in files:
                dest = os.path.join(d, clean(name))
                with open(dest, "wb") as f:
                    f.write(data)
                saved.append({"name": name, "bytes": len(data), "file": os.path.relpath(dest, out)})
            try:
                meta = json.loads(fields.get("frameMetadata", "null"))
            except ValueError:
                meta = fields.get("frameMetadata")
            body = {"sessionId": sid, "frameNos": fields.get("frameNos"), "frameMetadata": meta, "files": saved}
            return body, f"frames   {sid} frameNos={fields.get('frameNos')} {sum(s['bytes'] for s in saved)} bytes"

    return H


def serve(a):
    srv = ThreadingHTTPServer(("0.0.0.0", a.port), make_handler(a.out))
    print(f"capture collector on :{a.port}, writing to {a.out}/", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


# ---------------------------------------------------------------- analyse

def load(d):
    """Return (events, frame uploads) from a folder; lifecycle posts count as events."""
    events, frames = [], []
    with open(os.path.join(d, "requests.jsonl")) as f:
        for ln in f:
            r = json.loads(ln)
            b = r.get("body")
            if not isinstance(b, dict):
                continue
            if r["path"] == "/v1/sessions":
                events.append(b)
            elif r["path"] == "/v1/events/batch":
                events.extend(e for e in b.get("events", []) if isinstance(e, dict))
            elif r["path"] == "/v1/frames":
                frames.append(b)
    return events, frames


def paths(v, prefix="", depth=0):
    """Dotted key paths of nested objects (list items become `key[]`), depth-limited."""
    out = set()
    if isinstance(v, dict):
        for k, x in v.items():
            p = prefix + k
            out.add(p)
            if depth < 3:
                out |= paths(x, p + ".", depth + 1)
    elif isinstance(v, list) and prefix and depth < 3:
        for x in v:
            out |= paths(x, prefix[:-1] + "[].", depth + 1)
    return out


def shapes(events):
    s = defaultdict(set)
    for e in events:
        s[e.get("eventType", "?")] |= paths(e)
    return s


def summarise(a):
    events, frames = load(a.dir)
    print("sessions:")
    for sid in sorted({str(e.get("sessionId")) for e in events} | {f["sessionId"] for f in frames}):
        print(f"  {sid}")
    print("event types:")
    for t, n in sorted(Counter(e.get("eventType", "?") for e in events).items()):
        print(f"  {t}: {n}")
    print("shapes (JSON key paths per event type):")
    for t, keys in sorted(shapes(events).items()):
        print(f"  {t}: {', '.join(sorted(keys))}")
    files = [x for f in frames for x in f["files"]]
    sizes = [x["bytes"] for x in files]
    extra = f", {sum(sizes)} bytes total, {min(sizes)}-{max(sizes)} each" if sizes else ""
    print(f"frames: {len(files)} in {len(frames)} uploads{extra}")
    print("network_call events:")
    for e in events:
        if e.get("eventType") == "network_call":
            p = e.get("payload") or {}
            print(f"  {e.get('sessionId')} {p.get('method')} {p.get('route')} -> {p.get('statusCode')} {p.get('outcome')} {p.get('durationMs')}ms")


def compare(a):
    sa, sb = shapes(load(a.a)[0]), shapes(load(a.b)[0])
    same = True
    for t in sorted(set(sa) | set(sb)):
        if t not in sa or t not in sb:
            print(f"{t}: only in {a.a if t in sa else a.b}")
            same = False
            continue
        for label, diff in ((a.a, sa[t] - sb[t]), (a.b, sb[t] - sa[t])):
            if diff:
                print(f"{t}: only in {label}: {', '.join(sorted(diff))}")
                same = False
    if same:
        print("shapes identical")


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd")
    s = sub.add_parser("serve")
    for x in (p, s):
        x.add_argument("--port", type=int, default=3000)
        x.add_argument("--out", default="capture-out")
    sub.add_parser("summarise").add_argument("dir")
    c = sub.add_parser("compare")
    c.add_argument("a")
    c.add_argument("b")
    a = p.parse_args()
    {"summarise": summarise, "compare": compare}.get(a.cmd, serve)(a)


if __name__ == "__main__":
    main()
