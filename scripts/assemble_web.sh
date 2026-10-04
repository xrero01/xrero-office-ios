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
cp "$ROOT/web/xr-editor.html" "$OUT/editors/web-apps/apps/api/documents/xr-editor.html"
mkdir -p "$OUT/x2t"
cp "$ROOT/web/x2t-worker.js" "$ROOT/vendor/x2t-wasm/x2t.js" "$ROOT/vendor/x2t-wasm/x2t.wasm" "$OUT/x2t/"
cp -R "$ROOT/fonts-gen" "$OUT/fonts-gen"
rm -f "$OUT/editors/sdkjs/common/AllFonts.js"          # the app serves fonts-gen/AllFonts.js in its place
cp "$ROOT/fonts-src/LICENSES.md" "$OUT/fonts-gen/LICENSES.md"
test -f "$OUT/editors/web-apps/apps/documenteditor/main/index.html"
test -f "$OUT/editors/sdkjs/word/sdk-all-min.js"
test -f "$OUT/templates/en/new.docx" && test -f "$OUT/templates/ar/new.docx"
du -sh "$OUT" "$OUT"/* | sort -h | tail -8
