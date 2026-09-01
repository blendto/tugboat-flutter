#!/usr/bin/env python3
"""Dump the public Swift API of TugboatCaptureRuntime (non-Internal sources)."""

from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "platforms/apple/Sources/TugboatCaptureRuntime"

PUBLIC_TYPES = (
    "public struct ",
    "public enum ",
    "public class ",
    "public final class ",
)
PUBLIC_MEMBERS = (
    "public func ",
    "public var ",
    "public static let ",
    "public static var ",
    "public init(",
)


def _strip_body(line: str) -> str:
    return line.split("{")[0].strip().rstrip(",")


def _fold_signature(lines: list[str], start: int, stripped: str) -> tuple[str, int]:
    buf = stripped
    idx = start
    while buf.count("(") > buf.count(")") and idx + 1 < len(lines):
        idx += 1
        buf = f"{buf} {lines[idx].strip()}"
    return " ".join(_strip_body(buf).split()), idx


def dump() -> str:
    lines_out: list[str] = []
    for path in sorted(SRC.glob("*.swift")):
        in_enum = False
        lines_out.append(f"## {path.name}")
        raw_lines = path.read_text().splitlines()
        idx = 0
        while idx < len(raw_lines):
            raw = raw_lines[idx]
            stripped = raw.strip()
            indent = len(raw) - len(raw.lstrip())
            if any(stripped.startswith(prefix) for prefix in PUBLIC_TYPES):
                in_enum = stripped.startswith("public enum ")
                folded, idx = _fold_signature(raw_lines, idx, stripped)
                lines_out.append(folded)
                idx += 1
                continue
            if in_enum and indent == 0 and stripped.startswith("}"):
                in_enum = False
                idx += 1
                continue
            if in_enum and stripped.startswith("case "):
                lines_out.append("  " + stripped.rstrip(","))
                idx += 1
                continue
            if indent == 2 and any(stripped.startswith(prefix) for prefix in PUBLIC_MEMBERS):
                folded, idx = _fold_signature(raw_lines, idx, stripped)
                lines_out.append("  " + folded)
            idx += 1
        lines_out.append("")
    return "\n".join(lines_out).rstrip() + "\n"


def main() -> int:
    sys.stdout.write(dump())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
