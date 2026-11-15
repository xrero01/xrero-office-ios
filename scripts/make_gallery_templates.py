#!/usr/bin/env python3
"""make_gallery_templates.py [--verify] - the template gallery (plan item S8): 5 UAE templates, each in English and
Arabic, written from scratch (no other vendor's template, no government emblem or authority name):

  letter   official letter   .docx   Gregorian date + Hijri date as editable placeholders
  invoice  tax invoice       .xlsx   UAE VAT 5 %, seller / customer TRN, live formulas, "template, not tax advice"
  cv       CV                .docx
  minutes  meeting minutes   .docx
  budget   monthly budget    .xlsx   planned / actual / difference with live formulas

Output: web/templates/en/gallery/<id>.<ext>, web/templates/ar/gallery/<id>.<ext> and web/templates/gallery.json (the
manifest TemplateGallery.swift reads: category, kind, EN / AR names, file, thumbnail layout). Fonts are bundled OFL
fonts only: Cairo for Arabic (and the Arabic files' Latin text), Open Sans for the English files. Arabic files are
right-to-left in their Normal style + document defaults (docx) or sheet view (xlsx), ar-AE.

Reproducible (fixed zip timestamps and part order): CI runs --verify, which rebuilds every file in memory, checks each
part is well-formed XML, checks the direction / font markers, and compares the parts with the committed files."""
import io, json, os, sys, zipfile
from xml.sax.saxutils import escape

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_blank_templates import XML, R_NS, W_NS, S_NS, rels, content_types, BASE_DEFAULTS, zip_bytes  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
TPL = os.path.join(ROOT, "web", "templates")
ACCENT = "0B6E7F"      # deep teal (Xrero family), headings and table headers
MUTED = "5F6B73"
LIGHT = "E8F1F3"       # header / band fill
LINE = "B8C4C9"


class Lang:
    def __init__(self, code):
        self.ar = code == "ar"
        self.code = code
        self.font = "Cairo" if self.ar else "Open Sans"
        self.cs = "Cairo"
        self.lang = "ar-AE" if self.ar else "en-GB"


# ================================================================ docx
def t(s):
    return escape(s)


