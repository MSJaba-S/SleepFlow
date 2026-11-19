#!/usr/bin/env python3
"""Prints the UDID of the newest available iPhone simulator (standard size preferred)."""
import json
import re
import subprocess
import sys

listing = subprocess.run(
    ["xcrun", "simctl", "list", "devices", "available", "-j"],
    capture_output=True, text=True, check=True,
).stdout
devices = json.loads(listing).get("devices", {})

best = None
for runtime, entries in devices.items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for device in entries:
        name = device.get("name", "")
        if not device.get("isAvailable", True) or not name.startswith("iPhone"):
            continue
        plain = not any(word in name for word in ("Pro", "Max", "Plus", "SE", "Air", "mini")) and not name.endswith("e")
        score = (version, plain, name)
        if best is None or score > best[0]:
            best = (score, device["udid"], name, runtime)

if best is None:
    sys.exit("No available iPhone simulator found")
print(f"Simulator: {best[2]} ({best[3]})", file=sys.stderr)
print(best[1])
