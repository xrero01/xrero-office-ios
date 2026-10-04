#!/usr/bin/env python3
"""pick_sim.py <simctl devices json> <name prefix> - UDID of an available simulator on the newest iOS runtime."""
import json, re, sys
devices = json.load(open(sys.argv[1]))["devices"]
def ver(rt):
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
for rt in sorted(devices, key=ver, reverse=True):
    if "iOS" not in rt:
        continue
    for d in devices[rt]:
        if d.get("isAvailable", True) and d["name"].startswith(sys.argv[2]) and " SE" not in d["name"]:
            print(d["udid"]); sys.exit(0)
sys.exit(1)