class Doc:
    """a small WordprocessingML writer: paragraphs and simple tables, right-to-left when the language is Arabic"""

    def __init__(self, L):
        self.L = L
        self.body = []

    def run(self, text, b=False, i=False, size=None, color=None):
        rpr = ""
        if b:
            rpr += "<w:b/><w:bCs/>"
        if i:
            rpr += "<w:i/><w:iCs/>"
        if color:
            rpr += '<w:color w:val="%s"/>' % color
        if size:
            rpr += '<w:sz w:val="%d"/><w:szCs w:val="%d"/>' % (size, size)
        if self.L.ar:
            rpr += "<w:rtl/>"
        return '<w:r>%s<w:t xml:space="preserve">%s</w:t></w:r>' % ("<w:rPr>%s</w:rPr>" % rpr if rpr else "", t(text))

    def ppr(self, style=None, jc=None, after=None, before=None, border=None, keep=False, shade=None):
        p = ""
        if style:
            p += '<w:pStyle w:val="%s"/>' % style
        if keep:
            p += "<w:keepNext/>"
        if border:
            p += ('<w:pBdr><w:bottom w:val="single" w:sz="%d" w:space="4" w:color="%s"/></w:pBdr>' % border)
        if shade:
            p += '<w:shd w:val="clear" w:color="auto" w:fill="%s"/>' % shade
        if before is not None or after is not None:
            p += '<w:spacing%s%s/>' % (' w:before="%d"' % before if before is not None else "",
                                       ' w:after="%d"' % after if after is not None else "")
        if self.L.ar:
            p += "<w:bidi/>"
        if jc:   # logical: "start" / "end" (a right-to-left paragraph mirrors them)
            p += '<w:jc w:val="%s"/>' % {"start": "left", "end": "right", "center": "center"}[jc] if not self.L.ar else \
                 '<w:jc w:val="%s"/>' % {"start": "right", "end": "left", "center": "center"}[jc]
        return "<w:pPr>%s</w:pPr>" % p

    def p(self, *runs, **kw):
        rs = "".join(r if r.startswith("<w:r>") else self.run(r) for r in runs)
        self.body.append("<w:p>%s%s</w:p>" % (self.ppr(**kw), rs))

    def cell(self, content, w, fill=None, bold=False, color=None, size=None):
        tc = '<w:tcW w:w="%d" w:type="dxa"/>' % w
        if fill:
            tc += '<w:shd w:val="clear" w:color="auto" w:fill="%s"/>' % fill
        tc += '<w:vAlign w:val="center"/>'
        paras = content if isinstance(content, list) else [content]
        ps = "".join("<w:p>%s%s</w:p>" % (self.ppr(after=40, before=40), self.run(x, b=bold, color=color, size=size))
                     for x in paras)
        return "<w:tc><w:tcPr>%s</w:tcPr>%s</w:tc>" % (tc, ps)

    def table(self, widths, rows, header=True, label_col=False):
        """rows: [[text|list, ...]]; the first row is the header (accent fill, white bold) when header=True;
        label_col: the first column is a light-filled bold label (key / value tables)"""
        b = "".join('<w:%s w:val="single" w:sz="4" w:space="0" w:color="%s"/>' % (s, LINE)
                    for s in ("top", "left", "bottom", "right", "insideH", "insideV"))
        tblpr = ('<w:tblPr><w:tblW w:w="%d" w:type="dxa"/>%s<w:tblBorders>%s</w:tblBorders>'
                 '<w:tblLayout w:type="fixed"/><w:tblCellMar><w:left w:w="100" w:type="dxa"/>'
                 '<w:right w:w="100" w:type="dxa"/></w:tblCellMar><w:tblLook w:val="04A0"/></w:tblPr>'
                 ) % (sum(widths), "<w:bidiVisual/>" if self.L.ar else "", b)
        grid = "<w:tblGrid>%s</w:tblGrid>" % "".join('<w:gridCol w:w="%d"/>' % w for w in widths)
        trs = []
        for r, row in enumerate(rows):
            cells = []
            for c, (x, w) in enumerate(zip(row, widths)):
                if header and r == 0:
                    cells.append(self.cell(x, w, fill=ACCENT, bold=True, color="FFFFFF", size=20))
                elif label_col and c == 0:
                    cells.append(self.cell(x, w, fill=LIGHT, bold=True, size=20))
                else:
                    cells.append(self.cell(x, w, size=20))
            trh = "<w:trPr><w:tblHeader/></w:trPr>" if header and r == 0 else ""
            trs.append("<w:tr>%s%s</w:tr>" % (trh, "".join(cells)))
        self.body.append("<w:tbl>%s%s%s</w:tbl>" % (tblpr, grid, "".join(trs)))
        self.p("", after=0)

    def heading(self, text):
        self.p(self.run(text), style="Heading1", keep=True)

    def bytes(self):
        L = self.L
        fonts = '<w:rFonts w:ascii="{0}" w:hAnsi="{0}" w:eastAsia="{0}" w:cs="{1}"/>'.format(L.font, L.cs)
        lang = '<w:lang w:val="{0}" w:eastAsia="{0}" w:bidi="{1}"/>'.format(L.lang, "ar-AE")
        bidi = "<w:bidi/>" if L.ar else ""

        def style(sid, name, size, color=None, after=120, before=0, bold=True, outline=None, border=None):
            o = '<w:outlineLvl w:val="%d"/>' % outline if outline is not None else ""
            c = '<w:color w:val="%s"/>' % color if color else ""
            bd = ('<w:pBdr><w:bottom w:val="single" w:sz="%d" w:space="2" w:color="%s"/></w:pBdr>' % border
                  if border else "")
            return ('<w:style w:type="paragraph" w:styleId="{0}"><w:name w:val="{1}"/><w:basedOn w:val="Normal"/>'
                    '<w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/><w:pPr><w:keepNext/>{8}'
                    '<w:spacing w:before="{5}" w:after="{4}"/>{7}{6}</w:pPr><w:rPr>{9}{2}<w:sz w:val="{3}"/>'
                    '<w:szCs w:val="{3}"/></w:rPr></w:style>').format(
                        sid, name, c, size, after, before, o, bidi, bd, "<w:b/><w:bCs/>" if bold else "")

        styles = (XML + '<w:styles xmlns:w="%s">' % W_NS +
                  '<w:docDefaults><w:rPrDefault><w:rPr>' + fonts + '<w:color w:val="1F2A30"/><w:sz w:val="21"/>'
                  '<w:szCs w:val="21"/>' + lang + '</w:rPr></w:rPrDefault><w:pPrDefault><w:pPr>' + bidi +
                  '<w:spacing w:after="100" w:line="288" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
                  '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/>'
                  '<w:pPr>' + bidi + '</w:pPr><w:rPr>' + fonts + lang + '</w:rPr></w:style>'
                  '<w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont">'
                  '<w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/>'
                  '<w:unhideWhenUsed/></w:style>'
                  '<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/>'
                  '<w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/><w:tblPr>' +
                  ("<w:bidiVisual/>" if L.ar else "") +
                  '<w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/>'
                  '<w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/>'
                  '</w:tblCellMar></w:tblPr></w:style>'
                  '<w:style w:type="numbering" w:default="1" w:styleId="NoList"><w:name w:val="No List"/>'
                  '<w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/></w:style>'
                  + style("Title", "Title", 40, ACCENT, after=60)
                  + style("Subtitle", "Subtitle", 24, MUTED, after=160, bold=False)
                  + style("Heading1", "heading 1", 24, ACCENT, after=80, before=240, outline=0, border=(6, LINE))
                  + style("Heading2", "heading 2", 22, None, after=40, before=160, outline=1)
                  + '</w:styles>')
        document = (XML + '<w:document xmlns:w="%s" xmlns:r="%s"><w:body>' % (W_NS, R_NS) + "".join(self.body) +
                    # A4 (UAE)
                    '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" '
                    'w:left="1134" w:header="567" w:footer="567" w:gutter="0"/><w:cols w:space="720"/>' +
                    ("<w:bidi/><w:rtlGutter/>" if L.ar else "") +
                    '<w:docGrid w:linePitch="360"/></w:sectPr></w:body></w:document>')
        settings = (XML + '<w:settings xmlns:w="%s"><w:defaultTabStop w:val="720"/>' % W_NS +
                    '<w:characterSpacingControl w:val="doNotCompress"/>'
                    '<w:themeFontLang w:val="%s" w:bidi="ar-AE"/>' % L.lang +
                    '<w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word"'
                    ' w:val="15"/></w:compat></w:settings>')
        font_table = (XML + '<w:fonts xmlns:w="%s">' % W_NS + "".join(
            '<w:font w:name="%s"><w:charset w:val="%s"/><w:family w:val="auto"/><w:pitch w:val="variable"/></w:font>'
            % (f, "B2" if f == "Cairo" else "00") for f in sorted({L.font, L.cs})) + '</w:fonts>')
        wml = "application/vnd.openxmlformats-officedocument.wordprocessingml."
        return zip_bytes([
            ("[Content_Types].xml", content_types(BASE_DEFAULTS, [
                ("/word/document.xml", wml + "document.main+xml"), ("/word/styles.xml", wml + "styles+xml"),
                ("/word/settings.xml", wml + "settings+xml"), ("/word/fontTable.xml", wml + "fontTable+xml")])),
            ("_rels/.rels", rels([("rId1", "officeDocument", "word/document.xml")])),
            ("word/_rels/document.xml.rels", rels([("rId1", "styles", "styles.xml"), ("rId2", "settings", "settings.xml"),
                                                   ("rId3", "fontTable", "fontTable.xml")])),
            ("word/document.xml", document), ("word/styles.xml", styles), ("word/settings.xml", settings),
            ("word/fontTable.xml", font_table)])


