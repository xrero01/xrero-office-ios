#!/usr/bin/env python3
"""make_reading_fixtures.py [--verify] - the multi-page files of the reading-view gate (plan S2).

Why: the reading view's page capsule ("3 / 12"), its Go to Page and scrolling can only be checked on a document that
has more than one page; the store letter (tests/ar_letter.docx / .pdf) has one, so every probe read "1/1" whatever the
app did (S2 review). EditorUITests.testReadingViewEditDoneThenType opens these instead:

  tests/reading_6p.docx  the store letter (page 1, kept byte for byte: check_saved.py still finds it) followed by five
                         more pages, each a paragraph with "page break before" and a few short Arabic + English lines, so
                         the engine lays out exactly 6 pages (none of them is near full, at any font fallback);
  tests/reading_6p.pdf   6 A4 pages written here from scratch (Helvetica, one of the PDF standard fonts: nothing is
                         embedded), "Page k of 6" in large type on each.

Output is reproducible (the letter's zip entries are copied with their own dates and order; the PDF has no dates), so
--verify regenerates both in memory and compares them with the committed files (the .docx part by part: another zlib
may compress the same part to other bytes)."""
import io, os, sys, zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
TESTS = os.path.join(ROOT, "tests")
PAGES = 6


def para(text, first=False, bold=False, rtl=True):
    """One paragraph: Arabic ones right-to-left (bidi), English ones left-to-right - not mixed in one line, where the
    bidi algorithm reorders "6 Page 2 of - 6 الصفحة 2 من" and the page reads as garbled (CI run 154 shot)."""
    ppr = '<w:pPr>%s%s</w:pPr>' % ('<w:pageBreakBefore/>' if first else '', '<w:bidi/>' if rtl else '')
    b = '<w:b/><w:bCs/><w:sz w:val="36"/><w:szCs w:val="36"/>' if bold else ''
    rpr = '<w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial"/>%s%s</w:rPr>' % (b, '<w:rtl/>' if rtl else '')
    return '<w:p>%s<w:r>%s<w:t xml:space="preserve">%s</w:t></w:r></w:p>' % (ppr, rpr, text)


def docx():
    src = zipfile.ZipFile(os.path.join(TESTS, "ar_letter.docx"))
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as z:
        for info in src.infolist():
            data = src.read(info.filename)
            if info.filename == "word/document.xml":
                s = data.decode("utf-8")
                pages = ""
                for k in range(2, PAGES + 1):
                    # "الصفحة k من 6", then the same in English (the digits are plain ASCII, never mirrored)
                    pages += para("\u0627\u0644\u0635\u0641\u062d\u0629 %d \u0645\u0646 %d" % (k, PAGES), first=True, bold=True)
                    pages += para("Page %d of %d" % (k, PAGES), bold=True, rtl=False)
                    for line in range(1, 5):
                        pages += para("\u0633\u0637\u0631 %d \u0641\u064a \u0627\u0644\u0635\u0641\u062d\u0629 %d" % (line, k))
                        pages += para("Line %d on page %d" % (line, k), rtl=False)
                at = s.rindex("<w:sectPr")                 # the body's own section properties stay last
                data = (s[:at] + pages + s[at:]).encode("utf-8")
            z.writestr(info, data)
    return out.getvalue()


def pdf():
    objs = []                                          # object bodies, numbered from 1

    def add(body):
        objs.append(body)
        return len(objs)

    font = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    pages_id = len(objs) + 1 + 2 * PAGES + 1           # the Pages tree goes after every page and its content
    kids = []
    for k in range(1, PAGES + 1):
        text = ("BT /F1 44 Tf 72 700 Td (Page %d of %d) Tj ET\n" % (k, PAGES) +
                "".join("BT /F1 16 Tf 72 %d Td (Xrero Office reading view - line %d on page %d) Tj ET\n" % (620 - 30 * i, i, k)
                        for i in range(1, 6))).encode("ascii")
        content = add(b"<< /Length %d >>\nstream\n" % len(text) + text + b"endstream")
        kids.append(add(b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 %d 0 R >> >> "
                        b"/Contents %d 0 R >>" % (pages_id, font, content)))
    add(b"<< /Type /Catalog /Pages %d 0 R >>" % pages_id)
    catalog = len(objs)
    assert add(b"<< /Type /Pages /Count %d /Kids [%s] >>" % (PAGES, b" ".join(b"%d 0 R" % i for i in kids))) == pages_id
    out = io.BytesIO()
    out.write(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, body in enumerate(objs, 1):
        offsets.append(out.tell())
        out.write(b"%d 0 obj\n" % i + body + b"\nendobj\n")
    xref = out.tell()
    out.write(b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1))
    for o in offsets:
        out.write(b"%010d 00000 n \n" % o)
    out.write(b"trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, catalog, xref))
    return out.getvalue()


def parts(data, name):
    if not name.endswith(".docx"):
        return data
    z = zipfile.ZipFile(io.BytesIO(data))
    return [(i.filename, z.read(i.filename)) for i in z.infolist()]


def main():
    files = {"reading_6p.docx": docx(), "reading_6p.pdf": pdf()}
    if "--verify" in sys.argv:
        bad = 0
        for name, data in files.items():
            p = os.path.join(TESTS, name)
            same = os.path.exists(p) and parts(open(p, "rb").read(), name) == parts(data, name)
            print("%s: %s" % (name, "the generated one" if same else "DIFFERS from the generator (run make_reading_fixtures.py)"))
            bad += not same
        return 1 if bad else 0
    for name, data in files.items():
        with open(os.path.join(TESTS, name), "wb") as f:
            f.write(data)
        print("wrote tests/%s (%d bytes)" % (name, len(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
