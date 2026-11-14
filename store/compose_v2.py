"""compose_v2.py - App Store screenshots, 20.3 look: the real app screenshots (store/raw/<iphone|ipad>-<lang>-<doc>.png
from the store-shots workflow, incl. the dark-mode ones) set in a light, editorial frame - eyebrow, bold headline with
one accent phrase, slim device - plus a hero opener and a typographic privacy closer. Rendered by headless Chrome at
Apple's exact sizes: iPhone 6.9" 1320x2868, iPad 13" 2064x2752. Output: store/final/<lang>/<device>-NN.png.
Claims are only what the app does today (no other vendor's names, no comparisons)."""
import json, os, pathlib, struct, subprocess

HERE = pathlib.Path(__file__).resolve().parent
RAW, OUT, TMP = HERE / "raw", HERE / "final", HERE / "frames-tmp"
FONTS = (HERE.parent / "fonts-src").as_uri()
ICON = (HERE / "icon" / "icon-G-files-teal.png").as_uri()
CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
PROFILE = pathlib.Path(os.environ.get("TEMP", ".")) / "xrero-store-chrome"
SIZES = {"iphone": (1320, 2868), "ipad": (2064, 2752)}
KIND = {"report": "#2F6BD8", "sales": "#1E9E5A", "deck": "#E0612F"}

# (kind of frame, raw doc, eyebrow, headline with <em>accent</em>, subline)
SCREENS = {
    "en": [
        ("hero", "en-report", "", "The office suite that speaks <em>Arabic</em> and English", ""),
        ("shot", "en-report", "Documents", "Write <em>beautiful</em> documents", "Open, edit and save .docx - headings, lists, tables and images"),
        ("shot", "en-sales", "Spreadsheets", "Sheets with <em>real formulas</em>", "Totals, percentages and cell formatting in .xlsx"),
        ("shot", "en-deck", "Presentations", "Slides that <em>stand out</em>", "Edit .pptx anywhere - layouts, themes and transitions"),
        ("shot", "ar-report", "Arabic-first", "Right to left, <em>done right</em>", "Cairo, Amiri, Tajawal and Noto Naskh built in"),
        ("dark", "en-darkreport", "Dark mode", "Easy on the eyes, <em>day or night</em>", "Follows your device - light or dark, live"),
        ("private", "", "Privacy", "<em>Private</em> by design", ""),
    ],
    "ar": [
        ("hero", "ar-report", "", "حزمة المكتب التي تتحدث <em>العربية</em> والإنجليزية", ""),
        ("shot", "ar-report", "المستندات", "مستندات <em>بتنسيق احترافي</em>", "افتح ملفات docx وعدّلها واحفظها - عناوين وقوائم وجداول وصور"),
        ("shot", "ar-sales", "الجداول", "جداول <em>بمعادلات حقيقية</em>", "الإجماليات والنسب وتنسيق الخلايا في ملفات xlsx"),
        ("shot", "ar-deck", "العروض التقديمية", "عروض <em>تلفت الأنظار</em>", "عدّل شرائح pptx أينما كنت - تخطيطات وسمات وانتقالات"),
        ("shot", "en-report", "لغتان", "بالعربية <em>والإنجليزية</em>", "بدّل لغة الواجهة بلمسة واحدة"),
        ("dark", "ar-darkreport", "الوضع الداكن", "مريح للعين <em>ليلًا ونهارًا</em>", "يتبع إعداد جهازك - فاتح أو داكن، فورًا"),
        ("private", "", "الخصوصية", "<em>خصوصيتك</em> أولًا", ""),
    ],
}
CHIPS = {"en": ["Free", "Works offline", "No account needed"], "ar": ["مجاني", "يعمل دون إنترنت", "بلا حساب"]}
PRIVATE = {
    "en": [("Your files stay on your device", "Nothing is uploaded to open, edit or save"),
           ("Works without internet", "On a plane, on site, anywhere"),
           ("No account needed", "Open the app and start writing"),
           ("No tracking", "Data Not Collected - see the privacy label"),
           ("Free and open source", "Every feature, at no cost")],
    "ar": [("ملفاتك تبقى على جهازك", "لا يُرفع شيء لفتح الملفات أو تعديلها أو حفظها"),
           ("يعمل دون إنترنت", "في الطائرة أو في الموقع أو أي مكان"),
           ("بلا حساب", "افتح التطبيق وابدأ الكتابة"),
           ("بلا تتبّع", "لا تُجمع أي بيانات - راجع ملصق الخصوصية"),
           ("مجاني ومفتوح المصدر", "كل الميزات دون أي تكلفة")],
}