FULL = 9638      # A4 text width in twips (11906 - 2 x 1134)


def letter(L):
    d = Doc(L)
    if L.ar:
        d.p(d.run("[اسم الشركة]", b=True, size=34, color=ACCENT), after=20)
        d.p(d.run("[الشارع، المنطقة] · [المدينة]، الإمارات العربية المتحدة · هاتف [+971 0 000 0000] · [البريد الإلكتروني]",
                  size=17, color=MUTED), border=(8, ACCENT), after=240)
        d.p(d.run("الرقم: ", b=True), "[المرجع]", jc="start", after=20)
        d.p(d.run("التاريخ: ", b=True), "[  /  /  20م] الموافق [  /  /  14هـ]", after=280)
        d.p(d.run("السيد/ة: ", b=True), "[اسم المرسل إليه]  المحترم/ة", after=20)
        d.p("[المسمى الوظيفي]", after=20)
        d.p("[اسم الجهة]", after=20)
        d.p("[المدينة]، الإمارات العربية المتحدة", after=280)
        d.p(d.run("الموضوع: ", b=True), d.run("[موضوع الخطاب]", b=True), after=240)
        d.p("تحية طيبة وبعد،", after=160)
        d.p("نتقدم إليكم بهذا الخطاب بخصوص [اذكر الغرض من الخطاب في جملة واحدة]. "
            "[أضف الخلفية التي يحتاجها القارئ: التواريخ وأرقام المراجع وما تم حتى الآن.]", jc=None)
        d.p("[اذكر بوضوح ما تطلبونه أو تؤكدونه والموعد المطلوب.] "
            "وللاستفسار يُرجى التواصل مع [الاسم] على الرقم [الهاتف] أو عبر البريد [البريد الإلكتروني].")
        d.p("وتفضلوا بقبول فائق الاحترام والتقدير،", before=200, after=600)
        d.p(d.run("[الاسم الكامل]", b=True), after=20)
        d.p("[المسمى الوظيفي]", after=20)
        d.p("[اسم الشركة]", after=360)
        d.p(d.run("[ختم الشركة]", size=17, color=MUTED))
    else:
        d.p(d.run("[Company Name]", b=True, size=34, color=ACCENT), after=20)
        d.p(d.run("[Street, Area] · [City], United Arab Emirates · Tel [+971 0 000 0000] · [email address]",
                  size=17, color=MUTED), border=(8, ACCENT), after=240)
        d.p(d.run("Ref: ", b=True), "[Reference]", after=20)
        d.p(d.run("Date: ", b=True), "[DD Month YYYY], corresponding to [DD Month 14YY AH]", after=280)
        d.p("[Recipient name]", after=20)
        d.p("[Job title]", after=20)
        d.p("[Organisation]", after=20)
        d.p("[City], United Arab Emirates", after=280)
        d.p(d.run("Subject: ", b=True), d.run("[Subject of the letter]", b=True), after=240)
        d.p("Dear [Mr / Ms Surname],", after=160)
        d.p("We are writing to you regarding [state the purpose of the letter in one sentence]. "
            "[Add the background the reader needs: dates, reference numbers and what has happened so far.]")
        d.p("[Say clearly what you are asking for or confirming, and by when.] Please contact [name] on [phone] "
            "or at [email address] if you need any further information.")
        d.p("Yours sincerely,", before=200, after=600)
        d.p(d.run("[Full name]", b=True), after=20)
        d.p("[Job title]", after=20)
        d.p("[Company Name]", after=360)
        d.p(d.run("[Company stamp]", size=17, color=MUTED))
    return d.bytes()


