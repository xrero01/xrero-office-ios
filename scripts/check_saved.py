#!/usr/bin/env python3
"""check_saved.py <out/saved> - verifies what the UI tests saved on each simulator (iPhone, iPad):
xr-test.docx must contain the English (and, if the keyboard could type it, the Arabic) test text;
xr-clip.docx must hold the ribbon Copy/Paste round trip (own copy twice + outside plain text);
ar_letter.docx must still hold the original Arabic letter after open + save; File > Save As must export ar_letter.odt
(a real ODT with the letter) without rewriting the original, and the File menu must show no no-op entry;
the Arabic blanks (xr-test-ar.*, made with the app in Arabic) must come back from the engine still right-to-left;
the touch / typing gate (plan M14 + F1, EditorUITests.testZZTouchGateCaretSelectionPinchFocus) must log every check as
PASS (or KNOWN: a reported app gap of the exact shape seen) for EN and AR (results also to out/qa/touch-gate.json), and its saved xr-touch-<lang>.docx must hold the sentence with the tapped-in letter inside it,
the word typed after the Bold tap and the word typed after the keyboard bar's Bold (plan M5) in bold runs, and the
5 Enter presses.
The Files gate (plan S9) must find the typed new document kept (English and Arabic), the one another window had
open kept, and no untouched new document left behind.
The window gate (plan S6, EditorUITests.testZZZZWindowLayoutAndKeyCommands + testZZZZZMenuBarOnRealEditor) must log
every check as PASS: the design follows the window (compact on the iPhone, regular on the full-screen iPad, compact
for a narrow iPad window, and the app's own rule gives compact under 600 pt on the iPad), the menu bar sees the
window's editor (MenuBarTargets) in the CI screen AND on the shipped DocumentOpener -> EditorHost path, Cmd+B from
the hardware keyboard and the menu bar's Format > Bold each toggle Bold exactly once (Cmd+I / Cmd+U once too), and
the menu bar's File > Close saves and closes the real editor - its xr-window-real.docx holds the word typed before.
Every editor log must be free of 'missing AscDesktopEditor.*' lines (engine contract: a member the editors ask the
shell for that xr-host.js does not define). Prints each editor log."""
import json, os, re, sys, zipfile
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


TOUCH = {   # what EditorUITests.touchGate types per language: sentence, tapped-in letter, word typed after Bold, last word,
            # word typed after the keyboard bar's Bold (plan M5)
    "en": ("Extraordinary Wonderful Typewriter", "Q", "Bold", "End", "Bar"),
    "ar": ("المستشفيات والمؤسسات الإماراتية", "ق", "عريض", "نهاية", "شريط"),
}
# the checks every language must log (a missing line means the test stopped early: that is a failure too)
TOUCH_CHECKS = ("editor-ready", "tap-places-caret-first-line", "typing", "line-direction", "tap-moves-caret-into-text",
                "tap-then-type-inserts-there", "double-tap-selects-word", "long-press-selects-word", "long-press-native-menu",
                # a long press on blank paper selects no word; a short tap on a busy page stays a tap (xr-host.js editMenu)
                "long-press-blank-no-word", "busy-tap-kept-as-tap",
                "caret-to-line-end",
                "bold-button-applies", "format-tap-keeps-keyboard", "type-after-format",
                "kbar-shown", "kbar-bold-on", "kbar-keeps-keyboard", "kbar-next-word-bold", "kbar-align-cycles",
                "enter-x5", "select-all",
                "sheet-opens-and-closes", "sheet-return-keyboard", "sheet-return-caret",
                "fmt-sheet-opens", "fmt-sheet-keyboard-down", "fmt-size-applies", "fmt-sheet-return-keyboard",
                "fmt-sheet-return-caret", "pinch-in-zooms-page",
                "pinch-zoom-kept", "pinch-in-no-menu", "pinch-out-zooms-back", "pinch-out-no-menu",
                "kbar-hide-keyboard", "save", "reopen-keeps-text")


QA = {}   # device -> lang -> {check: [status, detail]} + typing latency: written to out/qa/touch-gate.json (F1 trend)


def touch_gate(d, lang):
    """the gate lines the UI test logged + the saved document; returns ok"""
    good = True
    lg = os.path.join(d, "xr-log-xr-touch-%s.docx.txt" % lang)
    log = open(lg, encoding="utf-8", errors="replace").read() if os.path.exists(lg) else ""
    res = {}
    for m in re.finditer(r"^touch-gate %s ([\w-]+): (PASS|FAIL|KNOWN|INFO)\s*(.*)$" % lang, log, re.M):
        res[m.group(1)] = (m.group(2), m.group(3))
    qa = QA.setdefault(os.path.basename(d), {}).setdefault(lang, {"checks": {k: list(v) for k, v in res.items()}})
    lat = re.search(r"n=([\d.]+) median=(-?[\d.]+) ms p95=(-?[\d.]+) ms", res.get("typing-latency", ("", ""))[1])
    if lat:   # keydown -> 2nd requestAnimationFrame on the simulator: a trend figure, not the device bar
        qa["latency_ms"] = {"n": float(lat.group(1)), "median": float(lat.group(2)), "p95": float(lat.group(3)),
                            "measure": "keydown->2rAF, probe paused, simulator"}
    print("Touch gate (%s):" % lang.upper())
    for name in TOUCH_CHECKS + tuple(k for k in res if k not in TOUCH_CHECKS):
        st, why = res.get(name, ("NOT LOGGED", ""))
        print("  %-30s %-10s %s" % (name, st, why[:160]))
        # KNOWN = a real app gap the gate found and reported (it passes by itself once fixed); FAIL / missing = fail
        if (name in TOUCH_CHECKS and st not in ("PASS", "KNOWN")) or st == "FAIL":
            good = False
    # the busy-page tap (touch-gate busy-tap-kept-as-tap): the hook really held the page and the edit menu kept the tap
    held = re.search(r"^busy hook: the page was held busy \d+ ms", log, re.M) is not None
    kept = re.search(r"^edit menu: a \d+ ms tap reached the engine as a long press - kept as a tap", log, re.M) is not None
    print("  busy-page tap: page held busy=%s  kept as a tap=%s -> %s" % (held, kept, "OK" if held and kept else "WRONG"))
    good &= held and kept
    sentence, marker, bold_word, end_word, bar_word = TOUCH[lang]
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
    def is_bold(word):
        b = False
        for r in doc.iter(W + "r"):
            if word in "".join(t.text or "" for t in r.iter(W + "t")):
                rpr = r.find(W + "rPr")
                b |= rpr is not None and (on(rpr.find(W + "b")) or on(rpr.find(W + "bCs")))
        return b
    bold = is_bold(bold_word)
    bar_bold = is_bold(bar_word)          # the keyboard bar's Bold reached the document (plan M5)
    end_at = max((i for i, s in enumerate(paras) if end_word in s), default=-1)
    word_at = max((i for i, s in enumerate(paras) if bold_word in s), default=-1)
    enters = end_at >= 0 and word_at >= 0 and end_at - word_at >= 5
    saved = inside and bold and bar_bold and enters
    print("  xr-touch-%s.docx: letter tapped in inside the sentence=%s  word after Bold is bold=%s  word after keyboard-bar Bold is bold=%s  5x Enter=%s  first line=%r -> %s"
          % (lang, inside, bold, bar_bold, enters, first[:80], "OK" if saved else "WRONG"))
    return good and saved


