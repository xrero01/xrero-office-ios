#!/usr/bin/env python3
"""check_saved.py <out/saved> - verifies what the UI tests saved on each simulator (iPhone, iPad):
xr-test.docx must contain the English (and, if the keyboard could type it, the Arabic) test text;
ar_letter.docx must still hold the original Arabic letter after open + save. Prints each editor log."""
import os, re, sys, zipfile

root = sys.argv[1]
ok = True
def text(p):
    z = zipfile.ZipFile(p)
    return re.sub(r"\s+", " ", "".join(re.findall(r"<w:t[^>]*>([^<]*)<", z.read("word/document.xml").decode("utf-8"))))
for dev in sorted(os.listdir(root)) if os.path.isdir(root) else []:
    d = os.path.join(root, dev)
    print("==", dev, sorted(os.listdir(d)))
    for log in sorted(f for f in os.listdir(d) if f.startswith("xr-log")):
        print("--", log)
        print("".join(open(os.path.join(d, log), encoding="utf-8", errors="replace").readlines()[-25:]))
    t = os.path.join(d, "xr-test.docx")
    if os.path.exists(t):
        s = text(t)
        en = "Typed on iPhone" in s and "English OK." in s      # iOS Smart Punctuation turns "-" into an en dash
        ar = "كتابة عربية" in s
        print("xr-test.docx: English typed=%s  Arabic typed=%s  text=%r" % (en, ar, s[:200]))
        ok &= en
    else:
        print("xr-test.docx: MISSING"); ok = False
    a = os.path.join(d, "ar_letter.docx")
    if os.path.exists(a):
        s = text(a)
        kept = "السادة أولياء الأمور الكرام" in s and "إدارة المدرسة" in s
        print("  typed word added:", "تم" in s)
        print("ar_letter.docx saved: original Arabic kept=%s (%d chars)" % (kept, len(s)))
        ok &= kept
    else:
        print("ar_letter.docx: MISSING"); ok = False
    pdf = os.path.join(d, "ar_letter.pdf")
    if os.path.exists(pdf):
        try:
            from pypdf import PdfReader
            r = PdfReader(pdf)
            rot = r.pages[0].get("/Rotate", 0)
            annots = sum(len(p.get("/Annots") or []) for p in r.pages)
            text = "".join(p.extract_text() or "" for p in r.pages)
            arabic = sum(1 for c in text if "؀" <= c <= "ۿ")      # the letter's Arabic text survived
            good = len(r.pages) == 2 and rot == 90 and annots >= 1 and arabic >= 100
            print("ar_letter.pdf saved: pages=%d rotate=%s annotations=%d arabic letters=%d -> %s"
                  % (len(r.pages), rot, annots, arabic, "OK" if good else "WRONG"))
            ok &= good
        except Exception as e:
            print("ar_letter.pdf: cannot read the saved PDF:", e); ok = False
    else:
        print("ar_letter.pdf: MISSING (PDF edit + save)"); ok = False
if not (os.path.isdir(root) and os.listdir(root)):
    print("no saved files from any simulator"); ok = False
print("RESULT", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
