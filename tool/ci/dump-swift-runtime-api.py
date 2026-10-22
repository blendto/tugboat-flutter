#!/usr/bin/env python3
"""Dump public Swift API surfaces for CI golden files."""

from __future__ import annotations

import argparse
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

PRODUCTS: dict[str, pathlib.Path] = {
    "capture-runtime": ROOT / "platforms/apple/Sources/TugboatCaptureRuntime",
    "tugboat": ROOT / "platforms/apple/Sources/Tugboat",
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


def _dump_swift_file(
    path: pathlib.Path,
    heading: str,
    *,
    track_extensions: bool,
) -> list[str]:
    lines_out: list[str] = [heading]
    in_enum = False
    in_extension = False
    extension_indent = 0
    raw_lines = path.read_text().splitlines()
    idx = 0
    while idx < len(raw_lines):
        raw = raw_lines[idx]
        stripped = raw.strip()
        indent = len(raw) - len(raw.lstrip())
        if track_extensions and stripped.startswith("extension "):
            folded, idx = _fold_signature(raw_lines, idx, stripped)
            lines_out.append(folded)
            in_extension = True
            extension_indent = indent
            idx += 1
            continue
        if track_extensions and in_extension and stripped == "}" and indent <= extension_indent:
            in_extension = False
            idx += 1
            continue
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
    return lines_out


def dump_product(src: pathlib.Path, *, recursive: bool, track_extensions: bool) -> str:
    if recursive:
        paths = sorted(src.rglob("*.swift"))
    else:
        paths = sorted(src.glob("*.swift"))
    lines_out: list[str] = []
    for path in paths:
        if recursive:
            heading = f"## {path.relative_to(src).as_posix()}"
        else:
            heading = f"## {path.name}"
        lines_out.extend(
            _dump_swift_file(path, heading, track_extensions=track_extensions)
        )
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
    recursive = args.product == "tugboat"
    track_extensions = args.product == "tugboat"
    sys.stdout.write(dump_product(src, recursive=recursive, track_extensions=track_extensions))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
