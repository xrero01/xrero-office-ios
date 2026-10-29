#!/usr/bin/env python3
"""check_saved.py <out/saved> - verifies what the UI tests saved on each simulator (iPhone, iPad):
xr-test.docx must contain the English (and, if the keyboard could type it, the Arabic) test text;
xr-clip.docx must hold the ribbon Copy/Paste round trip (own copy twice + outside plain text);
ar_letter.docx must still hold the original Arabic letter after open + save; File > Save As must export ar_letter.odt
(a real ODT with the letter) without rewriting the original, and the File menu must show no no-op entry;
the Arabic blanks (xr-test-ar.*, made with the app in Arabic) must come back from the engine still right-to-left;
the touch / typing gate (plan M14 + F1, EditorUITests.testTouchGateCaretSelectionPinchFocus) must log every check as
PASS (or KNOWN: a reported app gap) for EN and AR, and its saved xr-touch-<lang>.docx must hold the sentence with the tapped-in letter inside it,
the word typed after the Bold tap in a bold run, and the 5 Enter presses.
Prints each editor log."""
import os, re, sys, zipfile
import xml.etree.ElementTree as ET

W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"


def on(el):
    """an OOXML on/off element: present without w:val, or w:val 1/true/on"""
    return el is not None and el.get(W + "val", "1") in ("1", "true", "on")


def arabic_blank_docx(p, word):
    """the paragraph holding `word` is right-to-left (its own pPr, else its style chain, else the document
    defaults) and the document defaults still say Cairo + ar-AE"""
    z = zipfile.ZipFile(p)
    doc, sty = ET.fromstring(z.read("word/document.xml")), ET.fromstring(z.read("word/styles.xml"))
    styles = {s.get(W + "styleId"): s for s in sty.iter(W + "style")}
    default = next((s.get(W + "styleId") for s in sty.iter(W + "style") if s.get(W + "type") == "paragraph"
                    and s.get(W + "default") in ("1", "true", "on")), "Normal")
    para = next((q for q in doc.iter(W + "p") if word in "".join(t.text or "" for t in q.iter(W + "t"))), None)
    if para is None:
        return False, "text %r not found" % word
    bidi = para.find(W + "pPr/" + W + "bidi")
    src = "paragraph"
    if bidi is None:
        ps = para.find(W + "pPr/" + W + "pStyle")
        sid, seen = (ps.get(W + "val") if ps is not None else default), set()
        while bidi is None and sid in styles and sid not in seen:
            seen.add(sid)
            bidi, src = styles[sid].find(W + "pPr/" + W + "bidi"), "style " + sid
            b = styles[sid].find(W + "basedOn")
            sid = b.get(W + "val") if b is not None else None
    if bidi is None:
        bidi, src = sty.find(W + "docDefaults/" + W + "pPrDefault/" + W + "pPr/" + W + "bidi"), "docDefaults"
    rtl = on(bidi)
    rpr = sty.find(W + "docDefaults/" + W + "rPrDefault/" + W + "rPr")
    fonts = rpr.find(W + "rFonts") if rpr is not None else None
    lang = rpr.find(W + "lang") if rpr is not None else None
    cairo = fonts is not None and fonts.get(W + "cs") == "Cairo"
    ar_ae = lang is not None and lang.get(W + "bidi") == "ar-AE"
    return rtl and cairo and ar_ae, "w:bidi=%s (from %s) default font Cairo=%s lang ar-AE=%s" % (rtl, src, cairo, ar_ae)


def arabic_blank_other(p):
    z = zipfile.ZipFile(p)
    xml = {n: z.read(n).decode("utf-8", "replace") for n in z.namelist() if n.endswith(".xml")}
    if p.endswith(".xlsx"):
        rtl = any(re.search(r'<(?:\w+:)?sheetView[^>]*rightToLeft="(?:1|true)"', v)
                  for n, v in xml.items() if n.startswith("xl/worksheets/"))
        return rtl, "sheet rightToLeft=%s" % rtl
    master = "".join(v for n, v in xml.items() if n.startswith("ppt/slideMasters/slideMaster"))
    title = re.search(r"<p:titleStyle>\s*<a:lvl1pPr[^>]*>", master)
    rtl = bool(title) and 'rtl="1"' in title.group(0) and 'algn="r"' in title.group(0)
    return rtl, "master title right-aligned rtl=%s" % rtl