# the spreadsheet gate (plan S3, EditorUITests.sheetGate): every check each language must log
SHEET_CHECKS = ("editor-ready", "a1-chip", "math-box-replaced", "chip-goes-to-cell", "formula-bar-tap-edits", "values-typed",
                "chip-selects-range", "sum-capsule", "sum-sheet", "sum-insert-below", "fkeys-shown", "fkeys-formula",
                "fkeys-commit", "fkeys-cancel", "fkeys-tab", "fkeys-hide-keyboard", "save")


def sheet_gate(d, lang):
    """the spreadsheet gate's lines + the saved xr-sheet-<lang>.xlsx (typed values, =SUM below the range from the Sum
    sheet's Insert below, =MAX(A1:A3,A4) built with the formula keys, 5 kept by the Tab key); returns ok"""
    good = True
    lg = os.path.join(d, "xr-log-xr-sheet-%s.xlsx.txt" % lang)
    log = open(lg, encoding="utf-8", errors="replace").read() if os.path.exists(lg) else ""
    res = {}
    for m in re.finditer(r"^sheet-gate %s ([\w-]+): (PASS|FAIL|KNOWN|INFO)\s*(.*)$" % lang, log, re.M):
        res[m.group(1)] = (m.group(2), m.group(3))
    QA.setdefault(os.path.basename(d), {}).setdefault("sheet-" + lang, {"checks": {k: list(v) for k, v in res.items()}})
    print("Spreadsheet gate (%s):" % lang.upper())
    for name in SHEET_CHECKS + tuple(k for k in res if k not in SHEET_CHECKS):
        st, why = res.get(name, ("NOT LOGGED", ""))
        print("  %-30s %-10s %s" % (name, st, why[:200]))
        if (name in SHEET_CHECKS and st not in ("PASS", "KNOWN")) or st == "FAIL":
            good = False
    p = os.path.join(d, "xr-sheet-%s.xlsx" % lang)
    if not os.path.exists(p):
        print("  xr-sheet-%s.xlsx: MISSING" % lang)
        return False
    try:
        xml = zipfile.ZipFile(p).read("xl/worksheets/sheet1.xml").decode("utf-8")
    except Exception as e:
        print("  xr-sheet-%s.xlsx: cannot read: %s" % (lang, e))
        return False
    def c(ref):
        m = re.search(r'<c r="%s"[^>]*?(?:/>|>(.*?)</c>)' % ref, xml, re.S)
        body = (m.group(1) or "") if m else ""
        f = re.search(r"<f[^>]*>(.*?)</f>", body, re.S)
        v = re.search(r"<v>(.*?)</v>", body, re.S)
        return (f.group(1) if f else ""), (v.group(1) if v else "")
    cells = {r: c(r) for r in ("A1", "A2", "A3", "A4", "B1", "C1")}
    values = [cells[r][1] for r in ("A1", "A2", "A3")] == ["12", "30", "1246"]
    total = cells["A4"][0].replace(" ", "").upper() == "SUM(A1:A3)" and cells["A4"][1] in ("1288", "")
    keys = cells["B1"][0].replace(" ", "").upper() == "MAX(A1:A3,A4)"
    tab = cells["C1"][1] == "5"
    saved = values and total and keys and tab
    print("  xr-sheet-%s.xlsx: values=%s  A4 =SUM(A1:A3)=%s  B1 =MAX(A1:A3,A4)=%s  C1 5 (Tab)=%s  cells=%r -> %s"
          % (lang, values, total, keys, tab, cells, "OK" if saved else "WRONG"))
    return good and saved


# the PDF tool bar gate (plan S7, EditorUITests.testZZPdfToolBarGate): the checks each language must log, and the
# pictures (check mark, cross, date, signatures) the gate put on the page must be in the saved PDF
PDF_CHECKS = {
    "en": ("editor-ready", "bar-shown", "mode-switch", "opens-reading", "highlight-on", "underline-on", "strike-on",
           "done-ends-tool", "pen-on", "eraser-on", "pen-stroke-makes-ink", "colour-picked", "note-reachable",
           "fill-shown", "check-placed", "check-sized", "cross-placed", "date-placed", "signature-sheet", "signature-honest-label",
           "signature-drawn-placed", "signature-sized", "my-signature-2-taps", "save", "reopen"),
    "ar": ("editor-ready", "bar-shown", "mode-switch", "opens-reading", "ar-labels", "ar-mirrored", "highlight-on",
           "underline-on", "strike-on", "done-ends-tool", "colour-picked", "note-reachable", "fill-shown",
           "check-placed", "check-sized", "signature-sheet", "signature-honest-label", "signature-typed-arabic-placed",
           "signature-sized",
           "my-signature-2-taps", "save", "reopen"),
}
PDF_PICTURES = {"en": 5, "ar": 3}       # en: check, cross, date, drawn signature, My signature; ar: check, typed, mine


def pdf_images(path):
    """image XObjects drawn on the PDF's pages (also inside form XObjects, tiling patterns - the converter paints a
    placed picture as a rectangle filled with an image pattern - and annotation appearances)"""
    from pypdf import PdfReader
    seen, count = set(), 0
    def walk(res):
        nonlocal count
        try:
            xo = res.get("/XObject") if res is not None else None
            xo = xo.get_object() if xo is not None else None
        except Exception:
            return
        for k in (xo or {}):
            ref = xo.raw_get(k)
            key = getattr(ref, "idnum", None) or id(ref)
            if key in seen:
                continue
            seen.add(key)
            o = ref.get_object()
            if o.get("/Subtype") == "/Image":
                count += 1
            elif o.get("/Subtype") == "/Form":
                walk(o.get("/Resources"))
        try:
            pats = res.get("/Pattern") if res is not None else None
            pats = pats.get_object() if pats is not None else None
        except Exception:
            pats = None
        for k in (pats or {}):
            ref = pats.raw_get(k)
            key = ("pattern", getattr(ref, "idnum", None) or id(ref))
            if key in seen:
                continue
            seen.add(key)
            o = ref.get_object()
            if hasattr(o, "get") and o.get("/PatternType") == 1:          # tiling pattern: its own resources
                walk(o.get("/Resources"))
    r = PdfReader(path)
    for pg in r.pages:
        walk(pg.get("/Resources"))
        for a in (pg.get("/Annots") or []):
            ap = a.get_object().get("/AP")
            n = ap.get_object().get("/N") if ap is not None else None
            if n is not None and hasattr(n.get_object(), "get"):
                walk(n.get_object().get("/Resources"))
    return count, len(r.pages)


