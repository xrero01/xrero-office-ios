"""serve.py [port] - browser harness for the iOS editor host (no document server, no converter).

  /editors/...           the Xrero web editors (v20 staging payload); editor pages get xr-host.js injected
  /editors/sdkjs/common/AllFonts.js   font list (harness: the installed Windows app's generated list)
  /__font?id=<path>      a font file named by the font list (only inside the listed font folders)
  /__doc/<name>          a test document (release-20.0.9/qa/inputs)
  /__save/<name>  POST   saved bytes -> harness/out/<name>
  /xr/...                ios/web + harness scripts
Open: http://127.0.0.1:<port>/editors/web-apps/apps/api/documents/index.html?doctype=word&title=ar_letter.docx&filetype=docx&lang=en
"""
import http.server, os, re, sys, urllib.parse, json

HERE = os.path.dirname(os.path.abspath(__file__))
V20 = os.path.abspath(os.path.join(HERE, "..", ".."))
EDITORS = os.path.join(V20, "staging", "XreroOffice", "editors")
WEB = os.path.join(V20, "ios", "web")
X2T = os.path.join(V20, "ios", "vendor", "x2t-wasm")
MEDIA = {}
DOCS = os.path.join(V20, "release-20.0.9", "qa", "inputs")
OUT = os.path.join(HERE, "out")
FONTS_JS = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Xrero", "XreroOffice", "data", "fonts", "AllFonts.js")
os.makedirs(OUT, exist_ok=True)

font_files = set()
try:
    s = open(FONTS_JS, encoding="utf-8-sig").read()
    m = re.search(r'window\["__fonts_files"\]\s*=\s*\[(.*?)\];', s, re.S)
    font_files = {os.path.normcase(os.path.abspath(p)) for p in json.loads("[" + m.group(1) + "]")}
except Exception as e:
    print("font list:", e)
print("fonts listed:", len(font_files))

INJECT = b'<script src="/xr/harness-host.js"></script><script src="/xr/xr-host.js"></script>'
EDITOR_PAGE = re.compile(r"^/editors/web-apps/apps/(api/documents|[a-z]+editor/main)/index\.html$")
TYPES = {".js": "application/javascript", ".css": "text/css", ".html": "text/html; charset=utf-8", ".json": "application/json",
         ".png": "image/png", ".svg": "image/svg+xml", ".woff2": "font/woff2", ".woff": "font/woff", ".ttf": "font/ttf",
         ".bin": "application/octet-stream", ".wasm": "application/wasm", ".gif": "image/gif", ".jpg": "image/jpeg"}


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        if "404" in (fmt % a) or "500" in (fmt % a):
            sys.stderr.write("%s\n" % (fmt % a))

    def send(self, code, body=b"", ctype="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def file(self, path, inject=False):
        if not os.path.isfile(path):
            return self.send(404, b"not found")
        body = open(path, "rb").read()
        if inject:
            body = re.sub(rb"<head[^>]*>", lambda m: m.group(0) + INJECT, body, count=1)
        self.send(200, body, TYPES.get(os.path.splitext(path)[1].lower(), "application/octet-stream"))

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        p = urllib.parse.unquote(u.path)
        if p == "/editors/sdkjs/common/AllFonts.js":
            return self.file(FONTS_JS)
        if p.startswith("/editors/"):
            local = os.path.normpath(os.path.join(EDITORS, p[len("/editors/"):]))
            if not local.startswith(EDITORS):
                return self.send(403)
            return self.file(local, inject=bool(EDITOR_PAGE.match(p)))
        if p == "/__font":
            fid = urllib.parse.parse_qs(u.query).get("id", [""])[0]
            f = os.path.normcase(os.path.abspath(fid))
            if f not in font_files:
                return self.send(404, b"font not in list")
            return self.file(f)
        if p == "/__fontsprite":
            return self.file(os.path.join(os.path.dirname(FONTS_JS), "fonts_thumbnail.png"))
        if p.startswith("/__media/"):
            d = MEDIA.get(os.path.basename(p[9:]))
            if d is None:
                return self.send(404, b"no media")
            return self.send(200, d, TYPES.get(os.path.splitext(p)[1].lower(), "application/octet-stream"))
        if p.startswith("/__doc/"):
            return self.file(os.path.join(DOCS, os.path.basename(p[7:])))
        if p.startswith("/xr/"):
            name = os.path.basename(p[4:])
            for d in (WEB, HERE, X2T):
                if os.path.isfile(os.path.join(d, name)):
                    return self.file(os.path.join(d, name))
            return self.send(404)
        self.send(404)

    def do_POST(self):
        p = urllib.parse.unquote(urllib.parse.urlparse(self.path).path)
        n = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(n)
        if p.startswith("/__media/"):
            MEDIA[os.path.basename(p[9:])] = data
            return self.send(200, b"ok")
        if not p.startswith("/__save/"):
            return self.send(404)
        open(os.path.join(OUT, os.path.basename(p[8:])), "wb").write(data)
        print("saved", os.path.basename(p[8:]), len(data), "bytes")
        self.send(200, b"ok")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8791
    print("harness on http://127.0.0.1:%d  editors=%s" % (port, EDITORS))
    http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
