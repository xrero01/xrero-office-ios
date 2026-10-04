#!/usr/bin/env python3
"""patch_amd_deps.py <web-apps dir> - fixes a load-order race in the (unbundled) Xrero web-apps.

80 RequireJS modules are declared with no dependencies - define([], function(){ ... Common.UI.BaseView.extend(...) })
- yet extend Common.UI.BaseView / Window / DataViewItem as soon as they run. When such a file happens to load
before BaseView.js, the editor dies at startup ("Common.UI.BaseView is undefined", seen on Slides in Chrome and
WebKit). Declaring the real dependency makes RequireJS load the base class first. Idempotent."""
import os, re, sys

BASES = {"BaseView": "common/main/lib/component/BaseView",
         "Window": "common/main/lib/component/Window",
         "DataViewItem": "common/main/lib/component/DataView"}
EMPTY = re.compile(r"define\(\s*\[\s*\]\s*,")

def patch_source(s):
    """returns patched text or None when the module needs nothing"""
    m = EMPTY.search(s)
    if not m:
        return None
    uses = [b for b in BASES if re.search(r"Common\.UI\.%s\.extend\(" % b, s)]
    if not uses:
        return None
    deps = ", ".join("'%s'" % BASES[b] for b in uses)
    return s[:m.start()] + "define([%s]," % deps + s[m.end():]

def main(root):
    n = 0
    for d, _, files in os.walk(root):
        if "vendor" in d.replace("\\", "/").split("/"):
            continue
        for f in files:
            if not f.endswith(".js"):
                continue
            p = os.path.join(d, f)
            s = open(p, encoding="utf-8", errors="surrogateescape").read()
            out = patch_source(s)
            if out is not None and out != s:
                open(p, "w", encoding="utf-8", errors="surrogateescape", newline="").write(out)
                n += 1
    print("patch_amd_deps: declared base-class dependencies in", n, "modules")

if __name__ == "__main__":
    main(sys.argv[1])
