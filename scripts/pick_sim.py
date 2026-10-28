#!/usr/bin/env python3
"""pick_sim.py <simctl devices json> <name prefix> [<fallback prefix> ...] - UDID of an available simulator on the
newest iOS runtime whose name starts with the first prefix that matches anything (the device's name goes to stderr,
so the CI log shows which model ran). Exit 1 when none matches."""
import json, re, sys
devices = json.load(open(sys.argv[1]))["devices"]
def ver(rt):
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
for prefix in sys.argv[2:]:
    for rt in sorted(devices, key=ver, reverse=True):
        if "iOS" not in rt:
            continue
        for d in devices[rt]:
            if d.get("isAvailable", True) and d["name"].startswith(prefix) and " SE" not in d["name"]:
                print("simulator: %s (%s)" % (d["name"], rt.rsplit(".", 1)[-1]), file=sys.stderr)
                print(d["udid"]); sys.exit(0)
sys.exit(1)