def pdf_bar(d, lang):
    """the PDF bar gate lines + the saved PDF; returns ok"""
    good = True
    lg = os.path.join(d, "xr-log-xr-pdf-bar-%s.pdf.txt" % lang)
    log = open(lg, encoding="utf-8", errors="replace").read() if os.path.exists(lg) else ""
    res = {}
    for m in re.finditer(r"^pdf-gate %s ([\w-]+): (PASS|FAIL|KNOWN|INFO)\s*(.*)$" % lang, log, re.M):
        res[m.group(1)] = (m.group(2), m.group(3))
    QA.setdefault(os.path.basename(d), {}).setdefault("pdf-" + lang, {"checks": {k: list(v) for k, v in res.items()}})
    print("PDF tool bar gate (%s):" % lang.upper())
    for name in PDF_CHECKS[lang] + tuple(k for k in res if k not in PDF_CHECKS[lang]):
        st, why = res.get(name, ("NOT LOGGED", ""))
        print("  %-30s %-10s %s" % (name, st, why[:160]))
        if (name in PDF_CHECKS[lang] and st not in ("PASS", "KNOWN")) or st == "FAIL":
            good = False
    p = os.path.join(d, "xr-pdf-bar-%s.pdf" % lang)
    orig = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "ar_letter.pdf")
    if not os.path.exists(p):
        print("  xr-pdf-bar-%s.pdf: MISSING" % lang)
        return False
    try:
        n0, _ = pdf_images(orig)
        n1, pages = pdf_images(p)
        added = n1 - n0
        pics = added >= PDF_PICTURES[lang]
        print("  xr-pdf-bar-%s.pdf (read with pypdf, outside the app): pages=%d pictures %d -> %d (+%d, want +%d) -> %s"
              % (lang, pages, n0, n1, added, PDF_PICTURES[lang], "OK" if pics else "WRONG"))
        good &= pics
    except Exception as e:
        print("  xr-pdf-bar-%s.pdf: cannot read: %s" % (lang, e))
        good = False
    return good


# PDF forms (21.0, EditorUITests.testPdfFormFields): the typed values must be in the SAVED page. Other apps draw a field
# from its saved appearance (/AP /N), not from its value (/V), so each typed field's appearance must draw something:
# glyph outlines (an embedded font: XR-FIELD-AP + scripts/patch_field_ap_ios.py) or text in a font x2t embedded
# (a standard-font field: xr-host.js fontUrls). With PyMuPDF the embedded-font Arabic line is also drawn and compared
# with the same text shaped by MuPDF / HarfBuzz in the field's own font (joined letters, not separate ones).
AR_CLIENT = "مؤسسة الإمارات للملاحظات"
FORM_VALUES = {
    "xr-form-embedded.pdf": {"client": AR_CLIENT, "ref": "XO-2026-014", "office": "الشارقة"},
    "xr-form-booking.pdf": {"department": "المشاريع", "office": "الشارقة", "date": "24/11/2026", "attendees": "12"},
}
FORM_CHECKS = {   # the test's own hard lines (INFO lines are printed, never required)
    "xr-form-embedded.pdf": ("editor-ready", "client-editing", "client-typed", "ref-editing", "ref-typed",
                             "office-editing", "office-typed", "field-ap-shim", "save"),
    "xr-form-booking.pdf": ("editor-ready", "department-editing", "office-typed", "date-typed", "attendees-typed", "save"),
}
FORM_MATCH_OK = 0.85      # ink match of the saved Arabic line with its HarfBuzz reference (Mac engine_checks.py)


def glyph_fills(s):
    """fills of paths that begin with a moveto in a content stream: glyph outlines, not a background 're' rectangle"""
    s = re.sub(r"\((?:\\.|[^\\)])*\)", " ", s)
    s = re.sub(r"<[0-9A-Fa-f\s]*>", " ", s)
    n, has_m = 0, False
    for tok in s.split():
        if tok[0] in "/[]<>" or re.match(r"^[-+.\d]", tok):
            continue
        if tok == "m":
            has_m = True
        elif tok in ("f", "f*", "F", "B", "B*", "b", "b*"):
            n += has_m
            has_m = False
        elif tok in ("n", "S", "s"):
            has_m = False
    return n


def form_fields(path):
    """{field name: {value, kind, text_ops, glyph_fills, state}} read with pypdf"""
    from pypdf import PdfReader
    out = {}
    for pg in PdfReader(path).pages:
        for a in (pg.get("/Annots") or []):
            w = a.get_object()
            par = w.get("/Parent")
            par = par.get_object() if par is not None else None
            name = w.get("/T") or (par.get("/T") if par is not None else None)
            if name is None:
                continue
            ft = w.get("/FT") or (par.get("/FT") if par is not None else None)
            v = w.get("/V") if w.get("/V") is not None else (par.get("/V") if par is not None else None)
            r = {"value": str(v) if v is not None else None, "kind": str(ft), "state": str(w.get("/AS"))}
            ap = w.get("/AP")
            n = ap.get_object().get("/N") if ap is not None else None
            n = n.get_object() if n is not None else None
            if ft == "/Tx" and n is not None and hasattr(n, "get_data"):
                s = n.get_data().decode("latin1")
                r["text_ops"] = len(re.findall(r"\bT[jJ]\b", s))
                r["glyph_fills"] = glyph_fills(s)
            out[str(name)] = r
    return out


def form_draw(path, field, value, font_name, evid):
    """PyMuPDF (when installed): the saved field drawn from its appearance -> (ink pixels, match with HarfBuzz or None)"""
    try:
        import pymupdf as fz
    except ImportError:
        try:
            import fitz as fz
        except ImportError:
            return None, None
    d = fz.open(path)
    try:
        w = next((x for x in d[0].widgets() if x.field_name == field), None)
        if w is None:
            return None, None
        zoom = 4
        pix = d[0].get_pixmap(matrix=fz.Matrix(zoom, zoom), clip=w.rect, annots=True)
        pix.save(os.path.join(evid, "form-%s-%s-saved.png" % (os.path.basename(path)[:-4], field)))
        ink = ink_mask(pix)
        n_ink = sum(v for r in ink for v in r)
        if not font_name:
            return n_ink, None
        # the field's own font program from /AcroForm/DR/Font/<name>
        af = d.xref_get_key(d.pdf_catalog(), "AcroForm/DR/Font/" + font_name)
        if af[0] != "xref":
            return n_ink, None
        f = int(af[1].split()[0])
        desc = re.search(r"DescendantFonts \[ ?(\d+)", d.xref_object(f))
        fobj = int(desc.group(1)) if desc else f
        fd = int(re.search(r"FontDescriptor (\d+)", d.xref_object(fobj)).group(1))
        ff = int(re.search(r"FontFile2 (\d+)", d.xref_object(fd)).group(1))
        ttf = os.path.join(evid, "_dr_%s.ttf" % font_name)
        open(ttf, "wb").write(d.xref_stream(ff))
        ref = fz.open()
        pg = ref.new_page(width=w.rect.width + 20, height=w.rect.height + 30)
        rtl = any("؀" <= c <= "ۿ" for c in value)
        css = "@font-face{font-family:f;src:url(%s)}div{font-family:f}" % os.path.basename(ttf)
        box = fz.Rect(10, 10, 10 + w.rect.width, 10 + w.rect.height + 12)
        pg.insert_htmlbox(box, '<div dir="%s" style="font-size:%gpt;color:#000">%s</div>'
                          % ("rtl" if rtl else "ltr", w.text_fontsize or 14, value),
                          css=css, archive=fz.Archive(os.path.dirname(ttf)), scale_low=1)
        rp = pg.get_pixmap(matrix=fz.Matrix(zoom, zoom), clip=box)
        return n_ink, ink_match(ink, ink_mask(rp), 2)
    finally:
        d.close()


