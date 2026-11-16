"""Minimal HuJSON reader: // comments and trailing commas."""

from __future__ import annotations

import json
import re


def strip(text: str) -> str:
    out: list[str] = []
    i = 0
    n = len(text)
    in_str = False
    escape = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if escape:
                escape = False
            elif c == "\\":
                escape = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            i += 2
            while i < n and text[i] != "\n":
                i += 1
            continue
        out.append(c)
        i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def loads(text: str):
    return json.loads(strip(text))
