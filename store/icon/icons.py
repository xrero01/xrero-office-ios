"""icons.py - Xrero Office app icon concepts: SVG -> 1024x1024 PNG (full-bleed square, iOS masks the corners)
via headless Chrome, plus a preview sheet with the iOS squircle mask at store / home-screen sizes."""
import pathlib, subprocess, os

HERE = pathlib.Path(__file__).resolve().parent
CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
PROFILE = pathlib.Path(os.environ.get("TEMP", ".")) / "xrero-icon-chrome"

DEFS = """
<linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1">
  <stop offset="0" stop-color="#14A7BF"/><stop offset="0.55" stop-color="#0585A1"/><stop offset="1" stop-color="#035569"/></linearGradient>
<radialGradient id="glow" cx="0.3" cy="0.12" r="0.75">
  <stop offset="0" stop-color="#ffffff" stop-opacity=".28"/><stop offset="1" stop-color="#ffffff" stop-opacity="0"/></radialGradient>
<filter id="sh" x="-30%" y="-30%" width="160%" height="160%">
  <feDropShadow dx="0" dy="22" stdDeviation="26" flood-color="#022a33" flood-opacity=".38"/></filter>
<filter id="sh2" x="-30%" y="-30%" width="160%" height="160%">
  <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#022a33" flood-opacity=".30"/></filter>
<linearGradient id="page" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#e9f4f6"/></linearGradient>
<linearGradient id="fold" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#cfe6ea"/><stop offset="1" stop-color="#9fcbd3"/></linearGradient>
<linearGradient id="lightbg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#DDF1F4"/></linearGradient>
<linearGradient id="night" x1="0" y1="0" x2="0.4" y2="1"><stop offset="0" stop-color="#0E4C5C"/><stop offset="0.6" stop-color="#0A3340"/><stop offset="1" stop-color="#06222B"/></linearGradient>
<linearGradient id="mint" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#9FF0E6"/><stop offset="1" stop-color="#4FD3C4"/></linearGradient>
<linearGradient id="white" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#e3f3f6"/></linearGradient>
"""
GLASS_X = ("<g filter='url(#sh)'>" + '<line x1="300" y1="300" x2="724" y2="724" stroke="url(#mint)" stroke-width="150" stroke-linecap="round"/>'
           + "</g><g filter='url(#sh)'>" + '<line x1="724" y1="300" x2="300" y2="724" stroke="url(#white)" stroke-width="150" stroke-linecap="round"/>'
           + '</g><line x1="684" y1="308" x2="308" y2="684" stroke="#ffffff" stroke-opacity=".55" stroke-width="18" stroke-linecap="round"/>')
BG = '<rect width="1024" height="1024" fill="url(#bg)"/><rect width="1024" height="1024" fill="url(#glow)"/>'

def bar(x1, y1, x2, y2, w, fill):
    return f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{fill}" stroke-width="{w}" stroke-linecap="round"/>'

def card(color, glyph, rot):
    """one file card (page with a folded corner) in a kind colour, fanned around the pivot under the icon centre"""
    x, y, w, h, f = 362, 300, 290, 420, 72
    page = (f'<path d="M{x+28} {y} H{x+w-f} L{x+w} {y+f} V{y+h-28} a28 28 0 0 1 -28 28 H{x+28} a28 28 0 0 1 -28 -28 '
            f'V{y+28} a28 28 0 0 1 28 -28 Z" fill="{color}"/>'
            f'<path d="M{x+w-f} {y} V{y+f-18} a18 18 0 0 0 18 18 H{x+w} Z" fill="#ffffff" fill-opacity=".45"/>')
    return f'<g transform="rotate({rot} 512 900)" filter="url(#sh2)">{page}{glyph}</g>'

W = 'fill="#ffffff"'
# glyphs sit in the top part of each card, the part the fan leaves visible
DOC = "".join(f'<rect x="398" y="{y}" width="{w}" height="24" rx="12" {W}/>' for y, w in ((345, 200), (390, 170), (435, 200)))
SHEET = ('<rect x="398" y="340" width="200" height="130" rx="14" fill="none" stroke="#fff" stroke-width="18"/>'
         '<line x1="398" y1="383" x2="598" y2="383" stroke="#fff" stroke-width="14"/><line x1="398" y1="427" x2="598" y2="427" stroke="#fff" stroke-width="14"/>'
         '<line x1="464" y1="340" x2="464" y2="470" stroke="#fff" stroke-width="14"/>')
