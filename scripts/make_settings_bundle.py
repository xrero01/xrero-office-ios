"""make_settings_bundle.py - generates app/XreroOffice/Settings.bundle (iOS Settings app > Xrero Office): version, source
code link and a "Licences" page listing every third-party component and the full licence texts from licenses/*.txt.
Font entries use the copyright string embedded in each bundled font (fonts-src, name table ID 0). Needs fontTools.
Re-run after changing a component, a font or the version."""
import collections, glob, os, plistlib, re
from fontTools.ttLib import TTFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIC = os.path.join(ROOT, "licenses")
OUT = os.path.join(ROOT, "app", "XreroOffice", "Settings.bundle")
SOURCE = "https://github.com/xrero01/xrero-office-ios"
VERSION = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', open(os.path.join(ROOT, "app", "project.yml"), encoding="utf-8").read()).group(1)

# licence of each bundled font family (checked against the font's own licence fields, nameID 13/14)
FONT_LICENCE = [
    ("Liberation", "GNU GPL v2 with the Liberation font exception (Liberation 1.07, https://fedoraproject.org/wiki/Licensing/LiberationFontLicense)"),
    ("Open Sans", "Apache License 2.0"), ("Roboto", "Apache License 2.0"),
    ("DejaVu", "Bitstream Vera licence; DejaVu changes are in the public domain"),
    ("ASCW3", "AGPL-3.0, part of the ONLYOFFICE editors"),
    ("", "SIL Open Font License 1.1"),
]

def text(name):
    s = open(os.path.join(LIC, name), encoding="utf-8").read().replace("\r\n", "\n").replace("\t", "    ")
    return re.sub(r"[\x00-\x09\x0b-\x1f]", "", s).strip()      # page breaks (^L) etc. are not allowed in plists

def group(title, footer=None):
    d = {"Type": "PSGroupSpecifier", "Title": title}
    if footer:
        d["FooterText"] = footer
    return d

def child(title, file):
    return {"Type": "PSChildPaneSpecifier", "Title": title, "File": file}

def write(name, specs, title=None):
    d = {"PreferenceSpecifiers": specs}
    if title:
        d["Title"] = title
    with open(os.path.join(OUT, name + ".plist"), "wb") as f:
        plistlib.dump(d, f, fmt=plistlib.FMT_XML)

FAMILIES = ["ASCW3", "Amiri", "Cairo", "Caladea", "Carlito", "DejaVu", "Liberation", "Montserrat", "Noto Naskh Arabic",
            "Open Sans", "Roboto", "Tajawal"]

def fonts():
    fam = collections.OrderedDict()
    for f in sorted(glob.glob(os.path.join(ROOT, "fonts-src", "*.ttf"))):
        n = TTFont(f, lazy=True)["name"]
        name = (n.getDebugName(1) or "").strip()
        family = next((k for k in FAMILIES if name.startswith(k)), None)
        if not family:
            raise SystemExit("font family without a licence entry: " + name)
        cr = " ".join((n.getDebugName(0) or "").split()).replace("©", "(c)").replace("�", "(c)")
        fam.setdefault(family, set()).add(cr)
    out = []
    for family, crs in fam.items():
        lic = next(l for k, l in FONT_LICENCE if family.startswith(k))
        out.append(group("Font: " + family, " ".join(sorted(crs)) + " Licence: " + lic + "."))
    return out

def main():
    os.makedirs(OUT, exist_ok=True)
    write("Root", [
        group("Xrero Office " + VERSION, "Free, open-source office suite for documents, spreadsheets and presentations. "
              "Arabic-first, works fully offline. Source code: " + SOURCE),
        child("Licences", "Licences"),
    ])
    specs = [
        group("Xrero Office", "Copyright (c) 2026 Xrero. Free software under the GNU Affero General Public License v3 "
              "(AGPL-3.0). Complete source code of this app: " + SOURCE),
        group("ONLYOFFICE Docs editors", "Document, spreadsheet and presentation editors. Copyright (c) Ascensio System SIA. "
              "AGPL-3.0. https://github.com/ONLYOFFICE/web-apps and https://github.com/ONLYOFFICE/sdkjs. Modified by Xrero "
              "(Arabic text handling, branding, iPhone/iPad integration); the modified source is part of " + SOURCE),
        group("ONLYOFFICE document converter (x2t) for WebAssembly", "Copyright (c) Ascensio System SIA; WebAssembly build by "
              "the CryptPad project. AGPL-3.0. https://github.com/ONLYOFFICE/core and https://github.com/cryptpad/onlyoffice-x2t-wasm"),
    ] + fonts() + [
        group("Licence texts"),
        child("GNU Affero General Public License v3", "AGPL"),
        child("GNU General Public License v2", "GPL2"),
        child("SIL Open Font License 1.1", "OFL"),
        child("Apache License 2.0", "Apache"),
        child("Bitstream Vera / DejaVu licence", "DejaVu"),
    ]
    write("Licences", specs, "Licences")
    for name, title, file in [("AGPL", "GNU AGPL v3", "AGPL-3.0.txt"), ("GPL2", "GNU GPL v2", "GPL-2.0.txt"),
                              ("OFL", "SIL OFL 1.1", "OFL-1.1.txt"), ("Apache", "Apache 2.0", "Apache-2.0.txt"),
                              ("DejaVu", "DejaVu", "DejaVu.txt")]:
        write(name, [group("", text(file))], title)
    print("Settings.bundle", VERSION, sorted(os.listdir(OUT)))
    for s in specs:
        if s.get("FooterText"):
            print(" -", s["Title"], "|", s["FooterText"][:150])

if __name__ == "__main__":
    main()