def cv(L):
    d = Doc(L)
    side, main = 3000, FULL - 3000
    if L.ar:
        d.p(d.run("[الاسم الكامل]", b=True, size=44, color=ACCENT), after=20)
        d.p(d.run("[المسمى الوظيفي المطلوب]", size=24, color=MUTED), border=(8, ACCENT), after=120)
        d.p(d.run("[+971 50 000 0000] · [البريد الإلكتروني] · [المدينة]، الإمارات · [رابط الملف المهني]", size=18),
            after=120)
        d.heading("نبذة مهنية")
        d.p("[ثلاثة أسطر عنك: سنوات الخبرة، مجالك، وأهم ما يمكنك تقديمه لصاحب العمل. مثال: محاسب بخبرة 6 سنوات "
            "في الشركات التجارية بالإمارات، متخصص في ضريبة القيمة المضافة والتقارير الشهرية.]")
        d.heading("الخبرة العملية")
        for n in (1, 2):
            d.p(d.run("[المسمى الوظيفي] — [اسم الشركة]، [المدينة]", b=True), after=0, keep=True)
            d.p(d.run("[الشهر السنة] – %s" % ("حتى الآن" if n == 1 else "[الشهر السنة]"), size=18, color=MUTED), after=60)
            d.p("•  [إنجاز بأرقام، مثال: خفّضت وقت إقفال الحسابات الشهرية من 10 أيام إلى 5 أيام]", after=20)
            d.p("•  [مسؤولية رئيسية أو مشروع مهم]", after=120)
        d.heading("التعليم")
        d.p(d.run("[الشهادة والتخصص] — [اسم الجامعة أو المعهد]", b=True), after=0)
        d.p(d.run("[سنة التخرج] · [التقدير إن وجد]", size=18, color=MUTED))
        d.heading("المهارات")
        d.table([side, main], [["المهارات المهنية", "[مثال: إعداد الإقرارات الضريبية، التقارير المالية، الميزانيات]"],
                               ["الحاسوب", "[مثال: جداول البيانات، أنظمة المحاسبة، العروض التقديمية]"],
                               ["الشهادات", "[اسم الشهادة المهنية، السنة]"]], header=False, label_col=True)
        d.heading("اللغات")
        d.p("العربية: [اللغة الأم] · الإنجليزية: [ممتاز / جيد جداً / جيد]")
        d.heading("بيانات شخصية")
        d.table([side, main], [["الجنسية", "[الجنسية]"], ["حالة الإقامة", "[مقيم / إقامة عمل / زيارة]"],
                               ["رخصة القيادة", "[إماراتية / لا يوجد]"], ["الإشعار", "[متاح فوراً / شهر واحد]"]],
                header=False, label_col=True)
    else:
        d.p(d.run("[Your Full Name]", b=True, size=44, color=ACCENT), after=20)
        d.p(d.run("[Job title you are applying for]", size=24, color=MUTED), border=(8, ACCENT), after=120)
        d.p(d.run("[+971 50 000 0000] · [email address] · [City], UAE · [profile or portfolio link]", size=18), after=120)
        d.heading("Profile")
        d.p("[Three lines about you: years of experience, your field, and what you bring to an employer. For example: "
            "accountant with 6 years in UAE trading companies, focused on VAT returns and monthly reporting.]")
        d.heading("Work experience")
        for n in (1, 2):
            d.p(d.run("[Job title] — [Company name], [City]", b=True), after=0, keep=True)
            d.p(d.run("[Month YYYY] – %s" % ("Present" if n == 1 else "[Month YYYY]"), size=18, color=MUTED), after=60)
            d.p("•  [An achievement with a number, e.g. cut the monthly close from 10 days to 5]", after=20)
            d.p("•  [A main responsibility or a key project]", after=120)
        d.heading("Education")
        d.p(d.run("[Degree and subject] — [University or institute]", b=True), after=0)
        d.p(d.run("[Year of graduation] · [Grade, if any]", size=18, color=MUTED))
        d.heading("Skills")
        d.table([side, main], [["Professional", "[e.g. VAT returns, financial reporting, budgeting]"],
                               ["Computer", "[e.g. spreadsheets, accounting systems, presentations]"],
                               ["Certificates", "[Professional certificate, year]"]], header=False, label_col=True)
        d.heading("Languages")
        d.p("English: [Fluent / Very good / Good] · Arabic: [Native / Very good / Good]")
        d.heading("Personal details")
        d.table([side, main], [["Nationality", "[Nationality]"], ["Visa status", "[Resident / Employment / Visit]"],
                               ["Driving licence", "[UAE / None]"], ["Notice period", "[Immediate / One month]"]],
                header=False, label_col=True)
    return d.bytes()


def minutes(L):
    d = Doc(L)
    k, v = 2600, FULL - 2600
    if L.ar:
        d.p(d.run("محضر اجتماع", b=True, size=40, color=ACCENT), after=20)
        d.p(d.run("[اسم الاجتماع أو اللجنة]", size=24, color=MUTED), border=(8, ACCENT), after=200)
        d.table([k, v], [["التاريخ", "[  /  /  20م] الموافق [  /  /  14هـ]"], ["الوقت", "[من 10:00 إلى 11:00]"],
                         ["المكان", "[قاعة الاجتماعات / اجتماع عن بعد]"], ["رئيس الاجتماع", "[الاسم]"],
                         ["كاتب المحضر", "[الاسم]"]], header=False, label_col=True)
        d.p(d.run("الحضور: ", b=True), "[الاسم، الاسم، الاسم]", after=20)
        d.p(d.run("المعتذرون: ", b=True), "[الاسم]")
        d.heading("جدول الأعمال")
        for n in (1, 2, 3):
            d.p("%d. [بند جدول الأعمال]" % n, after=20)
        d.heading("المناقشات والقرارات")
        for n in (1, 2):
            d.p(d.run("%d. [بند جدول الأعمال]" % n), style="Heading2")
            d.p("[ملخص المناقشة في سطرين أو ثلاثة.]", after=40)
            d.p(d.run("القرار: ", b=True), "[ما تم الاتفاق عليه]")
        d.heading("المهام المطلوبة")
        d.table([600, 5000, 2000, 2038], [["#", "المهمة", "المسؤول", "الموعد"],
                                          ["1", "[المهمة]", "[الاسم]", "[  /  /  ]"],
                                          ["2", "[المهمة]", "[الاسم]", "[  /  /  ]"],
                                          ["3", "[المهمة]", "[الاسم]", "[  /  /  ]"]])
        d.p(d.run("الاجتماع القادم: ", b=True), "[التاريخ والوقت والمكان]", after=360)
        d.p(d.run("اعتماد رئيس الاجتماع: ", b=True), "[الاسم]      التوقيع: ________      التاريخ: [  /  /  ]")
    else:
        d.p(d.run("Meeting minutes", b=True, size=40, color=ACCENT), after=20)
        d.p(d.run("[Meeting or committee name]", size=24, color=MUTED), border=(8, ACCENT), after=200)
        d.table([k, v], [["Date", "[DD Month YYYY]"], ["Time", "[10:00 – 11:00]"],
                         ["Location", "[Meeting room / online]"], ["Chair", "[Name]"],
                         ["Minutes taken by", "[Name]"]], header=False, label_col=True)
        d.p(d.run("Attendees: ", b=True), "[Name, Name, Name]", after=20)
        d.p(d.run("Apologies: ", b=True), "[Name]")
        d.heading("Agenda")
        for n in (1, 2, 3):
            d.p("%d. [Agenda item]" % n, after=20)
        d.heading("Discussion and decisions")
        for n in (1, 2):
            d.p(d.run("%d. [Agenda item]" % n), style="Heading2")
            d.p("[A two- or three-line summary of the discussion.]", after=40)
            d.p(d.run("Decision: ", b=True), "[What was agreed]")
        d.heading("Action items")
        d.table([600, 5000, 2000, 2038], [["#", "Action", "Owner", "Due date"],
                                          ["1", "[Action]", "[Name]", "[DD/MM/YYYY]"],
                                          ["2", "[Action]", "[Name]", "[DD/MM/YYYY]"],
                                          ["3", "[Action]", "[Name]", "[DD/MM/YYYY]"]])
        d.p(d.run("Next meeting: ", b=True), "[Date, time and location]", after=360)
        d.p(d.run("Approved by the chair: ", b=True), "[Name]      Signature: ________      Date: [DD/MM/YYYY]")
    return d.bytes()


