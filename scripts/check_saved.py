#!/usr/bin/env python3
"""check_saved.py <out/saved> - verifies what the UI tests saved on each simulator (iPhone, iPad):
xr-test.docx must contain the English (and, if the keyboard could type it, the Arabic) test text;
ar_letter.docx must still hold the original Arabic letter after open + save; File > Save As must export ar_letter.odt
(a real ODT with the letter) without rewriting the original, and the File menu must show no no-op entry.
Prints each editor log."""
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
    # File > Save As (testSaveAsCopy): the copy is a real ODT holding the letter, the original was not rewritten,
    # and the File menu shows no entry that does nothing on iOS
    odt = os.path.join(d, "ar_letter.odt")
    if os.path.exists(odt):
        try:
            z = zipfile.ZipFile(odt)
            mime = z.read("mimetype").decode("ascii", "replace")
            body = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", z.read("content.xml").decode("utf-8")))
            good = mime == "application/vnd.oasis.opendocument.text" and "السادة أولياء الأمور الكرام" in body
            print("ar_letter.odt (Save As copy): mimetype=%s letter kept=%s -> %s" % (mime, "السادة أولياء الأمور الكرام" in body, "OK" if good else "WRONG"))
            ok &= good
        except Exception as e:
            print("ar_letter.odt: cannot read the exported copy:", e); ok = False
    else:
        print("ar_letter.odt: MISSING (File > Save As copy)"); ok = False
    lg = os.path.join(d, "xr-log-ar_letter.docx.txt")
    log = open(lg, encoding="utf-8", errors="replace").read() if os.path.exists(lg) else ""
    menu = re.findall(r"file menu visible: ([^\n]*)", log)
    if menu:
        shown = menu[-1].split()
        dead = [b for b in ("fm-btn-local-open", "fm-btn-print", "fm-btn-print-with-preview", "fm-btn-export-pdf",
                            "fm-btn-recent", "fm-btn-suggest") if b in shown]
        good = not dead and ("fm-btn-download" in shown or "fm-btn-save-desktop" in shown) and "fm-btn-save" in shown
        print("File menu entries:", " ".join(shown), "-> %s" % ("OK" if good else "WRONG (no-op entries: %s)" % dead))
        ok &= good
    else:
        print("File menu entries: NOT LOGGED"); ok = False
    tiles = re.findall(r"download as formats: ([^\n]*)", log)
    if tiles:
        shown = tiles[-1].split()
        # Word: DOCX, DOTX, ODT, OTT, RTF (Asc.c_oAscFileType) - the formats the on-device converter writes correctly
        good = bool(shown) and "67" in shown and set(shown) <= {"65", "76", "67", "79", "68"}
        print("Download As formats:", " ".join(shown), "-> %s" % ("OK" if good else "WRONG"))
        ok &= good
    else:
        print("Download As formats: NOT LOGGED"); ok = False
    rtf = os.path.join(d, "ar_letter.rtf")
    if os.path.exists(rtf):
        raw = open(rtf, "rb").read()
        good = raw.startswith(rb"{\rtf") and rb"\u1575" in raw         # an RTF holding Arabic (alef = U+0627 as \u1575)
        print("ar_letter.rtf (Save As list copy): %d bytes -> %s" % (len(raw), "OK" if good else "WRONG"))
        ok &= good
    else:
        print("ar_letter.rtf: MISSING (Save As format list)"); ok = False
    if "exported copy" in log:
        rewrote = re.search(r"^saved ar_letter\.docx", log, re.M) is not None
        print("Save As left the original alone: %s" % (not rewrote))
        ok &= not rewrote
    pdf = os.path.join(d, "ar_letter.pdf")
    if os.path.exists(pdf):
        try:
            from pypdf import PdfReader
            r = PdfReader(pdf)
            rot = r.pages[0].get("/Rotate", 0)
            annots = sum(len(p.get("/Annots") or []) for p in r.pages)
            pdf_text = "".join(p.extract_text() or "" for p in r.pages)
            arabic = sum(1 for c in pdf_text if "؀" <= c <= "ۿ")      # the letter's Arabic text survived
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
