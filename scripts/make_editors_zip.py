"""make_editors_zip.py [--source <dir>] <previous ios-editors zip> <out zip> - the editors package of the iOS app
(release asset ios-editors-<version>.zip, unpacked by assemble_web.sh), built from v20/staging/XreroOffice/editors, or
from --source <dir>: a folder with the same layout (editors/...), e.g. the editors tree extracted from a released
Windows MSIX (21.0: v20/payload-21.0-r5, from the round-5 MSIX), so the package never depends on a staging folder
that is still being changed:

  - every file of the previous package, refreshed from staging (templates/ come from the previous package),
  - + the PDF editor: web-apps/apps/pdfeditor/main/** and the PDF engine sdkjs/pdf/src/** (drawingfile.js +
    drawingfile.wasm + cmap.bin + viewer.js + stamp texts) - without drawingfile_ie.js (asm.js fallback for
    browsers without WebAssembly, 18 MB) and drawingfile_native.js (desktop native engine).
Not included, as before: sdkjs-plugins, V8 snapshots (*.bin of the converter), the forms/visio editors."""
import hashlib, os, sys, zipfile

V20 = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
STAGE = os.path.join(V20, "staging", "XreroOffice")
ADD_DIRS = ["editors/web-apps/apps/pdfeditor/main", "editors/sdkjs/pdf/src"]
SKIP = {"drawingfile_ie.js", "drawingfile_native.js"}


def main(prev, out, stage=STAGE):
    old = zipfile.ZipFile(prev)
    names = [n for n in old.namelist() if not n.endswith("/")]
    files = {}
    for n in names:
        p = os.path.join(stage, n)
        files[n] = ("disk", p) if os.path.isfile(p) else ("zip", n)
    added = 0
    for d in ADD_DIRS:
        for root, _, fs in os.walk(os.path.join(stage, d)):
            for f in fs:
                if f in SKIP:
                    continue
                rel = os.path.relpath(os.path.join(root, f), stage).replace(os.sep, "/")
                if rel not in files:
                    added += 1
                files[rel] = ("disk", os.path.join(root, f))
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for rel in sorted(files):
            kind, src = files[rel]
            data = open(src, "rb").read() if kind == "disk" else old.read(src)
            z.writestr(rel, data)
    for must in ["editors/web-apps/apps/pdfeditor/main/index.html", "editors/sdkjs/pdf/src/engine/drawingfile.wasm",
                 "editors/sdkjs/pdf/src/engine/cmap.bin", "editors/web-apps/apps/documenteditor/main/index.html",
                 "templates/en/new.docx"]:
        if must not in files:
            raise SystemExit("missing " + must)
    kept = sorted(n for n, (kind, _) in files.items() if kind == "zip")
    print("source %s; kept from the previous package (not in the source): %d %s" % (stage, len(kept), kept[:12]))
    h = hashlib.sha256(open(out, "rb").read()).hexdigest()
    open(out + ".sha256", "w").write("%s  %s\n" % (h, os.path.basename(out)))
    print("%s: %d files (%d new for PDF), %.1f MB, sha256 %s" % (out, len(files), added, os.path.getsize(out) / 1e6, h))


if __name__ == "__main__":
    a = sys.argv[1:]
    src = STAGE
    if a[:1] == ["--source"]:
        src = os.path.abspath(a[1]); a = a[2:]
        if not os.path.isdir(os.path.join(src, "editors")):
            raise SystemExit("--source has no editors/ folder: " + src)
    main(a[0], a[1], src)