TOUCH = {   # what EditorUITests.touchGate types per language: sentence, tapped-in letter, word typed after Bold, last word
    "en": ("Extraordinary Wonderful Typewriter", "Q", "Bold", "End"),
    "ar": ("المستشفيات والمؤسسات الإماراتية", "ق", "عريض", "نهاية"),
}
# the checks every language must log (a missing line means the test stopped early: that is a failure too)
TOUCH_CHECKS = ("editor-ready", "tap-places-caret-first-line", "typing", "line-direction", "tap-moves-caret-into-text",
                "tap-then-type-inserts-there", "double-tap-selects-word", "long-press-selects-word", "caret-to-line-end",
                "bold-button-applies", "format-tap-keeps-keyboard", "type-after-format", "enter-x5", "select-all",
                "sheet-opens-and-closes", "sheet-return-keyboard", "sheet-return-caret", "pinch-in-zooms-page",
                "pinch-zoom-kept", "pinch-out-zooms-back", "save", "reopen-keeps-text")


def touch_gate(d, lang):
    """the gate lines the UI test logged + the saved document; returns ok"""
    good = True
    lg = os.path.join(d, "xr-log-xr-touch-%s.docx.txt" % lang)
    log = open(lg, encoding="utf-8", errors="replace").read() if os.path.exists(lg) else ""
    res = {}
    for m in re.finditer(r"^touch-gate %s ([\w-]+): (PASS|FAIL|KNOWN|INFO)\s*(.*)$" % lang, log, re.M):
        res[m.group(1)] = (m.group(2), m.group(3))
    print("Touch gate (%s):" % lang.upper())
    for name in TOUCH_CHECKS + tuple(k for k in res if k not in TOUCH_CHECKS):
        st, why = res.get(name, ("NOT LOGGED", ""))
        print("  %-30s %-10s %s" % (name, st, why[:160]))
        # KNOWN = a real app gap the gate found and reported (it passes by itself once fixed); FAIL / missing = fail
        if (name in TOUCH_CHECKS and st not in ("PASS", "KNOWN")) or st == "FAIL":
            good = False
    sentence, marker, bold_word, end_word = TOUCH[lang]
    p = os.path.join(d, "xr-touch-%s.docx" % lang)
    if not os.path.exists(p):
        print("  xr-touch-%s.docx: MISSING" % lang)
        return False
    try:
        doc = ET.fromstring(zipfile.ZipFile(p).read("word/document.xml"))
    except Exception as e:
        print("  xr-touch-%s.docx: cannot read: %s" % (lang, e))
        return False
    paras = ["".join(t.text or "" for t in q.iter(W + "t")) for q in doc.iter(W + "p")]
    first = next((s for s in paras if marker in s or sentence[:6] in s), "")
    inside = first.replace(marker, "").strip().startswith(sentence) and marker in first \
        and not first.startswith(marker) and sentence in first.replace(marker, "")
    bold = False
    for r in doc.iter(W + "r"):
        if bold_word in "".join(t.text or "" for t in r.iter(W + "t")):
            rpr = r.find(W + "rPr")
            bold |= rpr is not None and (on(rpr.find(W + "b")) or on(rpr.find(W + "bCs")))
    end_at = max((i for i, s in enumerate(paras) if end_word in s), default=-1)
    word_at = max((i for i, s in enumerate(paras) if bold_word in s), default=-1)
    enters = end_at >= 0 and word_at >= 0 and end_at - word_at >= 5
    saved = inside and bold and enters
    print("  xr-touch-%s.docx: letter tapped in inside the sentence=%s  word after Bold is bold=%s  5x Enter=%s  first line=%r -> %s"
          % (lang, inside, bold, enters, first[:80], "OK" if saved else "WRONG"))
    return good and saved


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
    c = os.path.join(d, "xr-clip.docx")       # clipboard test: ribbon Copy + Paste x2, then outside plain text
    if os.path.exists(c):
        s = text(c)
        flat = re.sub(r"[\s‎‏]+", "", s)
        pasted = flat.count("Helloمرحبا")
        outside = "Outside text 42" in s
        good = pasted >= 2 and outside
        print("xr-clip.docx: own copy pasted=%s (Hello+Arabic x%d)  outside text pasted=%s  text=%r -> %s"
              % (pasted >= 2, pasted, outside, s[:200], "OK" if good else "WRONG"))
        ok &= good
    else:
        print("xr-clip.docx: MISSING (clipboard copy/paste + save)"); ok = False
    for lang in ("en", "ar"):                     # touch / typing gate (plan M14 + F1)
        ok &= touch_gate(d, lang)
    for ext in ("docx", "xlsx", "pptx"):          # Arabic-first blanks (EditorUITests.testArabicBlanksStartRightToLeft)
        b = os.path.join(d, "xr-test-ar." + ext)
        if not os.path.exists(b):
            print("xr-test-ar.%s: MISSING" % ext); ok = False; continue
        try:
            good, why = arabic_blank_docx(b, "مرحبا") if ext == "docx" else arabic_blank_other(b)
        except Exception as e:
            good, why = False, "cannot read: %s" % e
        print("xr-test-ar.%s (Arabic blank, saved by the engine): right-to-left=%s  %s" % (ext, good, why))
        ok &= good
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
