#!/usr/bin/env python3
"""Dump the public Kotlin API of capture-runtime (non-internal sources)."""

from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "platforms/android/capture-runtime/src/main/java/com/tugboat/capture"


def _is_enum_entry(line: str, in_enum: bool) -> bool:
    if not in_enum:
        return False
    stripped = line.strip().rstrip(",")
    if not stripped or stripped.startswith("//"):
        return False
    indent = len(line) - len(line.lstrip())
    if indent != 4:
        return False
    if any(
        stripped.startswith(prefix)
        for prefix in ("fun ", "val ", "const ", "private ", "internal ")
    ):
        return False
    token = stripped.split("=")[0].strip()
    return token.isidentifier() and token[0].isupper()


def dump() -> str:
    lines: list[str] = []
    for path in sorted(SRC.glob("*.kt")):
        in_enum = False
        lines.append(f"## {path.name}")
        for raw in path.read_text().splitlines():
            stripped = raw.strip()
            if stripped.startswith("enum class "):
                in_enum = True
                lines.append(stripped.split("{")[0].strip())
                continue
            if in_enum and stripped.startswith("}"):
                in_enum = False
                continue
            if _is_enum_entry(raw, in_enum):
                lines.append("  " + stripped.rstrip(","))
                continue
            if stripped.startswith("private ") or stripped.startswith("internal "):
                continue
            indent = len(raw) - len(raw.lstrip())
            if indent == 0 and stripped.startswith(
                ("class ", "data class ", "object ")
            ):
                lines.append(stripped.split("{")[0].strip())
            elif indent == 4 and stripped.startswith(
                ("fun ", "val ", "companion object")
            ):
                lines.append("  " + stripped.split("{")[0].strip())
            elif indent == 8 and stripped.startswith("const val "):
                lines.append("  " + stripped.split("{")[0].strip())
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    sys.stdout.write(dump())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