_S = 'fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"'
ICONS = {   # 24-unit line icons, white on the teal tile
    "device": f'<svg viewBox="0 0 24 24" {_S}><rect x="6" y="2.5" width="12" height="19" rx="2.6"/><path d="M10.5 18.5h3"/><path d="M9.5 9.5l2 2 3.5-4"/></svg>',
    "offline": f'<svg viewBox="0 0 24 24" {_S}><path d="M6.5 18.5h10a4 4 0 0 0 .6-7.95A6 6 0 0 0 7 9.2 4.7 4.7 0 0 0 6.5 18.5z"/><path d="M3 3l18 18"/></svg>',
    "account": f'<svg viewBox="0 0 24 24" {_S}><circle cx="12" cy="8" r="3.6"/><path d="M5 20c.8-3.6 3.6-5.5 7-5.5s6.2 1.9 7 5.5"/><path d="M3 3l18 18"/></svg>',
    "track": f'<svg viewBox="0 0 24 24" {_S}><path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/><path d="M3 3l18 18"/></svg>',
}
SHIELD = """<svg viewBox="0 0 400 400" xmlns="http://www.w3.org/2000/svg"><defs>
<radialGradient id="g" cx="50%" cy="45%" r="50%"><stop offset="0" stop-color="#5FE0CF" stop-opacity=".45"/><stop offset="1" stop-color="#5FE0CF" stop-opacity="0"/></radialGradient>
<linearGradient id="sf" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffffff" stop-opacity=".22"/><stop offset="1" stop-color="#ffffff" stop-opacity=".05"/></linearGradient>
<linearGradient id="se" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#B8FFF5"/><stop offset="1" stop-color="#14A7BF"/></linearGradient></defs>
<circle cx="200" cy="200" r="200" fill="url(#g)"/>
<circle cx="200" cy="200" r="168" fill="none" stroke="#5FE0CF" stroke-opacity=".18" stroke-width="2"/>
<circle cx="200" cy="200" r="132" fill="none" stroke="#5FE0CF" stroke-opacity=".12" stroke-width="2"/>
<path d="M200 70 L300 108 V196 C300 262 258 310 200 334 C142 310 100 262 100 196 V108 Z" fill="url(#sf)" stroke="url(#se)" stroke-width="7" stroke-linejoin="round"/>
<path d="M166 150 h50 l22 22 v74 a8 8 0 0 1 -8 8 h-64 a8 8 0 0 1 -8 -8 v-88 a8 8 0 0 1 8 -8 z" fill="#ffffff"/>
<path d="M216 150 v16 a6 6 0 0 0 6 6 h16 z" fill="#B8E6EC"/>
<rect x="172" y="180" width="40" height="7" rx="3.5" fill="#9FCBD3"/><rect x="172" y="194" width="52" height="7" rx="3.5" fill="#CFE6EA"/>
<circle cx="236" cy="248" r="26" fill="#0585A1" stroke="#ffffff" stroke-width="5"/>
<path d="M224 248 l9 9 l16 -18" fill="none" stroke="#fff" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/></svg>"""

def png_size(p):
    return struct.unpack(">II", open(p, "rb").read()[16:24])

