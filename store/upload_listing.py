"""upload_listing.py <AuthKey .p8> [--screens-only|--text-only]
Fills the App Store listing of Xrero Office (com.xrero.office) through the App Store Connect API from
store/listing.json + store/final/<en|ar>/<iphone|ipad>-NN.png: categories, version 20.0.9 + copyright,
EN + AR texts (name, subtitle, privacy URL, description, keywords, promotional text, URLs), age rating,
screenshots (6.9" iPhone + 13" iPad). Idempotent: re-running replaces the screenshots.
Left for the account holder in App Store Connect: price (Free), App Privacy ("Data Not Collected"), review contact."""
import base64, hashlib, json, os, sys, time, urllib.request, urllib.error
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

HERE = os.path.dirname(os.path.abspath(__file__))
KEY_FILE, KID, ISS = sys.argv[1], "43Y7PTLSWT", "57bafb2b-775d-4d48-b296-dd6787354a62"
MODE = sys.argv[2] if len(sys.argv) > 2 else ""
L = json.load(open(os.path.join(HERE, "listing.json"), encoding="utf-8"))
LOCALES = {"en-US": "en", "ar-SA": "ar"}
SCREEN_TYPES = {"iphone": "APP_IPHONE_67", "ipad": "APP_IPAD_PRO_3GEN_129"}

def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
_key = serialization.load_pem_private_key(open(KEY_FILE, "rb").read(), None)
def token():
    h = b64(json.dumps({"alg": "ES256", "kid": KID, "typ": "JWT"}).encode()); now = int(time.time())
    p = b64(json.dumps({"iss": ISS, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}).encode())
    r, s = decode_dss_signature(_key.sign((h + "." + p).encode(), ec.ECDSA(hashes.SHA256())))
    return h + "." + p + "." + b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))

def api(method, path, body=None):
    url = path if path.startswith("http") else "https://api.appstoreconnect.apple.com" + path
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, method=method,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")[:900]

def must(st, res, what):
    if st not in (200, 201, 204):
        raise SystemExit("%s failed: HTTP %s %s" % (what, st, res))
    return res