SLIDES = ('<rect x="398" y="340" width="200" height="125" rx="16" fill="none" stroke="#fff" stroke-width="18"/>'
          '<path d="M478 372 L478 434 L530 403 Z" fill="#fff"/>')
PDF = '<text x="470" y="430" text-anchor="middle" font-family="Montserrat, Arial Black, sans-serif" font-weight="800" font-size="78" fill="#fff">PDF</text>'
FAN = ('<g transform="translate(512 560) scale(1.04) translate(-512 -560)">' + card("#C62828", PDF, -30) + card("#E0612F", SLIDES, 30)
       + card("#1E9E5A", SHEET, -11) + card("#2F6BD8", DOC, 11) + '</g>')
LIGHT = '<rect width="1024" height="1024" fill="url(#lightbg)"/>'

NAME = ('<text x="512" y="232" text-anchor="middle" font-family="Montserrat" font-weight="700" font-size="104" fill="#ffffff" '
        'letter-spacing="-1">Xrero <tspan font-weight="400" fill-opacity=".85">Office</tspan></text>')

CONCEPTS = {
    # G (owner's choice 14 Nov): the four file types as a fan of cards on the brand teal, the name on top
    "G-files-teal": BG + NAME + '<g transform="translate(512 640) scale(.86) translate(-512 -560)">' + FAN + '</g>',
}

FONT = (pathlib.Path(__file__).resolve().parents[2] / "fonts-src").as_uri()
STYLE = (f"<style>@font-face{{font-family:Montserrat;src:url('{FONT}/Montserrat-Bold.ttf');font-weight:700}}"
         f"@font-face{{font-family:Montserrat;src:url('{FONT}/Montserrat-Regular.ttf');font-weight:400}}</style>")

def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><defs>{DEFS}{STYLE}</defs>{body}</svg>'

def render(html, out, w, h):
    p = HERE / ("_" + out.stem + ".html")
    p.write_text(html, encoding="utf-8")
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                    "--allow-file-access-from-files", "--virtual-time-budget=4000", f"--user-data-dir={PROFILE}", f"--window-size={w},{h}",
                    f"--screenshot={out}", p.as_uri()], check=True, capture_output=True)
    p.unlink()

if __name__ == "__main__":
    tiles = []
    for name, body in CONCEPTS.items():
        f = HERE / f"icon-{name}.svg"
        f.write_text(svg(body), encoding="utf-8")
        render(f'<html><body style="margin:0">{svg(body)}</body></html>', HERE / f"icon-{name}.png", 1024, 1024)
        tiles.append((name, HERE / f"icon-{name}.png"))
    # preview: squircle-masked at 300 / 120 / 60 px, on light and dark
    cells = ""
    for name, f in tiles:
        u = f.as_uri()
        cells += f"""<div class="c"><div class="big"><img src="{u}" style="width:300px;border-radius:67px"></div>
<div class="row"><img src="{u}" style="width:120px;border-radius:27px"><img src="{u}" style="width:60px;border-radius:13px">
<span class="dk"><img src="{u}" style="width:120px;border-radius:27px"><img src="{u}" style="width:60px;border-radius:13px"></span></div>
<p>{name}</p></div>"""
    html = f"""<html><head><style>body{{margin:0;background:#f2f2f7;font:600 28px -apple-system,Segoe UI,sans-serif;display:flex;gap:40px;padding:40px}}
.c{{background:#fff;border-radius:28px;padding:30px;text-align:center}} .row{{display:flex;gap:18px;align-items:center;margin-top:24px}}
.dk{{background:#1c1c1e;border-radius:18px;padding:14px;display:flex;gap:18px;align-items:center}}
img{{box-shadow:0 6px 18px rgba(0,0,0,.18)}} p{{margin:18px 0 0}}</style></head><body>{cells}</body></html>"""
    render(html, HERE / "preview.png", 40 + len(tiles) * 470, 640)
    print("ok", [t[0] for t in tiles])