def ink_mask(pix, thr=140):
    w, h, n, s, st = pix.width, pix.height, pix.n, pix.samples, pix.stride
    return [[((s[y * st + x * n] * 299 + s[y * st + x * n + 1] * 587 + s[y * st + x * n + 2] * 114) // 1000) < thr
             if n >= 3 else s[y * st + x * n] < thr for x in range(w)] for y in range(h)]


def ink_match(a, b, k=1):
    """share of each drawing's ink within k px of the other's (both ink-cropped, b scaled to a's box); 1.0 = same"""
    def crop(m):
        ys = [y for y, r in enumerate(m) if any(r)]
        if not ys:
            return None
        xs = [x for x in range(len(m[0])) if any(m[y][x] for y in ys)]
        return [r[xs[0]:xs[-1] + 1] for r in m[ys[0]:ys[-1] + 1]]
    def dil(m):
        h, w = len(m), len(m[0])
        out = [[False] * w for _ in range(h)]
        for y in range(h):
            for x in range(w):
                if m[y][x]:
                    for yy in range(max(0, y - k), min(h, y + k + 1)):
                        for xx in range(max(0, x - k), min(w, x + k + 1)):
                            out[yy][xx] = True
        return out
    a, b = crop(a), crop(b)
    if a is None or b is None:
        return 0.0
    h, w = len(a), len(a[0])
    H, W = len(b), len(b[0])
    b = [[b[min(H - 1, y * H // h)][min(W - 1, x * W // w)] for x in range(w)] for y in range(h)]
    da, db = dil(a), dil(b)
    na = sum(v for r in a for v in r) or 1
    nb = sum(v for r in b for v in r) or 1
    pa = sum(1 for y in range(h) for x in range(w) if a[y][x] and db[y][x]) / na
    pb = sum(1 for y in range(h) for x in range(w) if b[y][x] and da[y][x]) / nb
    return round((pa + pb) / 2, 3)


def pdf_form(d):
    """the PDF form test's lines + the two saved forms (values and what their saved appearance draws); returns ok"""
    good = True
    evid = os.path.join(os.path.dirname(os.path.abspath(root)), "qa", "forms-" + os.path.basename(d))
    os.makedirs(evid, exist_ok=True)
    for name, want in FORM_VALUES.items():
        print("PDF form %s:" % name)
        lg = os.path.join(d, "xr-log-%s.txt" % name)
        log = open(lg, encoding="utf-8", errors="replace").read() if os.path.exists(lg) else ""
        res = {}
        for m in re.finditer(r"^form-gate %s ([\w-]+): (PASS|FAIL|INFO)\s*(.*)$" % re.escape(name), log, re.M):
            res[m.group(1)] = (m.group(2), m.group(3))
        for c in FORM_CHECKS[name] + tuple(k for k in res if k not in FORM_CHECKS[name]):
            st, why = res.get(c, ("NOT LOGGED", ""))
            print("  %-26s %-10s %s" % (c, st, why[:170]))
            if (c in FORM_CHECKS[name] and st != "PASS") or st == "FAIL":
                good = False
        for l in re.findall(r"^saved %s [^\n]*" % re.escape(name), log, re.M):
            print("  log:", l)
        p = os.path.join(d, name)
        if not os.path.exists(p):
            print("  %s: MISSING" % name)
            good = False
            continue
        try:
            got = form_fields(p)
        except Exception as e:
            print("  %s: cannot read: %s" % (name, e))
            good = False
            continue
        for field, value in want.items():
            g = got.get(field, {})
            drawn = (g.get("text_ops") or 0) + (g.get("glyph_fills") or 0)
            ok_v = g.get("value") == value
            ink, match = form_draw(p, field, value, "PlexAr" if name == "xr-form-embedded.pdf" and field != "office" else None, evid)
            line_ok = ok_v and drawn > 0 and (ink is None or ink > 0)
            if field == "client":              # Arabic in the embedded font: joined letters, as outlines
                line_ok &= (g.get("glyph_fills") or 0) >= 15 and (match is None or match >= FORM_MATCH_OK)
            print("  %-12s value=%s (%s) appearance: text ops %s, glyph outlines %s, ink %s, HarfBuzz match %s -> %s"
                  % (field, g.get("value"), "OK" if ok_v else "WANT %s" % value, g.get("text_ops"), g.get("glyph_fills"),
                     ink, match, "OK" if line_ok else "WRONG"))
            good &= line_ok
        if name == "xr-form-booking.pdf":       # recorded: the check boxes ticked by Return (Tab path) and by a tap
            for box in ("display", "video", "refreshments"):
                print("  %-12s saved value %s, appearance state %s (informational)" % (box, got.get(box, {}).get("value"),
                                                                                       got.get(box, {}).get("state")))
    return good


KBDIR_CHECKS = ("editor-ready", "keyboard-up", "observer", "empty-arabic-rtl", "empty-english-ltr", "empty-arabic-rtl-again",
                "arabic-typed", "text-paragraph-kept", "new-empty-english-ltr", "english-text-kept", "both-typed", "save")
# the shipped default of the setting (no -xr.kbDirection): xr-log-xr-kbdef-<lang>.docx.txt
KBDEF_CHECKS = ("default-editor-ready", "default-keyboard-up", "default-observer", "default-switch")


def para_bidi(p, word):
    """the effective w:bidi of the paragraph holding `word`: its own pPr, else its style chain, else the document
    defaults (as arabic_blank_docx resolves it); None when the word is not found"""
    z = zipfile.ZipFile(p)
    doc, sty = ET.fromstring(z.read("word/document.xml")), ET.fromstring(z.read("word/styles.xml"))
    styles = {s.get(W + "styleId"): s for s in sty.iter(W + "style")}
    default = next((s.get(W + "styleId") for s in sty.iter(W + "style") if s.get(W + "type") == "paragraph"
                    and s.get(W + "default") in ("1", "true", "on")), "Normal")
    para = next((q for q in doc.iter(W + "p") if word in "".join(t.text or "" for t in q.iter(W + "t"))), None)
    if para is None:
        return None, "not found"
    bidi, src = para.find(W + "pPr/" + W + "bidi"), "paragraph"
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
    return on(bidi), src


def kbdir_gate(d, lang):
    """plan C1 (EditorUITests.testZZKeyboardDirectionFollowsKeyboard): every kbdir-* line PASS, and the saved
    xr-kbdir-<lang>.docx keeps the Arabic paragraph right-to-left and the English one left-to-right"""
    good = True
    lg = os.path.join(d, "xr-log-xr-kbdir-%s.docx.txt" % lang)
    log = open(lg, encoding="utf-8", errors="replace").read() if os.path.exists(lg) else ""
    lg2 = os.path.join(d, "xr-log-xr-kbdef-%s.docx.txt" % lang)
    log += "\n" + (open(lg2, encoding="utf-8", errors="replace").read() if os.path.exists(lg2) else "")
    res = {}
    for m in re.finditer(r"^touch-gate %s kbdir-([\w-]+): (PASS|FAIL|KNOWN|INFO)\s*(.*)$" % lang, log, re.M):
        res[m.group(1)] = (m.group(2), m.group(3))
    QA.setdefault(os.path.basename(d), {}).setdefault(lang, {}).setdefault("checks", {}).update(
        {"kbdir-" + k: list(v) for k, v in res.items()})
    print("Keyboard direction gate C1 (%s):" % lang.upper())
    want = KBDIR_CHECKS + KBDEF_CHECKS
    for name in want + tuple(k for k in res if k not in want):
        st, why = res.get(name, ("NOT LOGGED", ""))
        print("  %-30s %-10s %s" % ("kbdir-" + name, st, why[:160]))
        if (name in want and st != "PASS") or st == "FAIL":
            good = False
    p = os.path.join(d, "xr-kbdir-%s.docx" % lang)
    if not os.path.exists(p):
        print("  xr-kbdir-%s.docx: MISSING" % lang)
        return False
    try:
        ar, ar_src = para_bidi(p, "سلام")       # سلام
        en, en_src = para_bidi(p, "Hello")
    except Exception as e:
        print("  xr-kbdir-%s.docx: cannot read: %s" % (lang, e))
        return False
    saved = ar is True and en is False
    print("  xr-kbdir-%s.docx: Arabic paragraph rtl=%s (%s)  English paragraph rtl=%s (%s) -> %s"
          % (lang, ar, ar_src, en, en_src, "OK" if saved else "WRONG"))
    return good and saved


def doc_menu(d):
    """The ⋯ document menu (plan M7b, EditorUITests.testDocumentMenu + testSpreadsheetAndPresentationOpen): every
    Export ▸ copy is a real file of its format holding what was on screen; the File menu (opened through ⋯ > All tools,
    its tab hidden on touch) keeps its Close Menu entry; the PDF spike is REPORTED only (PDF / Print are not offered)."""
    good = True
    want_ar = "مرحبا"
    for f, kind in (("exp-xr-menu-en.docx", "docx"), ("xr-menu-en.odt", "odt"), ("xr-menu-en.rtf", "rtf"),
                    ("exp-xr-menu-ar.docx", "docx")):
        p = os.path.join(d, f)
        if not os.path.exists(p):
            print("%s: MISSING (⋯ > Export ▸ .%s)" % (f, kind)); good = False; continue
        try:
            if kind == "docx":
                s = text(p); g = "Menu check" in s and want_ar in s
            elif kind == "odt":
                z = zipfile.ZipFile(p)
                body = re.sub(r"<[^>]+>", "", z.read("content.xml").decode("utf-8"))
                g = z.read("mimetype") == b"application/vnd.oasis.opendocument.text" and "Menu check" in body and want_ar in body
            else:
                raw = open(p, "rb").read()
                # x2t writes every character as an RTF escape (\uN* with N the signed 16-bit code): decode them
                esc = re.compile(re.escape(bytes([92])) + rb"u(-?[0-9]+)[*]?")      # a backslash, u, the number
                txt = esc.sub(lambda m: chr(int(m.group(1)) % 65536).encode("utf-8"), raw).decode("utf-8", "replace")
                g = raw.startswith(rb"{\rtf") and "Menu check" in txt and want_ar in txt
        except Exception as e:
            g = False; print("%s: cannot read: %s" % (f, e))
        print("%s (⋯ > Export ▸ .%s): text on screen kept -> %s" % (f, kind, "OK" if g else "WRONG"))
        good &= g
    for f, part, mime in (("exp-xr-test.xlsx", "xl/workbook.xml", None), ("exp-xr-test.pptx", "ppt/presentation.xml", None),
                          ("xr-test.odp", "content.xml", b"application/vnd.oasis.opendocument.presentation")):
        p = os.path.join(d, f)
        if not os.path.exists(p):
            print("%s: MISSING (⋯ > Export)" % f); good = False; continue
        try:
            z = zipfile.ZipFile(p)
            g = part in z.namelist() and (mime is None or z.read("mimetype") == mime)
        except Exception as e:
            g = False; print("%s: cannot read: %s" % (f, e))
        print("%s (⋯ > Export): %s" % (f, "OK" if g else "WRONG"))
        good &= g
    lg = os.path.join(d, "xr-log-xr-menu-en.docx.txt")
    log = open(lg, encoding="utf-8", errors="replace").read() if os.path.exists(lg) else ""
    for what in ("find", "doc info", "all tools"):
        r = re.findall(r"menu %s: ([^\n]*)" % what, log)
        print("⋯ > %s: %s" % (what, r[-1] if r else "NOT LOGGED"))
        good &= bool(r) and r[-1] == "ok"
    # the PDF spike (informational): x2t's answer, and if it wrote a file, whether its Arabic text can be copied out
    spike = re.findall(r"pdf spike[^\n]*", log)
    print("PDF spike:", " | ".join(spike) if spike else "NOT RUN")
    sp = os.path.join(d, "xr-menu-en-spike.pdf")
    if os.path.exists(sp):
        try:
            from pypdf import PdfReader
            t = "".join(pg.extract_text() or "" for pg in PdfReader(sp).pages)
            print("PDF spike copy-text: %r -> Arabic copyable=%s (informational: PDF / Print stay hidden until this passes)"
                  % (t[:80], want_ar in t))
        except Exception as e:
            print("PDF spike: the written PDF cannot be read:", e)
    return good


def title_menu(d):
    """The title menu (plan M4b, EditorUITests.testTitleMenuRenameSaveReopen, the real UIDocument path): after
    type + save, Rename, type + save, Duplicate, reopen from Recent, type + save, the renamed file holds all three
    words (the saves after the rename and after the reopen landed in it), nothing is left at the old name (no ghost
    file), and the copy holds the first two. English and an Arabic file name."""
    import unicodedata
    good = True
    names = {unicodedata.normalize("NFC", f): f for f in os.listdir(d)}
    for old, new, words in (("xr-ren-en.docx", "Renamed note", ("Alpha", "Beta", "Gamma")),
                            ("xr-ren-ar.docx", "ملاحظة الاجتماع", ("Delta", "Omega", "Sigma"))):
        ghost = old in names
        f = names.get(unicodedata.normalize("NFC", new + ".docx"))
        if f is None:
            print("%s.docx: MISSING (title menu > Rename of %s)%s" % (new, old, " - the file is still at the old name" if ghost else ""))
            good = False; continue
        try:
            s = text(os.path.join(d, f))
        except Exception as e:
            print("%s: cannot read: %s" % (f, e)); good = False; continue
        has = [w in s for w in words]
        g = all(has) and not ghost
        print("%s (renamed from %s): words %s=%s  old name gone=%s  text=%r -> %s"
              % (f, old, "/".join(words), has, not ghost, s[:120], "OK" if g else "WRONG"))
        good &= g
        c = names.get(unicodedata.normalize("NFC", new + (" - نسخة" if old.endswith("-ar.docx") else " copy") + ".docx"))
        if c is None:
            print("  copy of %s: MISSING (title menu > Duplicate)" % new); good = False
        else:
            cs = text(os.path.join(d, c))
            cg = words[0] in cs and words[1] in cs
            print("  %s (Duplicate): %s+%s inside=%s -> %s" % (c, words[0], words[1], cg, "OK" if cg else "WRONG"))
            good &= cg
    return good


def files_gate(d):
    """Files (plan S9, EditorUITests.testFilesPickerSheetAndUntouchedNewFile, the real UIDocument path), English then
    Arabic interface. English: the new document typed into ("Kept") was kept under the name the untouched new document
    before it had freed again by being removed on close, so Document.docx holds "Kept"; Document 2.docx is the new
    document another window also had open when this one closed it unchanged - kept, never typed into; no other
    "Document N.docx" (an untouched file left behind). Arabic: the same on the right-to-left blank - مستند.docx holds
    the typed Arabic word in a right-to-left paragraph, and no "مستند N.docx" is left."""
    good = True
    # Stage 6: a later test makes a new file in the same app folder - ScanQuickActionUITests' New Document quick action
    # opens a new "Document N" and the test then ends the app with it open, so it is never closed (nor tidied). Only the
    # file that test names in its own line ("XR quick new-document <lang>: title=<name>", out/ui-<device>.log) is set
    # aside here; any other "Document N" is still an untouched file left behind.
    ui = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(d))),
                      "ui-%s.log" % os.path.basename(os.path.normpath(d)))
    later = []
    if os.path.exists(ui):
        later = [t.strip() + ".docx" for t in re.findall(r"XR quick new-document \w+: title=([^\n]+)",
                                                           open(ui, encoding="utf-8", errors="replace").read())]
    for name, word, rtl in (("Document", "Kept", False),
                            ("مستند", "محفوظ", True)):
        p = os.path.join(d, name + ".docx")
        if not os.path.exists(p):
            print("%s.docx: MISSING (Files: a new document typed into must be kept)" % name)
            good = False
            continue
        try:
            s = text(p)
            bidi = arabic_blank_docx(p, word) if rtl else (True, "")
        except Exception as e:
            print("%s.docx: cannot read:" % name, e)
            good = False
            continue
        # English: Document 2.docx is the one kept for the other window (asserted by the test); nothing beyond it
        held = ["Document 2.docx"] if name == "Document" else []
        left = sorted(f for f in os.listdir(d)
                      if re.match(re.escape(name) + r" \d+\.docx$", f) and f not in held and f not in later)
        aside = sorted(f for f in os.listdir(d) if f in later and f.startswith(name))
        held_ok = all(os.path.exists(os.path.join(d, h)) and word not in text(os.path.join(d, h)) for h in held)
        one = word in s and not left and held_ok and bidi[0]
        print("%s.docx (Files: new, typed into, kept): %r inside=%s  untouched new files left=%s%s%s%s  text=%r -> %s"
              % (name, word, word in s, left or "none",
                 ("  (the quick-action test's own new file: %s)" % ", ".join(aside)) if aside else "",
                 ("  kept for another window: %s=%s" % (held[0], held_ok)) if held else "",
                 ("  right-to-left: " + bidi[1]) if rtl else "", s[:80], "OK" if one else "WRONG"))
        good &= one
    return good


def reading_view(d):
    """The reading view (plan S2, EditorUITests.testReadingViewEditDoneThenType, the real UIDocument path): the 6-page
    reading document (the store letter + 5 pages) opened as an existing file in reading state, Edit / Done switched 10
    times, then Edit and an English and an Arabic line typed - both lines must be in the saved xr-read-<lang>.docx (the
    editor's input field stayed healthy through the switches) with the letter and its last page kept. English and
    Arabic interface."""
    good = True
    for lang in ("en", "ar"):
        f = os.path.join(d, "xr-read-%s.docx" % lang)
        if not os.path.exists(f):
            print("xr-read-%s.docx: MISSING (reading view: Edit / Done x10, then type + save)" % lang); good = False; continue
        try:
            s = text(f)
        except Exception as e:
            print("xr-read-%s.docx: cannot read: %s" % (lang, e)); good = False; continue
        flat = re.sub(r"[‎‏]", "", s)
        en = "Reading view OK." in flat
        ar = "وضع القراءة" in flat
        kept = "السادة أولياء الأمور الكرام" in flat
        # the 6-page reading document (tests/reading_6p.docx): its last page is still there after the save (two of its
        # lines: the typing lands wherever the test's tap put the caret, and it could be inside one of them)
        pages = "Page 6 of 6" in flat or "Line 4 on page 6" in flat
        g = en and ar and kept and pages
        print("xr-read-%s.docx (reading view, Edit / Done x10 then typing): English typed=%s  Arabic typed=%s  letter kept=%s  6 pages kept=%s -> %s"
              % (lang, en, ar, kept, pages, "OK" if g else "WRONG"))
        good &= g
    return good


def gallery(d):
    """The template gallery (plan S8, TemplateGalleryUITests): every template, EN + AR, was made from the gallery,
    opened and saved by the engine (an x2t round trip) under its name in that language; each saved copy still holds its
    template text, the Arabic ones are still right-to-left, the spreadsheets keep their formulas; the letters hold the
    English (and, if the keyboard could type it, the Arabic) text typed into them, which the test also read back after
    a relaunch."""
    man = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "web", "templates", "gallery.json"),
                         encoding="utf-8"))
    good = True
    typed_en, typed_ar = "Typed in template.", "كتابة في القالب"
    for t in man["templates"]:
        ext = t["file"]["en"].rsplit(".", 1)[1]
        for lang in ("en", "ar"):
            f = "%s.%s" % (t["name"][lang], ext)
            p = os.path.join(d, f)
            if not os.path.exists(p):
                print("template %s (%s) %s: MISSING" % (t["id"], lang, f)); good = False; continue
            try:
                z = zipfile.ZipFile(p)
                xml = {n: z.read(n).decode("utf-8", "replace") for n in z.namelist() if n.endswith(".xml")}
                marker = t["marker"][lang]
                if ext == "docx":
                    s = text(p)
                    kept = marker in s
                    rtl, why = arabic_blank_docx(p, marker) if lang == "ar" else (True, "")
                    extra = ""
                    if t["id"] == "letter":
                        flat = re.sub(r"[‎‏]", "", s)
                        en, ar = typed_en in flat, typed_ar in flat
                        extra = "  English typed=%s  Arabic typed=%s" % (en, ar)
                        kept &= en
                    g = kept and rtl
                    print("template %s (%s) %s: template text kept=%s%s%s -> %s"
                          % (t["id"], lang, f, marker in s, extra, ("  right-to-left: " + why) if lang == "ar" else "",
                             "OK" if g else "WRONG"))
                else:
                    sheets = "".join(v for n, v in xml.items() if n.startswith("xl/worksheets/"))
                    strings = "".join(xml.values())
                    kept = marker in strings
                    formulas = sheets.count("<f>") + sheets.count("<f ")
                    rtl = re.search(r'<(?:\w+:)?sheetView[^>]*rightToLeft="(?:1|true)"', sheets) is not None
                    g = kept and formulas >= 5 and (rtl or lang == "en")
                    print("template %s (%s) %s: template text kept=%s formulas=%d%s -> %s"
                          % (t["id"], lang, f, kept, formulas, ("  sheet right-to-left=%s" % rtl) if lang == "ar" else "",
                             "OK" if g else "WRONG"))
            except Exception as e:
                g = False; print("template %s (%s) %s: cannot read: %s" % (t["id"], lang, f, e))
            good &= g
    return good


