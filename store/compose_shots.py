"""compose_shots.py - App Store screenshots: the real app screenshots (store/raw/<iphone|ipad>-<lang>-<doc>.png,
from the store-shots workflow) framed with a caption, rendered by headless Chrome at Apple's exact sizes:
iPhone 6.9" 1320x2868, iPad 13" 2064x2752 (portrait). Output: store/final/<lang>/<device>-NN.png"""
import json, os, pathlib, struct, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
RAW, OUT, TMP = HERE / "raw", HERE / "final", HERE / "frames-tmp"
FONTS = HERE.parent / "fonts-src"
CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
PROFILE = pathlib.Path(os.environ.get("TEMP", ".")) / "xrero-store-chrome"

SCREENS = {   # (raw doc, caption, subcaption) per listing language
    "en": [("en-report", "Your documents, beautifully edited", "Open, edit and save .docx files - fully offline"),
           ("en-sales", "Spreadsheets with real formulas", "Totals, percentages and formatting in .xlsx"),
           ("en-deck", "Presentations that stand out", "Edit .pptx slides wherever you are"),
           ("ar-report", "Arabic-first, right to left", "Cairo, Amiri and more Arabic fonts built in")],
    "ar": [("ar-report", "مستنداتك بتنسيق احترافي", "افتح ملفات docx وعدّلها واحفظها دون إنترنت"),
           ("ar-sales", "جداول بمعادلات حقيقية", "الإجماليات والنسب والتنسيق في ملفات xlsx"),
           ("ar-deck", "عروض تقديمية مميزة", "عدّل شرائح pptx أينما كنت"),
           ("en-report", "بالعربية والإنجليزية", "بدّل لغة الواجهة بلمسة واحدة - وملفاتك لا تغادر جهازك")],
}
SIZES = {"iphone": (1320, 2868), "ipad": (2064, 2752)}

def png_size(p):
    w, h = struct.unpack(">II", open(p, "rb").read()[16:24])
    return w, h

def page(device, lang, raw, cap, sub):
    W, H = SIZES[device]
    rw, rh = png_size(raw)
    if device == "iphone":            # device runs off the bottom edge (modern store style)
        dev_w = 1150; cap_size, sub_size, top = 96, 52, 500
    else:
        dev_w = 1720; cap_size, sub_size, top = 112, 60, 520
    bezel = 26 if device == "iphone" else 30
    radius = 92 if device == "iphone" else 54
    shot_w = dev_w - 2 * bezel
    shot_h = round(shot_w * rh / rw)
    rtl = lang == "ar"
    font = FONTS.as_uri()
    return f"""<!doctype html><html dir="{'rtl' if rtl else 'ltr'}"><head><meta charset="utf-8"><style>
@font-face{{font-family:Cairo;src:url('{font}/Cairo-Bold.ttf');font-weight:700}}
@font-face{{font-family:Cairo;src:url('{font}/Cairo-Regular.ttf');font-weight:400}}
html,body{{margin:0;width:{W}px;height:{H}px;overflow:hidden}}
body{{background:radial-gradient(1400px 900px at {"80%" if rtl else "20%"} 0%,#3fb3c4 0%,rgba(63,179,196,0) 60%),
      linear-gradient(180deg,#1f7a8c 0%,#145566 55%,#0d3b47 100%);font-family:Cairo,sans-serif;color:#fff;position:relative}}
.cap{{position:absolute;left:90px;right:90px;top:{150 if device=='iphone' else 170}px;text-align:center}}
.cap h1{{font-size:{cap_size}px;line-height:1.12;margin:0;font-weight:700;letter-spacing:{0 if rtl else -1}px}}
.cap p{{font-size:{sub_size}px;line-height:1.3;margin:22px 0 0;color:#d4eef3;font-weight:400}}
.dev{{position:absolute;left:{(W-dev_w)//2}px;top:{top}px;width:{dev_w}px;padding:{bezel}px;box-sizing:border-box;
      background:#0b1f25;border-radius:{radius}px;box-shadow:0 50px 120px rgba(0,0,0,.45),0 0 0 3px rgba(255,255,255,.08) inset}}
.dev img{{display:block;width:{shot_w}px;height:{shot_h}px;border-radius:{radius-bezel+6}px}}
</style></head><body>
<div class="cap"><h1>{cap}</h1><p>{sub}</p></div>
<div class="dev"><img src="{raw.as_uri()}"></div>
</body></html>"""

def render(html_path, out_png, W, H):
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                    "--allow-file-access-from-files", f"--user-data-dir={PROFILE}", f"--window-size={W},{H}",
                    f"--screenshot={out_png}", html_path.as_uri()], check=True, capture_output=True, timeout=120)
    w, h = png_size(out_png)
    if (w, h) != (W, H):
        raise SystemExit(f"{out_png}: {w}x{h}, expected {W}x{H}")

def main():
    TMP.mkdir(exist_ok=True)
    made = []
    for lang, screens in SCREENS.items():
        for device in ("iphone", "ipad"):
            (OUT / lang).mkdir(parents=True, exist_ok=True)
            for i, (doc, cap, sub) in enumerate(screens, start=1):
                raw = RAW / f"{device}-{doc}.png"
                if not raw.exists():
                    print("missing", raw.name); continue
                html = TMP / f"{lang}-{device}-{i}.html"
                html.write_text(page(device, lang, raw, cap, sub), encoding="utf-8")
                out = OUT / lang / f"{device}-{i:02d}.png"
                render(html, out, *SIZES[device])
                made.append(str(out.relative_to(HERE)))
    print(json.dumps(made, indent=1))

if __name__ == "__main__":
    main()
