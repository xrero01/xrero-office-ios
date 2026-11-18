#!/usr/bin/env python3
"""patch_field_ap_ios.py <editors dir> - iOS only: every glyph of a PDF form field in an EMBEDDED font is saved as its
outline.

The Windows payload's XR-FIELD-AP (word/sdk-all.js, from 21.0) draws a field glyph as its outline only when the text
path cannot give it (Arabic and other complex scripts, ligatures); simple glyphs stay text in the embedded font. On
Windows / macOS the converter has the PDF's own embedded fonts, so that text is drawn. On iOS the PDF is saved by x2t
WebAssembly (xr-host.js savePdf), which only gets the app's own font files - a glyph of the PDF's embedded font written
as text came out as an empty path, so Latin letters and digits typed into such a field (an ID, a date, an e-mail) were
missing from the saved page in every other app. Here the outline is used for every glyph of an embedded font (the field
value itself is still saved as text). Fields in a standard font (Helvetica...) keep the text path: x2t draws them with
the app's fonts (xr-host.js fontUrls). Idempotent; fails loudly when the anchor is not found exactly once.
"""
import os, sys

ANCHOR = "if (!need) need = font.GetGIDByUnicode(cps[0]) !== gid;"
PATCH = ("if (!need) need = true; /*XR-IOS-FIELD-AP-ALL: iOS saves every glyph of an embedded font as its outline"
         " (scripts/patch_field_ap_ios.py)*/")


def main(editors):
    p = os.path.join(editors, "sdkjs", "word", "sdk-all.js")
    s = open(p, encoding="utf-8", errors="surrogateescape", newline="").read()
    if "XR-IOS-FIELD-AP-ALL" in s:
        print("patch_field_ap_ios: already applied")
        return
    n = s.count(ANCHOR)
    if n != 1 or "/*XR-FIELD-AP-START*/" not in s:
        raise SystemExit("patch_field_ap_ios: XR-FIELD-AP anchor found %d times in %s (expected 1)" % (n, p))
    open(p, "w", encoding="utf-8", errors="surrogateescape", newline="").write(s.replace(ANCHOR, PATCH))
    print("patch_field_ap_ios: embedded-font field glyphs saved as outlines (word/sdk-all.js)")


if __name__ == "__main__":
    main(sys.argv[1])