def open_in(d):
    """Plan S11 (OpenInUITests.testOpenInCopyAndInPlace, the real UIDocument path): where the saved bytes landed.
    A copy from Mail / WhatsApp (the Inbox) is moved into the app's folder under its clean name - next to, never over,
    a file of that name - and holds every edit (also the one made after reopening it from Recent); nothing is left in
    the Inbox. A file opened in place from Files (here: Library/Application Support/Outside, copied by the workflow to
    _outside) holds its edit, and no copy of it appears in the app's folder. English and Arabic file names."""
    import unicodedata
    nfc = lambda s: unicodedata.normalize("NFC", s)
    good = True
    names = {nfc(f): f for f in os.listdir(d)}
    inbox = os.path.join(d, "Inbox")
    left = sorted(nfc(f) for f in os.listdir(inbox)) if os.path.isdir(inbox) else []
    def words_in(path, words):
        s = text(path)
        return [w in s for w in words], s
    # copies: (attachment name, where it must land, words, a file that was already there and must stay untouched)
    for src, dest, words, clash in (("Quarterly report.docx", "Quarterly report 2.docx", ("Kappa", "Rho"), "Quarterly report.docx"),
                                    ("تقرير الربع.docx", "تقرير الربع.docx", ("Lambda", "Tau"), None)):
        f = names.get(nfc(dest))
        if f is None:
            print("open-in copy %s: MISSING %s in the app's folder" % (src, dest)); good = False; continue
        try:
            has, s = words_in(os.path.join(d, f), words)
        except Exception as e:
            print("open-in copy %s: cannot read %s: %s" % (src, f, e)); good = False; continue
        still = nfc(src) in left
        g = all(has) and not still
        print("open-in copy %s -> %s: words %s=%s  inbox emptied=%s  text=%r -> %s"
              % (src, f, "/".join(words), has, not still, s[:100], "OK" if g else "WRONG"))
        good &= g
        if clash:
            c = names.get(nfc(clash))
            if c is None:
                print("  existing %s: GONE (replaced by the copy?) -> WRONG" % clash); good = False
            else:
                cs = text(os.path.join(d, c))
                untouched = not any(w in cs for w in words)
                print("  existing %s kept, not written: %s -> %s" % (clash, untouched, "OK" if untouched else "WRONG"))
                good &= untouched
    out = os.path.join(d, "_outside")
    outside = {nfc(f): f for f in os.listdir(out)} if os.path.isdir(out) else {}
    for name, word in (("Field notes.docx", "Mu"), ("ملاحظات الموقع.docx", "Nu")):
        f = outside.get(nfc(name))
        if f is None:
            print("open-in in place %s: MISSING (original outside the app's folder)" % name); good = False; continue
        s = text(os.path.join(out, f))
        base = nfc(os.path.splitext(name)[0])
        stray = [n for n in names if n.startswith(base)]
        g = word in s and not stray
        print("open-in in place %s: original edited=%s  copies in the app's folder=%s  text=%r -> %s"
              % (name, word in s, stray or "none", s[:100], "OK" if g else "WRONG"))
        good &= g
    return good


