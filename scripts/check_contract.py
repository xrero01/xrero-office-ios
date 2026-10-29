#!/usr/bin/env python3
"""check_contract.py <web xr-contract.json> <editors folder> - the engine-contract gate, build step (20.3 F0).

Every entry of web/xr-contract.json names an editor internal that xr-host.js, the app or the CI hooks rely on.
This step fails when a packaged editor update no longer contains one of them (renamed or removed), before any test
runs. Each entry's tokens (the path's / selector's / name's parts) must appear in the editors' .js / .html files.
The running editors are checked separately by the Autotest 'contract' hook (EditorUITests)."""
import json, os, re, sys

SKIP = {"prototype", "Asc", "AscCommon", "AscFonts", "Common", "UI", "Utils", "editor"}   # trivially present


def tokens(c):
    if c.get("static") is False:
        return []
    if "token" in c:
        return [c["token"]]
    k = c["kind"]
    if k == "global":
        return [p for p in c["path"].split(".") if p not in SKIP]
    if k == "dom":
        return re.findall(r"[#.]([\w-]+)", c["selector"])
    if k == "controller":
        return [c["name"]] + [p for p in c.get("path", "").split(".") if p and p not in SKIP]
    return [c["name"]]          # api, callback, setting, id


def main():
    manifest, root = sys.argv[1], sys.argv[2]
    checks = json.load(open(manifest, encoding="utf-8"))["checks"]
    want = {}
    for c in checks:
        for t in tokens(c):
            want.setdefault(t, []).append(c)
    left = set(want)
    files = 0
    for d, _, names in os.walk(root):
        for n in names:
            if not n.endswith((".js", ".html")):
                continue
            files += 1
            with open(os.path.join(d, n), encoding="utf-8", errors="replace") as f:
                s = f.read()
            for t in [t for t in left if t in s]:
                left.discard(t)
            if not left:
                break
    print("engine contract: %d entries, %d tokens, %d editor files searched" % (len(checks), len(want), files))
    if files == 0:
        print("error: no editor files under", root); return 1
    for t in sorted(left):
        for c in want[t]:
            print("error: engine contract: '%s' not found in the editors (%s %s - %s)"
                  % (t, c["kind"], c.get("path") or c.get("name") or c.get("selector"), c.get("why", "")))
    print("engine contract:", "PASS" if not left else "FAIL (%d missing)" % len(left))
    return 1 if left else 0


if __name__ == "__main__":
    sys.exit(main())
