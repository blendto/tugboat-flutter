#!/usr/bin/env python3
"""Dump public Swift API surfaces for CI golden files."""

from __future__ import annotations

import argparse
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

PRODUCTS: dict[str, pathlib.Path] = {
    "capture-runtime": ROOT / "platforms/apple/Sources/TugboatCaptureRuntime",
    "tugboat": ROOT / "platforms/apple/Sources/Tugboat/Public",
}

PUBLIC_TYPES = (
    "public struct ",
    "public enum ",
    "public class ",
    "public final class ",
    "public typealias ",
)
PUBLIC_MEMBERS = (
    "public func ",
    "public static func ",
    "public var ",
    "public let ",
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


def dump_source_dir(src: pathlib.Path) -> str:
    lines_out: list[str] = []
    for path in sorted(src.glob("*.swift")):
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
                prefix = "  " if indent >= 2 else ""
                lines_out.append(prefix + folded)
                idx += 1
                continue
            if in_enum and stripped.startswith("case "):
                case_indent = "  " if indent <= 2 else "    "
                lines_out.append(case_indent + stripped.rstrip(","))
                idx += 1
                continue
            if in_enum and stripped == "}":
                in_enum = False
                idx += 1
                continue
            if indent >= 2 and any(stripped.startswith(prefix) for prefix in PUBLIC_MEMBERS):
                folded, idx = _fold_signature(raw_lines, idx, stripped)
                member_indent = "  " if indent == 2 else "    "
                lines_out.append(member_indent + folded)
            idx += 1
        lines_out.append("")
    return "\n".join(lines_out).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--product",
        choices=sorted(PRODUCTS),
        default="capture-runtime",
        help="Swift product to dump (default: capture-runtime)",
    )
    args = parser.parse_args()
    src = PRODUCTS[args.product]
    if not src.is_dir():
        print(f"::error::{src} is missing", file=sys.stderr)
        return 1
    sys.stdout.write(dump_source_dir(src))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
