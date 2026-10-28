#!/usr/bin/env python3
"""make_blank_templates.py [--verify] - Xrero's own Arabic blank files (web/templates/ar/new.docx|xlsx|pptx).

Why: a new document made while the app is in Arabic must start right-to-left (Arabic-first promise, plan item M10).
The editors package used to ship ONLYOFFICE's ar-SA blanks: Calibri/theme fonts (not Arabic-capable on iOS, so Arabic
fell back to a system font), lang ar-SA, Chinese cell-style name. These files are written here from scratch - no
Microsoft or ONLYOFFICE template - and assemble_web.sh copies them over templates/ar in the app bundle:

  docx: Normal style + document defaults are bidi (right-to-left paragraphs; the logical "start" alignment shows as
        right-aligned), font Cairo (bundled, SIL OFL - fonts-src/LICENSES.md) for Latin AND complex script, ar-AE.
  xlsx: right-to-left sheet "ورقة1", default font Cairo.
  pptx: 16:9, theme fonts Cairo, every placeholder right-aligned and rtl="1" (title, subtitle, body levels 1-9).

English mode keeps the package's English blanks (templates/en). Output is reproducible (fixed zip timestamps and part
order), so CI runs --verify: regenerate in memory, compare each part with the committed files, check the RTL markers."""
import io, os, sys, zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT = os.path.join(ROOT, "web", "templates", "ar")
FONT = "Cairo"
LANG = "ar-AE"
XML = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKG_REL = "http://schemas.openxmlformats.org/package/2006/relationships"
REL = R_NS
W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
S_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
A_NS = "http://schemas.openxmlformats.org/drawingml/2006/main"
P_NS = "http://schemas.openxmlformats.org/presentationml/2006/main"


def rels(items):
    """items: [(id, type suffix, target)]"""
    body = "".join('<Relationship Id="%s" Type="%s/%s" Target="%s"/>' % (i, REL, t, tg) for i, t, tg in items)
    return XML + '<Relationships xmlns="%s">%s</Relationships>' % (PKG_REL, body)


def content_types(defaults, overrides):
    d = "".join('<Default Extension="%s" ContentType="%s"/>' % e for e in defaults)
    o = "".join('<Override PartName="%s" ContentType="%s"/>' % e for e in overrides)
    return XML + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">%s%s</Types>' % (d, o)


BASE_DEFAULTS = [("rels", "application/vnd.openxmlformats-package.relationships+xml"), ("xml", "application/xml")]