# ================================================================ xlsx
def col(n):
    s = ""
    while n:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


# cell styles (cellXfs index): the same table for both workbooks
#  0 default   1 title   2 bold   3 header (white on accent, border)   4 number border   5 text border
#  6 note (italic muted)   7 total (bold number, light fill, border)   8 centred border   9 muted label
#  10 total label (bold, light fill, border)   11 input number (border, light yellow)   12 subtitle (muted, 12 pt)
def xlsx_styles(L):
    f = L.font
    fonts = [
        '<font><sz val="11"/><color rgb="FF1F2A30"/><name val="%s"/><family val="2"/>%s</font>',
        '<font><b/><sz val="20"/><color rgb="FF%s"/><name val="%%s"/><family val="2"/>%%s</font>' % ACCENT,
        '<font><b/><sz val="11"/><color rgb="FF1F2A30"/><name val="%s"/><family val="2"/>%s</font>',
        '<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="%s"/><family val="2"/>%s</font>',
        '<font><i/><sz val="9"/><color rgb="FF%s"/><name val="%%s"/><family val="2"/>%%s</font>' % MUTED,
        '<font><sz val="12"/><color rgb="FF%s"/><name val="%%s"/><family val="2"/>%%s</font>' % MUTED,
    ]
    cs = '<charset val="178"/>' if L.ar else ""
    fonts = "".join(x % (f, cs) for x in fonts)
    fills = ('<fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
             '<fill><patternFill patternType="solid"><fgColor rgb="FF%s"/><bgColor indexed="64"/></patternFill></fill>'
             '<fill><patternFill patternType="solid"><fgColor rgb="FF%s"/><bgColor indexed="64"/></patternFill></fill>'
             '<fill><patternFill patternType="solid"><fgColor rgb="FFFFFBEA"/><bgColor indexed="64"/></patternFill></fill>'
             ) % (ACCENT, LIGHT)
    side = '<%s style="thin"><color rgb="FF%s"/></%s>'
    borders = ('<border><left/><right/><top/><bottom/><diagonal/></border>'
               '<border>%s%s%s%s<diagonal/></border>' % tuple(side % (s, LINE, s) for s in ("left", "right", "top", "bottom")))
    al = '<alignment horizontal="%s" vertical="center"%s/>'
    start = "right" if L.ar else "left"
    xfs = [
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>',
        '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>',
        '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>',
        '<xf numFmtId="0" fontId="3" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" '
        'applyAlignment="1">%s</xf>' % (al % ("center", ' wrapText="1"')),
        '<xf numFmtId="4" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1"/>',
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1">%s</xf>'
        % (al % (start, "")),
        '<xf numFmtId="0" fontId="4" fillId="0" borderId="0" xfId="0" applyFont="1"/>',
        '<xf numFmtId="4" fontId="2" fillId="3" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" '
        'applyBorder="1"/>',
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1">%s</xf>'
        % (al % ("center", "")),
        '<xf numFmtId="0" fontId="5" fillId="0" borderId="0" xfId="0" applyFont="1"/>',
        '<xf numFmtId="0" fontId="2" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" '
        'applyAlignment="1">%s</xf>' % (al % (start, "")),
        '<xf numFmtId="4" fontId="0" fillId="4" borderId="1" xfId="0" applyNumberFormat="1" applyFill="1" applyBorder="1"/>',
        '<xf numFmtId="0" fontId="5" fillId="0" borderId="0" xfId="0" applyFont="1"/>',
    ]
    return (XML + '<styleSheet xmlns="%s">' % S_NS +
            '<fonts count="6">%s</fonts><fills count="5">%s</fills><borders count="2">%s</borders>' % (fonts, fills, borders) +
            '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
            '<cellXfs count="%d">%s</cellXfs>' % (len(xfs), "".join(xfs)) +
            '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
            '<dxfs count="0"/><tableStyles count="0"/></styleSheet>')