WINDOW_CHECKS = ("editor-ready", "layout-follows-window", "layout-rule", "live-narrow-class", "menu-sees-editor",
                 "cmd-b-on-once", "cmd-b-off-once", "cmd-i-on-once", "cmd-u-on-once", "cmd-b-types-nothing",
                 "menu-bold-once")
# the shipped editor path (testZZZZZMenuBarOnRealEditor: DocumentOpener -> EditorHost, as from Home), File > Close
REAL_MENU_CHECKS = ("real-editor-up", "real-menu-sees-editor", "real-menu-bold-on-once", "real-menu-bold-off-once",
                    "real-menu-close-returns", "real-menu-after-close")


def window_gate(d):
    """plan S6: the gate lines testZZZZWindowLayoutAndKeyCommands logged (xr-window.docx, and on the iPad also the
    narrow-window run xr-window-narrow.docx) and testZZZZZMenuBarOnRealEditor logged (xr-window-real.docx); every check
    must be PASS. A missing line = the test stopped early = fail. File > Close saved the real document: it holds the
    word typed before ("Menu"), followed only by bare "p"s of probe presses that lost their modifiers."""
    res = {}
    for f in sorted(os.listdir(d)):
        if f.startswith("xr-log-xr-window") and f.endswith(".txt"):
            log = open(os.path.join(d, f), encoding="utf-8", errors="replace").read()
            for m in re.finditer(r"^window-gate ([\w-]+): (PASS|FAIL|INFO)\s*(.*)$", log, re.M):
                res[m.group(1)] = (m.group(2), m.group(3))
    need = list(WINDOW_CHECKS) + list(REAL_MENU_CHECKS)
    if "layout1:regular" in res.get("layout-follows-window", ("", ""))[1]:   # the iPad: its narrow-window run too
        need.append("ipad-narrow-window-compact")
    good = True
    print("Window gate (plan S6):")
    for name in need + [k for k in res if k not in need]:
        st, why = res.get(name, ("NOT LOGGED", ""))
        print("  %-28s %-10s %s" % (name, st, why[:200]))
        if (name in need and st != "PASS") or st == "FAIL":
            good = False
    p = os.path.join(d, "xr-window-real.docx")
    try:
        s = text(p).strip() if os.path.exists(p) else "(missing)"
    except Exception as e:
        s = "(cannot read: %s)" % e
    saved = s.startswith("Menu") and set(s[4:]) <= {"p"}
    print("  %-28s %-10s %s" % ("real-close-saved", "PASS" if saved else "FAIL", "xr-window-real.docx text %r" % s[:120]))
    return good and saved