def zip_bytes(parts):
    """parts: [(name, str)] in order; [Content_Types].xml first. Fixed timestamps -> reproducible bytes."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, text in parts:
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, text.encode("utf-8"))
    return buf.getvalue()


# ---------------------------------------------------------------- docx
def docx():
    fonts = '<w:rFonts w:ascii="{0}" w:hAnsi="{0}" w:eastAsia="{0}" w:cs="{0}"/>'.format(FONT)
    lang = '<w:lang w:val="{0}" w:eastAsia="{0}" w:bidi="{0}"/>'.format(LANG)

    def heading(sid, name, size, after, outline=None, based="Normal"):
        o = '<w:outlineLvl w:val="%d"/>' % outline if outline is not None else ""
        return ('<w:style w:type="paragraph" w:styleId="{0}"><w:name w:val="{1}"/><w:basedOn w:val="{2}"/>'
                '<w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/>'
                '<w:spacing w:before="240" w:after="{4}"/>{5}</w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="{3}"/>'
                '<w:szCs w:val="{3}"/></w:rPr></w:style>').format(sid, name, based, size, after, o)

    styles = (XML + '<w:styles xmlns:w="%s">' % W_NS +
              # document defaults: every paragraph right-to-left, Cairo for Latin + Arabic, ar-AE
              '<w:docDefaults><w:rPrDefault><w:rPr>' + fonts + '<w:sz w:val="24"/><w:szCs w:val="24"/>' + lang +
              '</w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:bidi/><w:spacing w:after="160" w:line="300" '
              'w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
              # Normal repeats bidi so the direction survives an engine that rewrites docDefaults; no w:jc = the
              # logical start, which a right-to-left paragraph shows on the right (Word and the editor agree)
              '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/>'
              '<w:pPr><w:bidi/></w:pPr><w:rPr>' + fonts + lang + '</w:rPr></w:style>'
              '<w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont">'
              '<w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/><w:unhideWhenUsed/>'
              '</w:style>'
              '<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/>'
              '<w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/><w:tblPr><w:bidiVisual/>'
              '<w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/>'
              '<w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/>'
              '</w:tblCellMar></w:tblPr></w:style>'
              '<w:style w:type="numbering" w:default="1" w:styleId="NoList"><w:name w:val="No List"/>'
              '<w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/></w:style>'
              + heading("Title", "Title", 52, 120)
              + heading("Subtitle", "Subtitle", 32, 160)
              + heading("Heading1", "heading 1", 36, 120, 0)
              + heading("Heading2", "heading 2", 30, 80, 1)
              + heading("Heading3", "heading 3", 26, 60, 2)
              + '</w:styles>')
    document = (XML + '<w:document xmlns:w="%s" xmlns:r="%s"><w:body>' % (W_NS, R_NS) +
                '<w:p><w:pPr><w:bidi/></w:pPr></w:p>'
                # A4 (UAE), section right-to-left: columns and the gutter mirror too
                '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" '
                'w:left="1440" w:header="720" w:footer="720" w:gutter="0"/><w:cols w:space="720"/><w:bidi/>'
                '<w:rtlGutter/><w:docGrid w:linePitch="360"/></w:sectPr></w:body></w:document>')
    settings = (XML + '<w:settings xmlns:w="%s"><w:defaultTabStop w:val="720"/>' % W_NS +
                '<w:characterSpacingControl w:val="doNotCompress"/>'
                '<w:themeFontLang w:val="%s" w:bidi="%s"/>' % (LANG, LANG) +
                '<w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word"'
                ' w:val="15"/></w:compat></w:settings>')
    font_table = (XML + '<w:fonts xmlns:w="%s"><w:font w:name="%s"><w:charset w:val="B2"/>' % (W_NS, FONT) +
                  '<w:family w:val="auto"/><w:pitch w:val="variable"/></w:font></w:fonts>')
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


# ---------------------------------------------------------------- xlsx
def xlsx():
    sheet_name = "ورقة1"
    workbook = (XML + '<workbook xmlns="%s" xmlns:r="%s"><bookViews><workbookView/></bookViews>' % (S_NS, R_NS) +
                '<sheets><sheet name="%s" sheetId="1" r:id="rId1"/></sheets></workbook>' % sheet_name)
    sheet = (XML + '<worksheet xmlns="%s" xmlns:r="%s"><dimension ref="A1"/>' % (S_NS, R_NS) +
             # the sheet itself right-to-left: column A on the right, the scroll start on the right
             '<sheetViews><sheetView rightToLeft="1" tabSelected="1" workbookViewId="0"/></sheetViews>'
             '<sheetFormatPr defaultRowHeight="18"/><sheetData/></worksheet>')
    styles = (XML + '<styleSheet xmlns="%s">' % S_NS +
              '<fonts count="1"><font><sz val="11"/><color rgb="FF000000"/><name val="%s"/><family val="2"/>'
              '<charset val="178"/></font></fonts>' % FONT +
              '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/>'
              '</fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
              '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
              '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>'
              '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
              '<dxfs count="0"/><tableStyles count="0"/></styleSheet>')
    sml = "application/vnd.openxmlformats-officedocument.spreadsheetml."
    return zip_bytes([
        ("[Content_Types].xml", content_types(BASE_DEFAULTS, [
            ("/xl/workbook.xml", sml + "sheet.main+xml"), ("/xl/worksheets/sheet1.xml", sml + "worksheet+xml"),
            ("/xl/styles.xml", sml + "styles+xml")])),
        ("_rels/.rels", rels([("rId1", "officeDocument", "xl/workbook.xml")])),
        ("xl/_rels/workbook.xml.rels", rels([("rId1", "worksheet", "worksheets/sheet1.xml"),
                                             ("rId2", "styles", "styles.xml")])),
        ("xl/workbook.xml", workbook), ("xl/worksheets/sheet1.xml", sheet), ("xl/styles.xml", styles)])


# ---------------------------------------------------------------- pptx
def lvl_ppr(n, size, bullet, mar=0):
    """one level of a right-to-left paragraph style: algn="r" + rtl="1" (explicit, unlike Word's logical start)"""
    b = ('<a:buFont typeface="Arial"/><a:buChar char="&#8226;"/>' if bullet else '<a:buNone/>')
    return ('<a:lvl{0}pPr marL="{1}" indent="{2}" algn="r" rtl="1"><a:spcBef><a:spcPts val="{3}"/></a:spcBef>{4}'
            '<a:defRPr sz="{5}" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>'
            '<a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl{0}pPr>'
            ).format(n, mar, -228600 if bullet else 0, 1000 if bullet else 0, b, size)


def pptx():
    sz = (12192000, 6858000)          # 16:9
    theme = (XML + '<a:theme xmlns:a="%s" name="Xrero">' % A_NS +
             '<a:themeElements><a:clrScheme name="Xrero">'
             '<a:dk1><a:srgbClr val="1C1C1E"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>'
             '<a:dk2><a:srgbClr val="17424C"/></a:dk2><a:lt2><a:srgbClr val="F2F2F7"/></a:lt2>'
             '<a:accent1><a:srgbClr val="1F7A8C"/></a:accent1><a:accent2><a:srgbClr val="C8963E"/></a:accent2>'
             '<a:accent3><a:srgbClr val="3E8E5A"/></a:accent3><a:accent4><a:srgbClr val="4B5EAA"/></a:accent4>'
             '<a:accent5><a:srgbClr val="B5524A"/></a:accent5><a:accent6><a:srgbClr val="6E6E73"/></a:accent6>'
             '<a:hlink><a:srgbClr val="1F7A8C"/></a:hlink><a:folHlink><a:srgbClr val="5B4B8A"/></a:folHlink>'
             '</a:clrScheme><a:fontScheme name="Xrero Arabic">'
             '<a:majorFont><a:latin typeface="{0}"/><a:ea typeface=""/><a:cs typeface="{0}"/></a:majorFont>'
             '<a:minorFont><a:latin typeface="{0}"/><a:ea typeface=""/><a:cs typeface="{0}"/></a:minorFont>'
             '</a:fontScheme><a:fmtScheme name="Xrero"><a:fillStyleLst>'
             '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr">'
             '<a:tint val="50000"/></a:schemeClr></a:solidFill><a:solidFill><a:schemeClr val="phClr">'
             '<a:shade val="80000"/></a:schemeClr></a:solidFill></a:fillStyleLst><a:lnStyleLst>'
             '<a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
             '<a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
             '<a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>'
             '<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/>'
             '</a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst>'
             '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr">'
             '<a:tint val="95000"/></a:schemeClr></a:solidFill><a:solidFill><a:schemeClr val="phClr">'
             '<a:shade val="90000"/></a:schemeClr></a:solidFill></a:bgFillStyleLst></a:fmtScheme>'
             '</a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>').format(FONT)
    ns = 'xmlns:a="%s" xmlns:r="%s" xmlns:p="%s"' % (A_NS, R_NS, P_NS)
    cmap = ('<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" '
            'accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>')
    m = 457200          # 0.5 inch side margin
    W, H = sz

    def sp(id_, name, ph, box=None, body=""):
        xfrm = ('<a:xfrm><a:off x="%d" y="%d"/><a:ext cx="%d" cy="%d"/></a:xfrm>' % box) if box else ""
        return ('<p:sp><p:nvSpPr><p:cNvPr id="%d" name="%s"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>'
                '<p:nvPr>%s</p:nvPr></p:nvSpPr><p:spPr>%s</p:spPr><p:txBody><a:bodyPr%s/><a:lstStyle/>'
                '<a:p><a:pPr algn="r" rtl="1"/><a:endParaRPr lang="%s"/></a:p></p:txBody></p:sp>'
                ) % (id_, name, ph, xfrm, body, LANG)

    def tree(shapes, name="", bg=""):
        """a slide/layout/master shape tree (bg: the master's background, which comes before the shapes)"""
        n = ' name="%s"' % name if name else ""
        return ('<p:cSld' + n + '>' + bg + '<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
                '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/>'
                '<a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>%s</p:spTree></p:cSld>') % "".join(shapes)

    title_box = (m, 365125, W - 2 * m, 1325563)
    body_box = (m, 1825625, W - 2 * m, 4351338)
    master = (XML + '<p:sldMaster %s>' % ns +
              tree([sp(2, "Title Placeholder 1", '<p:ph type="title"/>', title_box, ' anchor="ctr"'),
                    sp(3, "Text Placeholder 2", '<p:ph type="body" idx="1"/>', body_box)],
                   bg='<p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>') +
              cmap + '<p:sldLayoutIdLst>' +
              "".join('<p:sldLayoutId id="%d" r:id="rId%d"/>' % (2147483649 + i, i + 1) for i in range(4)) +
              '</p:sldLayoutIdLst><p:txStyles><p:titleStyle>'
              '<a:lvl1pPr algn="r" rtl="1"><a:lnSpc><a:spcPct val="90000"/></a:lnSpc><a:spcBef><a:spcPct val="0"/>'
              '</a:spcBef><a:buNone/><a:defRPr sz="4000" b="1" kern="1200"><a:solidFill><a:schemeClr val="tx1"/>'
              '</a:solidFill><a:latin typeface="+mj-lt"/><a:ea typeface="+mj-ea"/><a:cs typeface="+mj-cs"/>'
              '</a:defRPr></a:lvl1pPr></p:titleStyle><p:bodyStyle>' +
              "".join(lvl_ppr(i, 2400 if i == 1 else 2000, True, 228600 + (i - 1) * 457200) for i in range(1, 10)) +
              '</p:bodyStyle><p:otherStyle>' +
              "".join(lvl_ppr(i, 1800, False, (i - 1) * 457200) for i in range(1, 10)) +
              '</p:otherStyle></p:txStyles></p:sldMaster>')

    def layout(name, typ, shapes):
        return (XML + '<p:sldLayout %s type="%s" preserve="1">' % (ns, typ) +
                tree(shapes, name) +
                '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>')

    layouts = [
        layout("Title Slide", "title", [
            sp(2, "Title 1", '<p:ph type="ctrTitle"/>', (m * 2, 1700000, W - 4 * m, 1800000), ' anchor="b"'),
            sp(3, "Subtitle 2", '<p:ph type="subTitle" idx="1"/>', (m * 2, 3650000, W - 4 * m, 1200000))]),
        layout("Title and Content", "obj", [
            sp(2, "Title 1", '<p:ph type="title"/>'), sp(3, "Content Placeholder 2", '<p:ph idx="1"/>')]),
        layout("Title Only", "titleOnly", [sp(2, "Title 1", '<p:ph type="title"/>')]),
        layout("Blank", "blank", []),
    ]
    slide = (XML + '<p:sld %s>' % ns + tree([
        sp(2, "Title 1", '<p:ph type="ctrTitle"/>'), sp(3, "Subtitle 2", '<p:ph type="subTitle" idx="1"/>')]) +
        '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>')
    default_text = "".join(lvl_ppr(i, 1800, False, (i - 1) * 457200) for i in range(1, 10))
    presentation = (XML + '<p:presentation %s saveSubsetFonts="1">' % ns +
                    '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
                    '<p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst>'
                    '<p:sldSz cx="%d" cy="%d"/><p:notesSz cx="6858000" cy="9144000"/>' % sz +
                    '<p:defaultTextStyle><a:defPPr algn="r" rtl="1"><a:defRPr lang="%s"/></a:defPPr>' % LANG +
                    default_text + '</p:defaultTextStyle></p:presentation>')
    pres_props = XML + '<p:presentationPr %s/>' % ns
    view_props = (XML + '<p:viewPr %s><p:normalViewPr><p:restoredLeft sz="15620"/><p:restoredTop sz="94660"/>' % ns +
                  '</p:normalViewPr><p:gridSpacing cx="76200" cy="76200"/></p:viewPr>')
    table_styles = XML + '<a:tblStyleLst xmlns:a="%s" def="{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"/>' % A_NS
    pml = "application/vnd.openxmlformats-officedocument.presentationml."
    overrides = [("/ppt/presentation.xml", pml + "presentation.main+xml"),
                 ("/ppt/slideMasters/slideMaster1.xml", pml + "slideMaster+xml"),
                 ("/ppt/slides/slide1.xml", pml + "slide+xml"),
                 ("/ppt/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml"),
                 ("/ppt/presProps.xml", pml + "presProps+xml"), ("/ppt/viewProps.xml", pml + "viewProps+xml"),
                 ("/ppt/tableStyles.xml", pml + "tableStyles+xml")]
    overrides += [("/ppt/slideLayouts/slideLayout%d.xml" % (i + 1), pml + "slideLayout+xml") for i in range(4)]
    parts = [
        ("[Content_Types].xml", content_types(BASE_DEFAULTS, overrides)),
        ("_rels/.rels", rels([("rId1", "officeDocument", "ppt/presentation.xml")])),
        ("ppt/_rels/presentation.xml.rels", rels([
            ("rId1", "slideMaster", "slideMasters/slideMaster1.xml"), ("rId2", "slide", "slides/slide1.xml"),
            ("rId3", "theme", "theme/theme1.xml"), ("rId4", "presProps", "presProps.xml"),
            ("rId5", "viewProps", "viewProps.xml"), ("rId6", "tableStyles", "tableStyles.xml")])),
        ("ppt/presentation.xml", presentation),
        ("ppt/slideMasters/_rels/slideMaster1.xml.rels", rels(
            [("rId%d" % (i + 1), "slideLayout", "../slideLayouts/slideLayout%d.xml" % (i + 1)) for i in range(4)] +
            [("rId5", "theme", "../theme/theme1.xml")])),
        ("ppt/slideMasters/slideMaster1.xml", master)]
    for i, l in enumerate(layouts):
        parts.append(("ppt/slideLayouts/_rels/slideLayout%d.xml.rels" % (i + 1),
                      rels([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")])))
        parts.append(("ppt/slideLayouts/slideLayout%d.xml" % (i + 1), l))
    parts += [("ppt/slides/_rels/slide1.xml.rels", rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")])),
              ("ppt/slides/slide1.xml", slide), ("ppt/theme/theme1.xml", theme),
              ("ppt/presProps.xml", pres_props), ("ppt/viewProps.xml", view_props),
              ("ppt/tableStyles.xml", table_styles)]
    return zip_bytes(parts)


BUILDERS = {"docx": docx, "xlsx": xlsx, "pptx": pptx}
# what each Arabic blank must say (checked on the generated bytes; the saved files are checked by check_saved.py)
MARKERS = {"docx": [("word/styles.xml", "<w:pPrDefault><w:pPr><w:bidi/>"), ("word/styles.xml", 'w:cs="Cairo"'),
                    ("word/styles.xml", 'w:bidi="ar-AE"'), ("word/document.xml", "<w:bidi/>")],
           "xlsx": [("xl/worksheets/sheet1.xml", 'rightToLeft="1"'), ("xl/styles.xml", '<name val="Cairo"/>')],
           "pptx": [("ppt/slideMasters/slideMaster1.xml", '<a:lvl1pPr algn="r" rtl="1">'),
                    ("ppt/theme/theme1.xml", '<a:cs typeface="Cairo"/>')]}


def parts_of(data):
    z = zipfile.ZipFile(io.BytesIO(data))
    return [(n, z.read(n)) for n in z.namelist()]


def main(verify):
    from xml.dom import minidom
    ok = True
    os.makedirs(OUT, exist_ok=True)
    for ext, build in BUILDERS.items():
        data = build()
        z = zipfile.ZipFile(io.BytesIO(data))
        for n in z.namelist():                 # every part is well-formed XML
            minidom.parseString(z.read(n))
        for part, marker in MARKERS[ext]:
            if marker not in z.read(part).decode("utf-8"):
                print("new.%s: %s lacks %s" % (ext, part, marker)); ok = False
        path = os.path.join(OUT, "new." + ext)
        if verify:
            # compare the parts, not the zip bytes: another zlib (macOS CI) may deflate the same XML differently
            same = os.path.exists(path) and parts_of(open(path, "rb").read()) == parts_of(data)
            print("new.%s: %s" % (ext, "matches the generator" if same else "DIFFERS from the generator - rerun"))
            ok &= same
        else:
            open(path, "wb").write(data)
            print("wrote", os.path.relpath(path, ROOT), len(data), "bytes")
    print("RESULT", "PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__":
    sys.exit(0 if main("--verify" in sys.argv[1:]) else 1)