def workbook(L, sheet_name, cells, widths, merges=(), rows_h=None):
    """cells: {(row, col): (value, style)}; value: str (inline text), number, or '=FORMULA'"""
    rows = {}
    for (r, c), v in cells.items():
        rows.setdefault(r, []).append((c, v))
    out = []
    for r in sorted(rows):
        cs = []
        for c, (v, s) in sorted(rows[r]):
            ref = "%s%d" % (col(c), r)
            if isinstance(v, str) and v.startswith("="):
                cs.append('<c r="%s" s="%d"><f>%s</f></c>' % (ref, s, escape(v[1:])))
            elif isinstance(v, (int, float)):
                cs.append('<c r="%s" s="%d"><v>%s</v></c>' % (ref, s, v))
            elif v == "" or v is None:
                cs.append('<c r="%s" s="%d"/>' % (ref, s))
            else:
                cs.append('<c r="%s" s="%d" t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>' % (ref, s, escape(v)))
        ht = ' ht="%d" customHeight="1"' % rows_h[r] if rows_h and r in rows_h else ""
        out.append('<row r="%d"%s>%s</row>' % (r, ht, "".join(cs)))
    last = "%s%d" % (col(max(c for _, c in cells)), max(r for r, _ in cells))
    cols = "".join('<col min="%d" max="%d" width="%s" customWidth="1"/>' % (i + 1, i + 1, w) for i, w in enumerate(widths))
    mg = ('<mergeCells count="%d">%s</mergeCells>' % (len(merges), "".join('<mergeCell ref="%s"/>' % m for m in merges))
          if merges else "")
    sheet = (XML + '<worksheet xmlns="%s" xmlns:r="%s"><dimension ref="A1:%s"/>' % (S_NS, R_NS, last) +
             '<sheetViews><sheetView %stabSelected="1" showGridLines="0" workbookViewId="0"/></sheetViews>'
             % ('rightToLeft="1" ' if L.ar else "") +
             '<sheetFormatPr defaultRowHeight="18"/><cols>%s</cols><sheetData>%s</sheetData>%s' % (cols, "".join(out), mg) +
             '<pageMargins left="0.5" right="0.5" top="0.6" bottom="0.6" header="0.3" footer="0.3"/>'
             '<pageSetup paperSize="9" orientation="portrait" fitToHeight="0"/></worksheet>')
    wb = (XML + '<workbook xmlns="%s" xmlns:r="%s"><bookViews><workbookView/></bookViews>' % (S_NS, R_NS) +
          '<sheets><sheet name="%s" sheetId="1" r:id="rId1"/></sheets><calcPr calcId="191029" fullCalcOnLoad="1"/>'
          '</workbook>' % escape(sheet_name))
    sml = "application/vnd.openxmlformats-officedocument.spreadsheetml."
    return zip_bytes([
        ("[Content_Types].xml", content_types(BASE_DEFAULTS, [
            ("/xl/workbook.xml", sml + "sheet.main+xml"), ("/xl/worksheets/sheet1.xml", sml + "worksheet+xml"),
            ("/xl/styles.xml", sml + "styles+xml")])),
        ("_rels/.rels", rels([("rId1", "officeDocument", "xl/workbook.xml")])),
        ("xl/_rels/workbook.xml.rels", rels([("rId1", "worksheet", "worksheets/sheet1.xml"), ("rId2", "styles", "styles.xml")])),
        ("xl/workbook.xml", wb), ("xl/worksheets/sheet1.xml", sheet), ("xl/styles.xml", xlsx_styles(L))])