root = sys.argv[1]
def scan_quick(d):
    """plan S10 (ScanQuickActionUITests): the quick actions' new files are real files of the right format, and
    Scan's save path wrote a 2-page PDF named "Scan <date>" (EN) and "مسح <date>" (AR)."""
    import unicodedata
    good = True
    names = [unicodedata.normalize("NFC", f) for f in os.listdir(d)]
    real = {unicodedata.normalize("NFC", f): f for f in os.listdir(d)}
    for base, ext, part in (("Document", "docx", "word/document.xml"), ("Spreadsheet", "xlsx", "xl/workbook.xml"),
                            ("Presentation", "pptx", "ppt/presentation.xml"),
                            ("جدول بيانات", "xlsx", "xl/workbook.xml")):
        hits = [n for n in names if n.startswith(base) and n.endswith("." + ext)]
        fine = False
        for n in hits:
            try:
                fine |= part in zipfile.ZipFile(os.path.join(d, real[n])).namelist()
            except Exception:
                pass
        print("quick action new %s.%s: files=%s -> %s" % (base, ext, hits, "OK" if fine else "WRONG"))
        good &= fine
    for prefix in ("Scan 20", "مسح 20"):
        hits = [n for n in names if n.startswith(prefix) and n.endswith(".pdf")]
        pages = []
        for n in hits:
            try:
                from pypdf import PdfReader
                pages.append(len(PdfReader(os.path.join(d, real[n])).pages))
            except Exception as e:
                print("  %s: cannot read: %s" % (n, e)); pages.append(0)
        fine = bool(hits) and all(p == 2 for p in pages)
        print("scan to PDF %r: files=%s pages=%s -> %s" % (prefix, hits, pages, "OK" if fine else "WRONG"))
        good &= fine
    return good


