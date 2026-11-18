#!/usr/bin/env python3
"""Turns xcodebuild / swift output into GitHub annotations and a compact error file.

Usage: report-errors.py <log> [out-file]
"""
import re
import sys

log_path = sys.argv[1]
out_path = sys.argv[2] if len(sys.argv) > 2 else "build-errors.txt"

try:
    with open(log_path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
except FileNotFoundError:
    print(f"::warning::{log_path} not found")
    sys.exit(0)

pattern = re.compile(r"^(/[^:]+):(\d+):(\d+): (error|fatal error): (.*)$")
seen = set()
errors = []
for i, line in enumerate(lines):
    m = pattern.match(line)
    if m:
        path, ln, col, _, msg = m.groups()
        key = (path, ln, msg)
        if key in seen:
            continue
        seen.add(key)
        rel = path
        for marker in ("/SleepFlow/", "/sleepflow/", "/work/"):
            if marker in path:
                rel = path.split(marker, 1)[-1]
                break
        errors.append((rel, ln, col, msg, lines[i + 1:i + 4]))
    elif ("error:" in line and "warning" not in line) or "** BUILD FAILED **" in line or "** TEST FAILED **" in line:
        key = ("", "", line.strip())
        if key not in seen:
            seen.add(key)
            errors.append(("", "", "", line.strip(), []))

with open(out_path, "w", encoding="utf-8") as f:
    f.write(f"{len(errors)} errors\n\n")
    for rel, ln, col, msg, ctx in errors:
        f.write(f"{rel}:{ln}:{col}: {msg}\n")
        for c in ctx:
            f.write(f"    {c}\n")
        f.write("\n")
    f.write("\n---- last 150 lines ----\n")
    f.write("\n".join(lines[-150:]))

for rel, ln, col, msg, _ in errors[:40]:
    msg = msg.replace("%", "%25").replace("\r", "").replace("\n", " ")
    if rel:
        print(f"::error file={rel},line={ln},col={col}::{msg}")
    else:
        print(f"::error::{msg[:300]}")
print(f"{len(errors)} errors found")
