#!/bin/bash
# assemble_web.sh <ios-editors zip> <out dir (app/build/web)>
# The app bundle's "web" folder: Xrero editors (web-apps + sdkjs, Writer/Calc/Slides), blank templates,
# the editor host (xr-host.js + xr-editor.html), x2t WebAssembly and the app's own fonts.
set -euo pipefail
ZIP="$1"; OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rm -rf "$OUT"; mkdir -p "$OUT"
ditto -x -k "$ZIP" "$OUT" 2>/dev/null || unzip -q "$ZIP" -d "$OUT"
cp "$ROOT/web/xr-host.js" "$OUT/xr-host.js"
# the engine contract (what xr-host.js relies on): read by the Autotest build's "contract" check in the running editors
cp "$ROOT/web/xr-contract.json" "$OUT/xr-contract.json"
# Xrero's own Arabic blanks (scripts/make_blank_templates.py: right-to-left, Cairo, ar-AE) replace the package's
# ar-SA ones, so a new file made while the app is in Arabic starts right-to-left; templates/en stay as packaged
mkdir -p "$OUT/templates/ar"
cp "$ROOT/web/templates/ar/new.docx" "$ROOT/web/templates/ar/new.xlsx" "$ROOT/web/templates/ar/new.pptx" "$OUT/templates/ar/"
cp "$ROOT/web/xr-editor.html" "$OUT/editors/web-apps/apps/api/documents/xr-editor.html"
mkdir -p "$OUT/x2t"
cp "$ROOT/web/x2t-worker.js" "$ROOT/vendor/x2t-wasm/x2t.js" "$ROOT/vendor/x2t-wasm/x2t.wasm" "$OUT/x2t/"
cp -R "$ROOT/fonts-gen" "$OUT/fonts-gen"
python3 "$ROOT/scripts/patch_amd_deps.py" "$OUT/editors/web-apps"
# 20.3 (M6): the Windows build paints its modern-theme header in the Office kind colours with white text
# (/*XR-HEADER*/ ... /*XR-HEADER-END*/ in each editor's app.css). The iPhone / iPad chrome is neutral, with Xrero's
# own kind accents (xr-host.js neutralChrome) - drop that block from this bundle only; Windows is unchanged.
python3 - "$OUT/editors/web-apps/apps" <<'PY'
import glob, re, sys
n = 0
for f in glob.glob(sys.argv[1] + '/*/main/resources/css/*.css'):
    s = open(f, encoding='utf-8').read()
    t = re.sub(r'/\*XR-HEADER\*/.*?/\*XR-HEADER-END\*/', '', s, flags=re.S)
    if t != s:
        open(f, 'w', encoding='utf-8').write(t); n += 1
    assert 'XR-HEADER' not in t, f
print('Office-coloured header block removed from', n, 'stylesheets')
PY
rm -f "$OUT/editors/sdkjs/common/AllFonts.js"          # the app serves fonts-gen/AllFonts.js in its place
cp "$ROOT/fonts-src/LICENSES.md" "$OUT/fonts-gen/LICENSES.md"
test -f "$OUT/editors/web-apps/apps/documenteditor/main/index.html"
test -f "$OUT/editors/sdkjs/word/sdk-all-min.js"
test -f "$OUT/editors/web-apps/apps/pdfeditor/main/index.html"         # PDF editor (packages from 20.0.10 on)
test -f "$OUT/editors/sdkjs/pdf/src/engine/drawingfile.wasm"
test -f "$OUT/templates/en/new.docx" && test -f "$OUT/templates/ar/new.docx"
du -sh "$OUT" "$OUT"/* | sort -h | tail -8