def css(device, rtl, dark, tint=None):
    W, H = SIZES[device]
    big = device == "ipad"
    ink, sub, accent = ("#F2FAFB", "#A9C9D0", "#5FE0CF") if dark else ("#0B2A33", "#4A6A72", "#0585A1")
    bg = ("radial-gradient(1200px 900px at 50% 0%,#145a6a 0%,rgba(20,90,106,0) 70%),linear-gradient(180deg,#0B2E38 0%,#06212A 100%)"
          if dark else
          f"radial-gradient(1300px 1000px at {'85%' if rtl else '15%'} -10%,{(tint + '2E') if tint else '#C8EEF2'} 0%,rgba(200,238,242,0) 65%),"
          "radial-gradient(900px 700px at 50% 110%,#D9F3EE 0%,rgba(217,243,238,0) 70%),linear-gradient(180deg,#F7FCFD 0%,#ECF6F8 100%)")
    head = "Tajawal" if rtl else "Montserrat"
    return f"""
@font-face{{font-family:Montserrat;src:url('{FONTS}/Montserrat-Bold.ttf');font-weight:700}}
@font-face{{font-family:Open;src:url('{FONTS}/OpenSans-Regular.ttf');font-weight:400}}
@font-face{{font-family:Open;src:url('{FONTS}/OpenSans-Semibold.ttf');font-weight:600}}
@font-face{{font-family:Tajawal;src:url('{FONTS}/Tajawal-Bold.ttf');font-weight:700}}
@font-face{{font-family:Tajawal;src:url('{FONTS}/Tajawal-Medium.ttf');font-weight:500}}
html,body{{margin:0;width:{W}px;height:{H}px;overflow:hidden}}
body{{background:{bg};color:{ink};font-family:{'Tajawal' if rtl else 'Open'},sans-serif;position:relative}}
.top{{position:absolute;left:{120 if big else 96}px;right:{120 if big else 96}px;top:{150 if big else 170}px;text-align:center}}
.eb{{display:inline-flex;align-items:center;gap:16px;font:{'500' if rtl else '600'} {40 if big else 38}px/1 {'Tajawal' if rtl else 'Open'};
     letter-spacing:{0 if rtl else 3}px;text-transform:uppercase;color:{accent};padding:16px 30px;border-radius:999px;
     background:{'rgba(95,224,207,.12)' if dark else 'rgba(5,133,161,.09)'}}}
.eb i{{width:18px;height:18px;border-radius:50%;display:block}}
h1{{font:700 {118 if big else 104}px/1.08 {head};margin:{34}px 0 0;letter-spacing:{0 if rtl else -2.5}px}}
h1 em{{font-style:normal;color:{accent}}}
.sub{{font-size:{50 if big else 46}px;line-height:1.35;color:{sub};margin:28px auto 0;max-width:{1500 if big else 1080}px}}
.dev{{position:absolute;left:50%;transform:translateX(-50%);background:#0E1A1E;box-shadow:0 60px 140px rgba(6,40,50,{.55 if dark else .28}),
      0 0 0 2px rgba(255,255,255,{.10 if dark else .6}) inset}}
.dev img{{display:block}}
.island{{position:absolute;left:50%;transform:translateX(-50%);background:#000;border-radius:999px}}
"""

def device_html(device, raw, top):
    rw, rh = png_size(raw)
    if device == "iphone":
        w, bez, rad = 1120, 22, 150
    else:
        w, bez, rad = 1740, 26, 70
    sw = w - 2 * bez
    sh = round(sw * rh / rw)
    island = (f'<div class="island" style="top:{bez + round(sw*0.03)}px;width:{round(sw*0.29)}px;height:{round(sw*0.085)}px"></div>'
              if device == "iphone" else "")
    return (f'<div class="dev" style="top:{top}px;width:{w}px;padding:{bez}px;box-sizing:border-box;border-radius:{rad}px">'
            f'<img src="{raw.as_uri()}" style="width:{sw}px;height:{sh}px;border-radius:{rad-bez}px">{island}</div>')

