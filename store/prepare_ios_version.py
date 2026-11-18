"""prepare_ios_version.py <AuthKey .p8> [--build N] [--release AFTER_APPROVAL|MANUAL] [--dry-run]
Prepares the iOS App Store version named by app/project.yml MARKETING_VERSION (21.0 on): creates it when it does not
exist yet (App Store Connect copies the live version's texts, screenshots and review details into it), sets its release
type, writes the version texts of store/listing.json for en-US and ar-SA (description, keywords, promotional text,
What's New; support / marketing URLs unchanged) and, with --build, attaches that processed build of this version.
Never submits for review (store/submit_review.py does that, only after the owner's OK), never touches the app-level
information, the age rating, the screenshots or the review details (contact, notes, demo account)."""
import json, sys
import upload_listing as U

LOCALES = ("en-US", "ar-SA")
TEXTS = ("description", "keywords", "promotionalText", "whatsNew")
EDITABLE = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED")


def arg(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def main():
    dry = "--dry-run" in sys.argv
    release = arg("--release", "AFTER_APPROVAL")
    build_no = arg("--build")
    L = U.L["localizations"]
    for loc in LOCALES:                                   # App Store Connect limits
        t = L[loc]
        assert len(t["keywords"]) <= 100, (loc, "keywords", len(t["keywords"]))
        assert len(t["promotionalText"]) <= 170, (loc, "promotionalText", len(t["promotionalText"]))
        assert len(t["description"]) <= 4000 and len(t["whatsNew"]) <= 4000, loc
    app_id = U.must(*U.api("GET", "/v1/apps?filter[bundleId]=com.xrero.office"), "find app")["data"][0]["id"]
    vers = U.must(*U.api("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=20"), "versions")["data"]
    ver = next((v for v in vers if v["attributes"]["versionString"] == U.VERSION), None)
    if ver and ver["attributes"]["appStoreState"] not in EDITABLE:
        raise SystemExit("iOS %s exists and is not editable: %s" % (U.VERSION, ver["attributes"]["appStoreState"]))
    other = [v for v in vers if v["attributes"]["appStoreState"] in EDITABLE and v["attributes"]["versionString"] != U.VERSION]
    if other:
        raise SystemExit("another iOS version is being prepared: " + other[0]["attributes"]["versionString"])
    if dry:
        print("dry run: would %s iOS %s (release %s) and set %s texts for %s%s" % (
            "update" if ver else "create", U.VERSION, release, "/".join(TEXTS), ", ".join(LOCALES),
            ", build " + build_no if build_no else ""))
        return
    if not ver:
        ver = U.must(*U.api("POST", "/v1/appStoreVersions", {"data": {"type": "appStoreVersions",
              "attributes": {"platform": "IOS", "versionString": U.VERSION, "releaseType": release},
              "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}}), "create version")["data"]
        print("created iOS", U.VERSION, ver["id"])
    vid = ver["id"]
    U.must(*U.api("PATCH", f"/v1/appStoreVersions/{vid}", {"data": {"type": "appStoreVersions", "id": vid,
           "attributes": {"releaseType": release}}}), "release type")
    vlocs = {l["attributes"]["locale"]: l for l in U.must(*U.api("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations"), "locs")["data"]}
    for loc in LOCALES:
        attrs = {k: L[loc][k] for k in TEXTS}
        if loc in vlocs:
            U.must(*U.api("PATCH", f"/v1/appStoreVersionLocalizations/{vlocs[loc]['id']}", {"data": {
                "type": "appStoreVersionLocalizations", "id": vlocs[loc]["id"], "attributes": attrs}}), "texts " + loc)
        else:
            attrs.update(locale=loc, supportUrl=U.L["app"]["supportUrl"], marketingUrl=U.L["app"]["marketingUrl"])
            U.must(*U.api("POST", "/v1/appStoreVersionLocalizations", {"data": {"type": "appStoreVersionLocalizations",
                   "attributes": attrs, "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}}),
                   "new texts " + loc)
        print("texts", loc, "set")
    if build_no:
        bs = U.must(*U.api("GET", f"/v1/builds?filter[app]={app_id}&filter[version]={build_no}"
                          f"&filter[preReleaseVersion.version]={U.VERSION}&filter[preReleaseVersion.platform]=IOS"), "build")["data"]
        if not bs or bs[0]["attributes"]["processingState"] != "VALID":
            raise SystemExit("build %s of %s is not processed (VALID) yet: %s" % (build_no, U.VERSION,
                             bs[0]["attributes"]["processingState"] if bs else "not found"))
        U.must(*U.api("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build", {"data": {"type": "builds", "id": bs[0]["id"]}}), "attach build")
        print("build", build_no, "attached")
    # read back what App Store Connect now holds
    v = U.must(*U.api("GET", f"/v1/appStoreVersions/{vid}?include=build"), "read back")
    a = v["data"]["attributes"]
    b = [i["attributes"]["version"] for i in v.get("included", []) if i["type"] == "builds"]
    print("iOS %s: state %s, release %s, build %s - NOT submitted" % (a["versionString"], a["appStoreState"], a["releaseType"], b[0] if b else "none"))
    for l in U.must(*U.api("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations"), "locs")["data"]:
        la = l["attributes"]
        same = all(la.get(k) == L[la["locale"]][k] for k in TEXTS) if la["locale"] in LOCALES else None
        print("  %s texts match store/listing.json: %s" % (la["locale"], same))


if __name__ == "__main__":
    main()