ok = True
def text(p):
    z = zipfile.ZipFile(p)
    return re.sub(r"\s+", " ", "".join(re.findall(r"<w:t[^>]*>([^<]*)<", z.read("word/document.xml").decode("utf-8"))))
for dev in sorted(os.listdir(root)) if os.path.isdir(root) else []:
    d = os.path.join(root, dev)
    print("==", dev, sorted(os.listdir(d)))
    missing = set()
    for log in sorted(f for f in os.listdir(d) if f.startswith("xr-log")):
        print("--", log)
        lines = open(os.path.join(d, log), encoding="utf-8", errors="replace").readlines()
        print("".join(lines[-25:]))
        # engine contract (20.3 F0): the editors asked the shell for a member xr-host.js does not define
        missing |= set(m for l in lines for m in re.findall(r"missing AscDesktopEditor\.(\S+)", l))
    print("AscDesktopEditor members the editors asked for and xr-host.js lacks: %s"
          % (" ".join(sorted(missing)) + " -> WRONG (add them to xr-host.js)" if missing else "none -> OK"))
    ok &= not missing
    t = os.path.join(d, "xr-test.docx")
    if os.path.exists(t):
        s = text(t)
        # the exact text (a stray character, e.g. a Cmd+S typed as "s", fails); iOS Smart Punctuation turns "-" into
        # an en dash. The Arabic line is there only if the keyboard could type it.
        n = s.replace("–", "-").strip()
        en = n in ("Typed on iPhone - English OK.", "Typed on iPhone - English OK.كتابة عربية")
        ar = n == "Typed on iPhone - English OK.كتابة عربية"
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
    for lang in ("en", "ar"):                     # spreadsheet gate (plan S3)
        ok &= sheet_gate(d, lang)
    for lang in ("en", "ar"):                     # PDF tool bar (plan S7)
        ok &= pdf_bar(d, lang)
    ok &= pdf_form(d)                             # PDF form fields typed + saved visibly (21.0)
    for lang in ("en", "ar"):                     # paragraph direction follows the keyboard (plan C1)
        ok &= kbdir_gate(d, lang)
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
        # the File tab is hidden on touch (M7b: ⋯ > All tools opens the backstage), so Close Menu is the way back
        tab = re.findall(r"file tab shown: (\d)", log)
        good = not dead and ("fm-btn-download" in shown or "fm-btn-save-desktop" in shown) and "fm-btn-save" in shown \
            and "fm-btn-return" in shown and tab[-1:] == ["0"]
        print("File menu entries:", " ".join(shown), "| file tab shown:", tab[-1:] or "?",
              "-> %s" % ("OK" if good else "WRONG (no-op entries: %s; Close Menu and a hidden File tab required)" % dead))
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
    ok &= doc_menu(d)
    ok &= title_menu(d)
    ok &= files_gate(d)
    ok &= reading_view(d)
    ok &= gallery(d)
    ok &= scan_quick(d)
    ok &= open_in(d)
    ok &= window_gate(d)
if not (os.path.isdir(root) and os.listdir(root)):
    print("no saved files from any simulator"); ok = False


def run_notes(out):
    """Beside the verdict, what a green run does NOT show by itself: every skipped test case and every retried tap
    (INFO lines) per device, from the filtered test output the workflow keeps in out/ui-<device>.log. Informational:
    the strict checks above decide the RESULT."""
    import glob
    logs = sorted(glob.glob(os.path.join(out, "ui-*.log")))
    print("== Skipped tests and retried taps (informational)")
    if not logs:
        print("  no out/ui-<device>.log (the workflow keeps the filtered test output there)")
    for lg in logs:
        lines = open(lg, encoding="utf-8", errors="replace").read().splitlines()
        skipped = [re.sub(r"^.*Test Case '-\[XreroOfficeUITests\.", "", l).split("]")[0]
                   for l in lines if re.search(r"Test Case '.*' skipped", l)]
        retries = [l.strip() for l in lines if "first-tap-ignored: INFO" in l or "first-tap-missed: INFO" in l]
        infos = [l.strip() for l in lines if re.search(r"XR (springboard|crash)\b.*: INFO", l)]
        print("  %s: %d skipped, %d retried tap(s)" % (os.path.basename(lg), len(skipped), len(retries)))
        for t in skipped:
            print("    skipped:", t)
        for l in infos + retries:
            print("    ", l[l.find("XR "):] if "XR " in l else l)


run_notes(os.path.dirname(os.path.abspath(root)))
try:   # out/qa/touch-gate.json beside out/saved: the gate's results per device + language (published in the evidence)
    qd = os.path.join(os.path.dirname(os.path.abspath(root)), "qa")
    os.makedirs(qd, exist_ok=True)
    with open(os.path.join(qd, "touch-gate.json"), "w", encoding="utf-8") as f:
        json.dump(QA, f, ensure_ascii=False, indent=1)
except Exception as e:
    print("out/qa/touch-gate.json not written:", e)
print("RESULT", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
