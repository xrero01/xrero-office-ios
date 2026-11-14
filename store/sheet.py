"""sheet.py [device] - contact sheet of store/final/<en|ar>/<device>-*.png (EN row, AR row) -> frames-tmp/sheet-<device>.png"""
import os, pathlib, subprocess, sys

H = pathlib.Path(__file__).resolve().parent
dev = sys.argv[1] if len(sys.argv) > 1 else "iphone"
w = 250 if dev == "iphone" else 360
cells = ""
for lang in ("en", "ar"):
    cells += "<div class=row>" + "".join(f'<img src="{p.as_uri()}">' for p in sorted((H / "final" / lang).glob(f"{dev}-*.png"))) + "</div>"
html = f'<html><body style="margin:0;background:#777"><style>.row{{display:flex;gap:10px;padding:10px}} img{{width:{w}px}}</style>{cells}</body></html>'
f = H / "frames-tmp" / "sheet.html"
f.write_text(html, encoding="utf-8")
hgt = 2 * (round(w * (2868 / 1320 if dev == "iphone" else 2752 / 2064)) + 20)
subprocess.run([r"C:\Program Files\Google\Chrome\Application\chrome.exe", "--headless=new", "--disable-gpu", "--hide-scrollbars",
                "--allow-file-access-from-files", "--user-data-dir=" + str(pathlib.Path(os.environ["TEMP"]) / "xrero-sheet-chrome"),
                f"--window-size={7 * (w + 10) + 10},{hgt}", "--screenshot=" + str(H / "frames-tmp" / f"sheet-{dev}.png"), f.as_uri()],
               check=True, capture_output=True, timeout=110)
print("ok")