def page(device, lang, frame, i):
    kind, doc, eb, h1, sub = frame
    rtl = lang == "ar"
    big = device == "ipad"
    dark = kind in ("dark", "private")
    body = ""
    if kind == "hero":
        chips = "".join(f'<span class="chip">{c}</span>' for c in CHIPS[lang])
        body = f"""<style>
.hero{{position:absolute;left:0;right:0;top:{150 if big else 170}px;text-align:center}}
.hero img{{width:{230 if big else 250}px;height:{230 if big else 250}px;border-radius:{52 if big else 56}px;box-shadow:0 30px 70px rgba(5,90,110,.35)}}
.name{{font:700 {54 if big else 52}px/1 {'Tajawal' if rtl else 'Montserrat'};margin-top:30px;color:#0585A1;letter-spacing:{0 if rtl else 1}px}}
.hero h1{{max-width:{1700 if big else 1150}px;margin:26px auto 0}}
.chips{{display:flex;gap:18px;justify-content:center;margin-top:40px}}
.chip{{font:600 {40 if big else 38}px/1 {'Tajawal' if rtl else 'Open'};padding:20px 34px;border-radius:999px;background:#fff;color:#0B2A33;
      box-shadow:0 8px 24px rgba(6,60,72,.10)}}</style>
<div class="hero"><img src="{ICON}"><div class="name">Xrero Office</div><h1>{h1}</h1><div class="chips">{chips}</div></div>"""
        body += device_html(device, RAW / f"{device}-{doc}.png", 1060 if big else 1280)
    elif kind == "private":
        # dark statement page: a glass shield holding a document, four feature tiles with their own icons, a wide
        # "free" bar and the app mark - fills the page from top to bottom (no device)
        items = PRIVATE[lang]
        tiles = "".join(f'<div class="t"><div class="ic">{ICONS[n]}</div><b>{a}</b><span>{b_}</span></div>'
                        for n, (a, b_) in zip(("device", "offline", "account", "track"), items[:4]))
        sw = 640 if big else 620
        body = f"""<style>
.shield{{position:absolute;left:50%;transform:translateX(-50%);top:{470 if big else 480}px;width:{sw}px;height:{sw}px}}
.stack{{position:absolute;left:{200 if big else 80}px;right:{200 if big else 80}px;top:{1160 if big else 1170}px}}
.grid{{display:grid;grid-template-columns:1fr 1fr;gap:{34 if big else 30}px}}
.t{{background:linear-gradient(180deg,rgba(255,255,255,.09),rgba(255,255,255,.04));border:2px solid rgba(255,255,255,.12);
    border-radius:48px;padding:{52 if big else 46}px {48 if big else 42}px;min-height:{300 if big else 330}px;box-sizing:border-box}}
.ic{{width:120px;height:120px;border-radius:36px;background:linear-gradient(135deg,#5FE0CF,#0585A1);display:flex;align-items:center;
     justify-content:center;box-shadow:0 14px 34px rgba(5,133,161,.45)}}
.ic svg{{width:66px;height:66px}}
.t b{{display:block;margin-top:34px;font:700 {54 if big else 50}px/1.2 {'Tajawal' if rtl else 'Montserrat'};color:#F2FAFB;letter-spacing:{0 if rtl else -.5}px}}
.t span{{display:block;margin-top:14px;font-size:{40 if big else 36}px;line-height:1.35;color:#A9C9D0}}
.free{{margin-top:{34 if big else 30}px;border-radius:999px;
      padding:38px 56px;background:linear-gradient(90deg,#5FE0CF,#14A7BF);color:#06222B;display:flex;align-items:center;justify-content:center;gap:24px;
      font:700 {52 if big else 48}px/1.1 {'Tajawal' if rtl else 'Montserrat'}}}
.free small{{font:500 {40 if big else 36}px/1.2 {'Tajawal' if rtl else 'Open'};opacity:.8}}
.foot{{position:absolute;left:0;right:0;bottom:{140 if big else 160}px;display:flex;gap:26px;justify-content:center;align-items:center;
      font:700 52px/1 {'Tajawal' if rtl else 'Montserrat'};color:#F2FAFB}}
.foot img{{width:112px;height:112px;border-radius:26px;box-shadow:0 12px 30px rgba(0,0,0,.35)}}</style>
<div class="shield">{SHIELD}</div><div class="stack"><div class="grid">{tiles}</div>
<div class="free">{items[4][0]}<small>· {items[4][1]}</small></div></div>
<div class="foot"><img src="{ICON}">Xrero Office</div>"""
    else:
        body = device_html(device, RAW / f"{device}-{doc}.png", 760 if big else 820)
    dot = ""
    k = next((v for key, v in KIND.items() if key in doc), None)
    if kind == "shot" and k:
        dot = f'<i style="background:{k}"></i>'
    top = "" if kind == "hero" else (f'<div class="top">{f"<span class=eb>{dot}{eb}</span>" if eb else ""}<h1>{h1}</h1>'
                                     + (f'<div class="sub">{sub}</div>' if sub else "") + "</div>")
    return (f'<!doctype html><html dir="{"rtl" if rtl else "ltr"}" lang="{lang}"><head><meta charset="utf-8">'
            f'<style>{css(device, rtl, dark, k if kind == "shot" else None)}</style></head><body>{top}{body}</body></html>')

def render(html_path, out_png, W, H):
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                    "--allow-file-access-from-files", f"--user-data-dir={PROFILE}", f"--window-size={W},{H}",
                    f"--screenshot={out_png}", html_path.as_uri()], check=True, capture_output=True, timeout=120)
    if png_size(out_png) != SIZES["iphone" if W == 1320 else "ipad"]:
        raise SystemExit(f"{out_png}: wrong size {png_size(out_png)}")

def main():
    TMP.mkdir(exist_ok=True)
    made, missing = [], []
    for lang, frames in SCREENS.items():
        for device in ("iphone", "ipad"):
            d = OUT / lang
            d.mkdir(parents=True, exist_ok=True)
            for old in d.glob(f"{device}-*.png"):
                old.unlink()
            n = 0
            for frame in frames:
                if frame[1] and not (RAW / f"{device}-{frame[1]}.png").exists():
                    missing.append(f"{device}-{frame[1]}"); continue
                n += 1
                html = TMP / f"{lang}-{device}-{n}.html"
                html.write_text(page(device, lang, frame, n), encoding="utf-8")
                out = d / f"{device}-{n:02d}.png"
                render(html, out, *SIZES[device])
                made.append(str(out.relative_to(HERE)))
    print(json.dumps({"made": made, "missing": missing}, indent=1, ensure_ascii=False))

if __name__ == "__main__":
    main()
