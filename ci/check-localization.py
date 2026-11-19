#!/usr/bin/env python3
"""Checks the Danish strings table against the keys the Swift compiler extracted.

Usage: check-localization.py <derived-data-dir> <da Localizable.strings> <report-file>

The compiler writes every localisable literal (Text("…"), LocalizedStringKey, String(localized:)
…) with its exact format specifiers into .stringsdata files when SWIFT_EMIT_LOC_STRINGS is on.
Missing Danish keys are reported as warnings; the app then shows the English text.
"""
import glob
import json
import os
import re
import sys

derived, strings_path, report_path = sys.argv[1], sys.argv[2], sys.argv[3]

extracted = {}
for path in glob.glob(os.path.join(derived, "**", "*.stringsdata"), recursive=True):
    if "SleepFlowTests" in path or "SleepFlowUITests" in path:
        continue
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        continue
    source = os.path.basename(data.get("source", path))
    for table, entries in data.get("tables", {}).items():
        if table != "Localizable":
            continue
        for entry in entries:
            key = entry.get("key") if isinstance(entry, dict) else None
            if key:
                extracted.setdefault(key, source)


def unescape(text):
    out, i = [], 0
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, nxt))
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


with open(strings_path, encoding="utf-8") as handle:
    content = handle.read()
pairs = re.findall(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', content)
translated = {unescape(key): unescape(value) for key, value in pairs}

specifier = re.compile(r"%(?:\d+\$)?(lld|ld|d|@|lf|f)")
missing = sorted(key for key in extracted if key not in translated)
unused = sorted(key for key in translated if key not in extracted)
mismatched = sorted(
    key for key, value in translated.items()
    if sorted(specifier.findall(key)) != sorted(specifier.findall(value))
)

lines = [
    f"Extracted keys: {len(extracted)}",
    f"Danish entries: {len(translated)}",
    f"Missing in Danish: {len(missing)}",
    f"Not used by the code: {len(unused)}",
    f"Format specifier mismatches: {len(mismatched)}",
    "",
    "== Missing ==",
]
lines += [f"{json.dumps(key, ensure_ascii=False)}  ({extracted[key]})" for key in missing]
lines += ["", "== Unused =="] + [json.dumps(key, ensure_ascii=False) for key in unused]
lines += ["", "== Specifier mismatches =="] + [json.dumps(key, ensure_ascii=False) for key in mismatched]
with open(report_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")

print("\n".join(lines[:5]))
if not extracted:
    print("::warning::No .stringsdata files found – is SWIFT_EMIT_LOC_STRINGS enabled?")
for key in missing[:40]:
    print(f"::warning title=Missing Danish text::{key}")
for key in mismatched:
    print(f"::error title=Format specifiers differ::{key}")
sys.exit(1 if mismatched else 0)