def invoice(L):
    a = L.ar
    T = {  # (EN, AR)
        "title": ("TAX INVOICE", "فاتورة ضريبية"),
        "seller": ("[Seller company name]", "[اسم الشركة البائعة]"),
        "addr": ("[Address], United Arab Emirates", "[العنوان]، الإمارات العربية المتحدة"),
        "trn": ("TRN: [15-digit tax registration number]", "رقم التسجيل الضريبي: [15 رقماً]"),
        "no": ("Invoice no.", "رقم الفاتورة"), "date": ("Invoice date", "تاريخ الفاتورة"),
        "supply": ("Date of supply", "تاريخ التوريد"), "due": ("Due date", "تاريخ الاستحقاق"),
        "billto": ("Bill to", "فاتورة إلى"), "cust": ("[Customer name]", "[اسم العميل]"),
        "caddr": ("[Customer address]", "[عنوان العميل]"),
        "ctrn": ("Customer TRN: [if registered]", "الرقم الضريبي للعميل: [إن وجد]"),
        "h": (["#", "Description", "Qty", "Unit price (AED)", "Amount excl. VAT", "VAT 5%", "Total (AED)"],
              ["#", "الوصف", "الكمية", "سعر الوحدة (درهم)", "المبلغ قبل الضريبة", "الضريبة 5%", "الإجمالي (درهم)"]),
        "item": ("[Item or service]", "[السلعة أو الخدمة]"),
        "sub": ("Total excl. VAT", "الإجمالي قبل الضريبة"), "vat": ("VAT (5%)", "ضريبة القيمة المضافة (5%)"),
        "tot": ("Total incl. VAT (AED)", "الإجمالي شامل الضريبة (درهم)"),
        "words": ("Amount in words: [ ]", "المبلغ كتابةً: [ ]"),
        "pay": ("Payment: [Bank name] · IBAN [AE00 0000 0000 0000 0000 000] · [Account name]",
                "الدفع: [اسم البنك] · رقم الآيبان [AE00 0000 0000 0000 0000 000] · [اسم الحساب]"),
        "note": ("Template only, not tax advice. Check the current UAE VAT rules for tax invoices before use.",
                 "هذا قالب فقط وليس استشارة ضريبية. راجع متطلبات الفاتورة الضريبية الحالية في الإمارات قبل الاستخدام."),
        "sheet": ("Invoice", "فاتورة"),
    }
    g = lambda k: T[k][1 if a else 0]
    c = {}
    c[(1, 1)] = (g("title"), 1)
    c[(3, 1)] = (g("seller"), 2); c[(4, 1)] = (g("addr"), 0); c[(5, 1)] = (g("trn"), 2)
    for r, k, v in ((3, "no", "[INV-0001]"), (4, "date", "[DD/MM/YYYY]"), (5, "supply", "[DD/MM/YYYY]"),
                    (6, "due", "[DD/MM/YYYY]")):
        c[(r, 5)] = (g(k), 10); c[(r, 6)] = ("", 5); c[(r, 7)] = (v, 5)
    c[(8, 1)] = (g("billto"), 2); c[(9, 1)] = (g("cust"), 0); c[(10, 1)] = (g("caddr"), 0); c[(11, 1)] = (g("ctrn"), 0)
    for i, h in enumerate(g("h")):
        c[(13, i + 1)] = (h, 3)
    first, last = 14, 19
    for r in range(first, last + 1):
        n = r - first + 1
        c[(r, 1)] = (n, 8)
        c[(r, 2)] = (g("item") if n == 1 else "", 5)
        c[(r, 3)] = (1 if n == 1 else "", 11)
        c[(r, 4)] = ("", 11)
        c[(r, 5)] = ("=IF(C%d*D%d=0,\"\",C%d*D%d)" % (r, r, r, r), 4)
        c[(r, 6)] = ("=IF(E%d=\"\",\"\",ROUND(E%d*0.05,2))" % (r, r), 4)
        c[(r, 7)] = ("=IF(E%d=\"\",\"\",E%d+F%d)" % (r, r, r), 4)
    s = last + 2
    c[(s, 5)] = (g("sub"), 10); c[(s, 6)] = ("", 10); c[(s, 7)] = ("=SUM(E%d:E%d)" % (first, last), 7)
    c[(s + 1, 5)] = (g("vat"), 10); c[(s + 1, 6)] = ("", 10); c[(s + 1, 7)] = ("=SUM(F%d:F%d)" % (first, last), 7)
    c[(s + 2, 5)] = (g("tot"), 10); c[(s + 2, 6)] = ("", 10); c[(s + 2, 7)] = ("=G%d+G%d" % (s, s + 1), 7)
    c[(s + 4, 1)] = (g("words"), 0)
    c[(s + 5, 1)] = (g("pay"), 0)
    c[(s + 7, 1)] = (g("note"), 6)
    merges = ["E%d:F%d" % (r, r) for r in (3, 4, 5, 6, s, s + 1, s + 2)]
    return workbook(L, g("sheet"), c, [5, 34, 8, 15, 16, 13, 16], merges, {1: 34, 13: 34})


def budget(L):
    a = L.ar
    T = {
        "title": ("Monthly budget", "الميزانية الشهرية"),
        "month": ("Month: [Month YYYY] · All amounts in AED", "الشهر: [الشهر السنة] · جميع المبالغ بالدرهم"),
        "h": (["Item", "Planned", "Actual", "Difference"], ["البند", "المخطط", "الفعلي", "الفرق"]),
        "inc": ("Income", "الدخل"),
        "incs": (["Salary", "Other income"], ["الراتب", "دخل آخر"]),
        "tinc": ("Total income", "إجمالي الدخل"),
        "exp": ("Expenses", "المصروفات"),
        "exps": (["Rent / housing", "Electricity and water", "Internet and mobile", "Groceries", "Transport and fuel",
                  "School fees", "Insurance", "Health", "Eating out", "Family support", "Other"],
                 ["الإيجار / السكن", "الكهرباء والماء", "الإنترنت والهاتف", "البقالة", "المواصلات والوقود",
                  "الرسوم المدرسية", "التأمين", "الصحة", "المطاعم", "دعم الأسرة", "أخرى"]),
        "texp": ("Total expenses", "إجمالي المصروفات"),
        "net": ("Left after expenses (income − expenses)", "المتبقي بعد المصروفات (الدخل − المصروفات)"),
        "save": ("Savings goal this month", "هدف الادخار هذا الشهر"),
        "tip": ("Type your amounts in the yellow cells; totals and differences update by themselves.",
                "اكتب المبالغ في الخلايا الصفراء، وتُحسب الإجماليات والفروق تلقائياً."),
        "sheet": ("Budget", "الميزانية"),
    }
    g = lambda k: T[k][1 if a else 0]
    c = {(1, 1): (g("title"), 1), (2, 1): (g("month"), 12)}
    for i, h in enumerate(g("h")):
        c[(4, i + 1)] = (h, 3)
    r = 5
    c[(r, 1)] = (g("inc"), 10); c[(r, 2)] = ("", 10); c[(r, 3)] = ("", 10); c[(r, 4)] = ("", 10)
    inc0 = r + 1
    for name in g("incs"):
        r += 1
        c[(r, 1)] = (name, 5); c[(r, 2)] = ("", 11); c[(r, 3)] = ("", 11)
        c[(r, 4)] = ("=C%d-B%d" % (r, r), 4)                  # income: more than planned is good
    inc1 = r
    r += 1
    tinc = r
    c[(r, 1)] = (g("tinc"), 10)
    for k in (2, 3, 4):
        c[(r, k)] = ("=SUM(%s%d:%s%d)" % (col(k), inc0, col(k), inc1), 7)
    r += 2
    c[(r, 1)] = (g("exp"), 10); c[(r, 2)] = ("", 10); c[(r, 3)] = ("", 10); c[(r, 4)] = ("", 10)
    exp0 = r + 1
    for name in g("exps"):
        r += 1
        c[(r, 1)] = (name, 5); c[(r, 2)] = ("", 11); c[(r, 3)] = ("", 11)
        c[(r, 4)] = ("=B%d-C%d" % (r, r), 4)                  # expenses: under the plan is good
    exp1 = r
    r += 1
    texp = r
    c[(r, 1)] = (g("texp"), 10)
    for k in (2, 3, 4):
        c[(r, k)] = ("=SUM(%s%d:%s%d)" % (col(k), exp0, col(k), exp1), 7)
    r += 2
    c[(r, 1)] = (g("net"), 10)
    c[(r, 2)] = ("=B%d-B%d" % (tinc, texp), 7); c[(r, 3)] = ("=C%d-C%d" % (tinc, texp), 7); c[(r, 4)] = ("", 10)
    r += 1
    c[(r, 1)] = (g("save"), 5); c[(r, 2)] = ("", 11); c[(r, 3)] = ("", 11); c[(r, 4)] = ("=C%d-B%d" % (r, r), 4)
    r += 2
    c[(r, 1)] = (g("tip"), 6)
    return workbook(L, g("sheet"), c, [38, 15, 15, 15], (), {1: 34, 4: 26})


