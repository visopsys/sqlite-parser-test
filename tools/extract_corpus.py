#!/usr/bin/env python3
"""Extract SQL scripts from SQLite's Tcl test suite into a corpus file.

Usage: tools/extract_corpus.py SQLITE_SOURCE_DIR OUTPUT_FILE

SQLITE_SOURCE_DIR is a checkout of https://github.com/sqlite/sqlite at the tag
named in docs/research.md (version-3.45.1). Every brace-quoted SQL argument of
execsql, catchsql, db eval, do_execsql_test, do_catchsql_test and do_eqp_test
becomes one case. Cases are deduplicated and written in a stable order.

Output format: each case starts with a header line `#### <file>:<line>` and
runs until the next header line. The SQL text is stored byte for byte, with one
trailing newline added. No case may itself contain a line starting with "####".
"""
import pathlib
import re
import sys

COMMANDS = re.compile(
    rb"(?:\bexecsql|\bcatchsql|\bdb2? eval"
    rb"|\bdo_execsql_test\s+\S+|\bdo_catchsql_test\s+\S+|\bdo_eqp_test\s+\S+)"
    rb"\s+\{"
)
MAX_CASE_BYTES = 16 * 1024


def braced_body(data: bytes, start: int) -> bytes | None:
    """Return the text between the '{' at data[start-1] and its matching '}'."""
    depth = 1
    i = start
    while i < len(data):
        c = data[i]
        if c == 0x5C:  # backslash escapes the next byte in Tcl braces
            i += 2
            continue
        if c == 0x7B:
            depth += 1
        elif c == 0x7D:
            depth -= 1
            if depth == 0:
                return data[start:i]
        i += 1
    return None


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src = pathlib.Path(sys.argv[1]) / "test"
    out = pathlib.Path(sys.argv[2])
    seen: set[bytes] = set()
    cases: list[tuple[str, bytes]] = []
    for path in sorted(src.glob("*.test")):
        data = path.read_bytes()
        for m in COMMANDS.finditer(data):
            body = braced_body(data, m.end())
            if body is None:
                continue
            sql = body.strip()
            if not sql or len(sql) > MAX_CASE_BYTES or sql in seen:
                continue
            if any(line.startswith(b"####") for line in sql.split(b"\n")):
                continue
            seen.add(sql)
            line = data.count(b"\n", 0, m.start()) + 1
            cases.append((f"{path.name}:{line}", sql))
    with out.open("wb") as f:
        for case_id, sql in cases:
            f.write(b"#### " + case_id.encode() + b"\n" + sql + b"\n")
    print(f"{len(cases)} cases -> {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
