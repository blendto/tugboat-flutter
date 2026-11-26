#!/usr/bin/env python3
"""Renders the Flutter SDK device report (checklist + capture benchmarks).

Reads the directories run-device-suite.sh wrote for each platform and prints
one Markdown document. The first line is a hidden marker the workflow uses to
find and update its PR comment.

Usage:
  render-report.py --android DIR --ios DIR --sdk-version-file PATH \
      --sha SHA --run-url URL [--expected-rows N] > report.md
"""

import argparse
import json
import re
from pathlib import Path

MARKER = "<!-- tugboat-device-report -->"
PLATFORMS = (("android", "Android"), ("ios", "iOS"))
BACKENDS = ("flutterRepaintBoundary", "nativeCpuExperimental")


def load(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def ms(micros):
    return f"{micros / 1000:.1f}"


def triple(stats, fmt=ms):
    if not stats or not stats.get("n"):
        return "–"
    return " / ".join(fmt(stats[k]) for k in ("p50", "p95", "max"))


def pair(stats, keys=("p50", "p95"), fmt=ms):
    if not stats or not stats.get("n"):
        return "–"
    return " / ".join(fmt(stats[k]) for k in keys)


def kb(value):
    return f"{value / 1024:.0f}"


def mb(value):
    return f"{value / (1024 * 1024):.0f}"


def counts(mapping):
    if not mapping:
        return "none"
    return ", ".join(f"`{k}` ×{v}" for k, v in sorted(mapping.items()))


def sdk_version(path):
    text = Path(path).read_text()
    match = re.search(r"tugboatSdkVersion\s*=\s*'([^']+)'", text)
    return match.group(1) if match else "unknown"


def describe_device(data):
    device = data["device"] or {}
    parts = [p for p in (device.get("model"), device.get("kind")) if p]
    text = " ".join(parts) or "unknown device"
    extra = [device.get("os"), device.get("abi")]
    if device.get("gpu"):
        extra.append(f"GPU `{device['gpu']}`")
    xcode = (data.get("xcode") or {}).get("xcode")
    if xcode:
        extra.append(xcode)
    return text + ", " + ", ".join(e for e in extra if e)


def load_platform(root):
    if not root or not Path(root).is_dir():
        return None
    base = Path(root)
    return {
        "device": load(base / "device.json"),
        "xcode": load(base / "xcode.json"),
        "flutter": load(base / "flutter-version.json"),
        "checklist": load(base / "device_checklist.json"),
        "profiles": {
            backend: (load(base / f"profile_{backend}.json") or {}).get("summary")
            for backend in BACKENDS
        },
        "notes": (load(base / "notes.json") or {}).get("notes", []),
    }


def checklist_section(platforms, expected_rows):
    order, titles = [], {}
    results = {}
    for key, _ in PLATFORMS:
        data = platforms.get(key)
        rows = ((data or {}).get("checklist") or {}).get("checklist") or []
        results[key] = {row["id"]: row for row in rows}
        for row in rows:
            if row["id"] not in titles:
                order.append(row["id"])
                titles[row["id"]] = row["title"]

    lines = ["### Feature checklist", ""]
    lines.append("| Feature | " + " | ".join(n for _, n in PLATFORMS) + " |")
    lines.append("|---|" + "---|" * len(PLATFORMS))
    failures = []
    for row_id in order:
        cells = []
        for key, name in PLATFORMS:
            row = results[key].get(row_id)
            if row is None:
                cells.append("– not run")
            elif row["pass"]:
                cells.append("✅")
            else:
                cells.append("❌")
                failures.append(f"- **{name} · {titles[row_id]}:** {row.get('reason', 'no reason recorded')}")
        lines.append(f"| {titles[row_id]} | " + " | ".join(cells) + " |")
    for key, name in PLATFORMS:
        got = len(results[key])
        if got < expected_rows:
            failures.append(f"- **{name}:** only {got} of {expected_rows} rows were recorded (see the run logs).")
    if failures:
        lines += ["", "Why each ❌:", ""] + failures
    return lines


def backend_column(summary, backend):
    """Returns (cells, note) for one backend, or n/a with the reason."""
    if not summary:
        return None, "no profile was recorded"
    resolved = summary.get("resolvedBackends") or {}
    by_backend = (summary.get("byBackend") or {}).get(backend) or {}
    own = resolved.get(backend, 0)
    total = summary.get("frames", 0)
    if own == 0:
        reason = counts(summary.get("fallbacks")) if summary.get("fallbacks") else "no frames"
        return None, f"every frame fell back to the Flutter path ({reason})"
    outcomes = summary.get("diagnosticOutcomes") or {}
    eligible = sum(outcomes.values())
    captured = outcomes.get("fresh_accepted", own)
    cells = {
        "mode": summary.get("mode", "?"),
        "frames": f"{captured} / {eligible}" if eligible else f"{own}",
        "capture": triple(by_backend.get("captureMicros") or summary.get("captureMicros")),
        "jank": f"{summary.get('uiJankFrames', 0)} of {summary.get('uiFrames', 0)}",
        "build": pair(summary.get("uiBuildMicros")),
        "raster": pair(summary.get("uiRasterMicros")),
        "rss": f"{mb((summary.get('rssBytes') or {}).get('max', 0))} (process max {mb(summary.get('processMaxRssBytes', 0))})",
        "bytes": pair(by_backend.get("jpegBytes") or summary.get("jpegBytes"), keys=("p50", "max"), fmt=kb),
        "fallbacks": counts(summary.get("fallbacks")),
        "skips": counts({k: v for k, v in outcomes.items() if k != "fresh_accepted"}),
        "errors": framework_errors(summary),
    }
    if own < total:
        cells["frames"] += f" ({own} native, {total - own} fell back)"
    stages = summary.get("nativeStageMicros") or {}
    if backend == "nativeCpuExperimental" and stages:
        cells["stages"] = ", ".join(
            f"{k.replace('Micros', '')} {ms(v['p50'])}" for k, v in sorted(stages.items()) if v.get("n")
        )
    return cells, None


def framework_errors(summary):
    errors = summary.get("frameworkErrors") or {}
    text = str(errors.get("count", 0))
    if errors.get("first"):
        text += f" (first: {errors['first'][:120]})"
    if summary.get("scriptError"):
        text += f"; script stopped early: {summary['scriptError'][:160]}"
    return text


METRICS = (
    ("mode", "Build mode"),
    ("frames", "Frames captured / eligible capture requests"),
    ("capture", "Capture cost per frame p50 / p95 / max (ms)"),
    ("stages", "Native stage p50 (ms)"),
    ("jank", "UI jank frames (build or raster > 16.7 ms)"),
    ("build", "UI build p50 / p95 (ms)"),
    ("raster", "UI raster p50 / p95 (ms)"),
    ("rss", "RSS peak, 100 ms samples (MB)"),
    ("bytes", "Encoded JPEG size p50 / max (KB)"),
    ("skips", "Capture requests not freshly captured"),
    ("fallbacks", "Backend fallbacks"),
    ("errors", "Framework errors during the script"),
)


def benchmark_section(platforms):
    lines = ["### Capture benchmarks", ""]
    lines.append(
        "Fixed script over the example app (browse feed flings, expand/collapse, catalog, "
        "scroll playground, privacy fixture), one app process per backend. Capture cost is "
        "frame wait + readback + mask + encode for each fresh frame; on the native path the "
        "encode part is the platform-channel round trip."
    )
    for key, name in PLATFORMS:
        data = platforms.get(key)
        lines += ["", f"#### {name}", ""]
        if not data:
            lines.append("No results: the job produced no report artifact.")
            continue
        columns, notes = {}, []
        for backend in BACKENDS:
            cells, note = backend_column(data["profiles"].get(backend), backend)
            columns[backend] = cells
            if note:
                notes.append(f"- `{backend}`: n/a, {note}.")
        lines.append("| Metric | " + " | ".join(f"`{b}`" for b in BACKENDS) + " |")
        lines.append("|---|" + "---|" * len(BACKENDS))
        for metric, label in METRICS:
            values = [(columns[b] or {}).get(metric) if columns[b] else "n/a" for b in BACKENDS]
            if all(v in (None, "n/a") for v in values):
                continue
            lines.append(f"| {label} | " + " | ".join(v if v is not None else "–" for v in values) + " |")
        lines += [""] + notes if notes else []
        lines += [f"- {n}" for n in data.get("notes") or [] if n.strip()]
    return lines


def header(platforms, args):
    flutter = next(
        (p["flutter"] for p in platforms.values() if p and p.get("flutter")), None
    ) or {}
    flutter_text = flutter.get("frameworkVersion", "unknown")
    if flutter.get("dartSdkVersion"):
        flutter_text += f" (Dart {flutter['dartSdkVersion'].split(' ')[0]})"
    lines = [
        MARKER,
        "## Device report: Flutter SDK capture",
        "",
        f"Commit `{args.sha[:12]}` · `tugboat` {sdk_version(args.sdk_version_file)} · "
        f"Flutter {flutter_text} · [workflow run]({args.run_url})",
        "",
        "| | " + " | ".join(n for _, n in PLATFORMS) + " |",
        "|---|" + "---|" * len(PLATFORMS),
    ]
    devices = [describe_device(platforms[k]) if platforms.get(k) else "no results" for k, _ in PLATFORMS]
    lines.append("| Device / runtime | " + " | ".join(devices) + " |")
    modes = []
    for key, _ in PLATFORMS:
        data = platforms.get(key) or {}
        found = sorted({(s or {}).get("mode") for s in (data.get("profiles") or {}).values() if s})
        modes.append(", ".join(m for m in found if m) or "–")
    lines.append("| Benchmark build mode | " + " | ".join(modes) + " |")
    lines += [
        "",
        "> [!NOTE]",
        "> These numbers come from a CI emulator and simulator. Treat them as regression "
        "signals between runs of this workflow, not as device performance. The Android "
        "emulator renders on the CPU (SwiftShader) on a shared runner; the iOS simulator "
        "can only run debug builds, and debug timings include JIT and assertion overhead.",
        "",
    ]
    return lines


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--android")
    parser.add_argument("--ios")
    parser.add_argument("--sdk-version-file", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--run-url", required=True)
    parser.add_argument("--expected-rows", type=int, default=12)
    args = parser.parse_args()
    platforms = {"android": load_platform(args.android), "ios": load_platform(args.ios)}
    lines = header(platforms, args)
    lines += checklist_section(platforms, args.expected_rows)
    lines += [""] + benchmark_section(platforms)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