def main():
    st, res = api("GET", "/v1/apps?filter[bundleId]=com.xrero.office")
    apps = must(st, res, "find app").get("data", [])
    if not apps:
        raise SystemExit("No App Store Connect app record for com.xrero.office yet (create it: Apps > + > New App).")
    app_id = apps[0]["id"]; print("app", app_id, apps[0]["attributes"].get("name"))

    # ---- app info: categories + per-language name / subtitle / privacy policy
    infos = must(*api("GET", f"/v1/apps/{app_id}/appInfos"), "appInfos")["data"]
    info = next((i for i in infos if i["attributes"].get("appStoreState") in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", None)), infos[0])
    if MODE != "--screens-only":
        must(*api("PATCH", f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
            "primaryCategory": {"data": {"type": "appCategories", "id": L["app"]["primaryCategory"]}},
            "secondaryCategory": {"data": {"type": "appCategories", "id": L["app"]["secondaryCategory"]}}}}}), "categories")
        locs = {l["attributes"]["locale"]: l for l in must(*api("GET", f"/v1/appInfos/{info['id']}/appInfoLocalizations"), "info locs")["data"]}
        for loc in LOCALES:
            t = L["localizations"][loc]
            attrs = {"name": t["name"], "subtitle": t["subtitle"], "privacyPolicyUrl": L["app"]["privacyPolicyUrl"]}
            if loc in locs:
                must(*api("PATCH", f"/v1/appInfoLocalizations/{locs[loc]['id']}", {"data": {"type": "appInfoLocalizations", "id": locs[loc]["id"], "attributes": attrs}}), "info loc " + loc)
            else:
                must(*api("POST", "/v1/appInfoLocalizations", {"data": {"type": "appInfoLocalizations", "attributes": dict(attrs, locale=loc),
                     "relationships": {"appInfo": {"data": {"type": "appInfos", "id": info["id"]}}}}}), "new info loc " + loc)
            print("app info", loc, "ok")
        # age rating: nothing objectionable (an office suite)
        st, ar = api("GET", f"/v1/appInfos/{info['id']}/ageRatingDeclaration")
        if st == 200:
            # a new app's answers start empty (null): answer every question explicitly - an office suite: NONE / No
            freq = ["alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons", "medicalOrTreatmentInformation",
                    "profanityOrCrudeHumor", "sexualContentGraphicAndNudity", "sexualContentOrNudity", "horrorOrFearThemes", "matureOrSuggestiveThemes",
                    "violenceCartoonOrFantasy", "violenceRealisticProlongedGraphicOrSadistic", "violenceRealistic"]
            flags = ["advertising", "gambling", "healthOrWellnessTopics", "lootBox", "messagingAndChat", "parentalControls", "ageAssurance",
                     "socialMedia", "unrestrictedWebAccess", "userGeneratedContent"]
            have = ar["data"]["attributes"]
            a = {k: "NONE" for k in freq if k in have}
            a.update({k: False for k in flags if k in have})
            st2, r2 = api("PATCH", f"/v1/ageRatingDeclarations/{ar['data']['id']}", {"data": {"type": "ageRatingDeclarations", "id": ar["data"]["id"], "attributes": a}})
            print("age rating", st2 if st2 == 200 else ("needs a manual look: %s %s" % (st2, r2)))

    # ---- the version being prepared
    vers = must(*api("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS"), "versions")["data"]
    ver = next((v for v in vers if v["attributes"]["appStoreState"] in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED")), None)
    if not ver:
        raise SystemExit("no editable iOS version: " + ", ".join(v["attributes"]["versionString"] + "/" + v["attributes"]["appStoreState"] for v in vers))
    vid = ver["id"]
    if MODE != "--screens-only":
        must(*api("PATCH", f"/v1/appStoreVersions/{vid}", {"data": {"type": "appStoreVersions", "id": vid, "attributes": {
            "versionString": "20.0.9", "copyright": L["app"]["copyright"]}}}), "version")
    vlocs = {l["attributes"]["locale"]: l for l in must(*api("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations"), "version locs")["data"]}
    first_release = len(vers) == 1
    for loc, lang in LOCALES.items():
        t = L["localizations"][loc]
        attrs = {"description": t["description"], "keywords": t["keywords"], "promotionalText": t["promotionalText"],
                 "supportUrl": L["app"]["supportUrl"], "marketingUrl": L["app"]["marketingUrl"]}
        if not first_release:
            attrs["whatsNew"] = t["whatsNew"]
        if loc in vlocs:
            vl_id = vlocs[loc]["id"]
            if MODE != "--screens-only":
                must(*api("PATCH", f"/v1/appStoreVersionLocalizations/{vl_id}", {"data": {"type": "appStoreVersionLocalizations", "id": vl_id, "attributes": attrs}}), "texts " + loc)
        else:
            vl_id = must(*api("POST", "/v1/appStoreVersionLocalizations", {"data": {"type": "appStoreVersionLocalizations", "attributes": dict(attrs, locale=loc),
                         "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}}), "new texts " + loc)["data"]["id"]
        print("texts", loc, "ok")
        if MODE == "--text-only":
            continue
        # ---- screenshots
        sets = {s["attributes"]["screenshotDisplayType"]: s for s in must(*api("GET", f"/v1/appStoreVersionLocalizations/{vl_id}/appScreenshotSets"), "sets")["data"]}
        for device, stype in SCREEN_TYPES.items():
            files = sorted(f for f in os.listdir(os.path.join(HERE, "final", lang)) if f.startswith(device + "-") and f.endswith(".png"))
            if not files:
                continue
            if stype in sets:
                set_id = sets[stype]["id"]
                for old in must(*api("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots"), "old shots")["data"]:
                    api("DELETE", f"/v1/appScreenshots/{old['id']}")
            else:
                set_id = must(*api("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": stype},
                              "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": vl_id}}}}}), "new set")["data"]["id"]
            for f in files:
                path = os.path.join(HERE, "final", lang, f); data = open(path, "rb").read()
                shot = must(*api("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots", "attributes": {"fileName": f, "fileSize": len(data)},
                            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}}), "reserve " + f)["data"]
                for op in shot["attributes"]["uploadOperations"]:
                    chunk = data[op["offset"]:op["offset"] + op["length"]]
                    req = urllib.request.Request(op["url"], data=chunk, method=op["method"],
                                                 headers={h["name"]: h["value"] for h in op.get("requestHeaders", [])})
                    urllib.request.urlopen(req, timeout=300).read()
                must(*api("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"], "attributes": {
                    "uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}}), "commit " + f)
                print("  screenshot", loc, stype, f)
    print("done - remaining in App Store Connect: price Free, App Privacy 'Data Not Collected', review contact, build selection")

if __name__ == "__main__":
    main()