# ================================================================ manifest + build
TEMPLATES = [
    # id, category, kind, ext, EN name, AR name, builder
    ("letter", "business", "word", "docx", "Official letter", "خطاب رسمي", letter),
    ("invoice", "finance", "cell", "xlsx", "Tax invoice", "فاتورة ضريبية", invoice),
    ("cv", "personal", "word", "docx", "CV", "السيرة الذاتية", cv),
    ("minutes", "business", "word", "docx", "Meeting minutes", "محضر اجتماع", minutes),
    ("budget", "finance", "cell", "xlsx", "Monthly budget", "الميزانية الشهرية", budget),
]
CATEGORIES = [("business", "Business", "الأعمال"), ("finance", "Finance", "المالية"), ("personal", "Personal", "شخصي")]
# text that must be in each file (the saved copies are checked again by check_saved.py)
MARKERS = {
    ("letter", "en"): "Yours sincerely", ("letter", "ar"): "وتفضلوا بقبول فائق الاحترام",
    ("cv", "en"): "Work experience", ("cv", "ar"): "الخبرة العملية",
    ("minutes", "en"): "Action items", ("minutes", "ar"): "المهام المطلوبة",
    ("invoice", "en"): "TAX INVOICE", ("invoice", "ar"): "فاتورة ضريبية",
    ("budget", "en"): "Monthly budget", ("budget", "ar"): "الميزانية الشهرية",
}


def manifest():
    return {
        "version": 1,
        "categories": [{"id": i, "name": {"en": e, "ar": r}} for i, e, r in CATEGORIES],
        "templates": [{"id": i, "category": cat, "kind": k, "thumbnail": i, "name": {"en": en, "ar": ar},
                       "file": {"en": "en/gallery/%s.%s" % (i, ext), "ar": "ar/gallery/%s.%s" % (i, ext)},
                       "marker": {"en": MARKERS[(i, "en")], "ar": MARKERS[(i, "ar")]}}
                      for i, cat, k, ext, en, ar, _ in TEMPLATES],
    }


def parts_of(data):
    z = zipfile.ZipFile(io.BytesIO(data))
    return [(n, z.read(n)) for n in z.namelist()]


def main(verify):
    from xml.dom import minidom
    ok = True
    files = {}
    for i, _, kind, ext, _, _, build in TEMPLATES:
        for code in ("en", "ar"):
            files[os.path.join(code, "gallery", "%s.%s" % (i, ext))] = (build(Lang(code)), i, code, ext)
    for rel, (data, i, code, ext) in files.items():
        z = zipfile.ZipFile(io.BytesIO(data))
        for n in z.namelist():
            minidom.parseString(z.read(n))
        allxml = "".join(z.read(n).decode("utf-8") for n in z.namelist())
        need = [MARKERS[(i, code)]]
        if code == "ar":
            need += (['<w:pPrDefault><w:pPr><w:bidi/>', 'w:cs="Cairo"', 'w:bidi="ar-AE"'] if ext == "docx"
                     else ['rightToLeft="1"', '<name val="Cairo"/>'])
        else:
            need += (['w:ascii="Open Sans"'] if ext == "docx" else ['<name val="Open Sans"/>'])
        if ext == "xlsx":
            need += ["<f>", 'fullCalcOnLoad="1"']
        for m in need:
            if escape(m) not in allxml and m not in allxml:
                print("%s: lacks %s" % (rel, m)); ok = False
        path = os.path.join(TPL, rel)
        if verify:
            same = os.path.exists(path) and parts_of(open(path, "rb").read()) == parts_of(data)
            print("%s: %s" % (rel, "matches the generator" if same else "DIFFERS from the generator - rerun"))
            ok &= same
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "wb").write(data)
            print("wrote", os.path.relpath(path, ROOT), len(data), "bytes")
    mpath = os.path.join(TPL, "gallery.json")
    mtext = json.dumps(manifest(), ensure_ascii=False, indent=1) + "\n"
    if verify:
        same = os.path.exists(mpath) and open(mpath, encoding="utf-8").read() == mtext
        print("gallery.json:", "matches the generator" if same else "DIFFERS from the generator - rerun")
        ok &= same
    else:
        open(mpath, "w", encoding="utf-8", newline="\n").write(mtext)
        print("wrote", os.path.relpath(mpath, ROOT))
    print("RESULT", "PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__":
    sys.exit(0 if main("--verify" in sys.argv[1:]) else 1)
