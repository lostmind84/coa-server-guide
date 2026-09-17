#!/usr/bin/env python3
"""Print the CoaProbe answer for a request id, read from the addon's SavedVariables file.

Usage: coa-probe-read.py SAVEDVARIABLES_FILE REQ
Exit 0 with the answer as JSON, 1 when the file or the answer is not there yet, 2 on wrong usage.
"""
import json
import re
import sys
from pathlib import Path

LUA_STRING = re.compile(r'"((?:[^"\\]|\\.)*)"', re.S)
LUA_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "a": "\a", "b": "\b", "f": "\f", "v": "\v", "\n": "\n"}


def lua_unescape(text):
    """Decode a Lua string body. Works on latin-1 text so that decimal escapes map to single bytes."""
    out = []
    i = 0
    while i < len(text):
        char = text[i]
        if char != "\\" or i + 1 == len(text):
            out.append(char)
            i += 1
            continue
        nxt = text[i + 1]
        digits = re.match(r"\d{1,3}", text[i + 1:])
        if digits:
            out.append(chr(int(digits.group(0))))
            i += 1 + len(digits.group(0))
        else:
            out.append(LUA_ESCAPES.get(nxt, nxt))
            i += 2
    return "".join(out)


def find_answer(raw_bytes, req):
    text = raw_bytes.decode("latin-1")
    for match in reversed(list(LUA_STRING.finditer(text))):
        body = lua_unescape(match.group(1)).encode("latin-1")
        try:
            answer = json.loads(body.decode("utf-8"))
        except ValueError:
            continue
        if isinstance(answer, dict) and answer.get("req") == req:
            return answer
    return None


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    path = Path(argv[1])
    if not path.is_file():
        return 1
    answer = find_answer(path.read_bytes(), argv[2])
    if answer is None:
        return 1
    print(json.dumps(answer, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
