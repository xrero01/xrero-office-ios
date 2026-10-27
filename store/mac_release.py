#!/usr/bin/env python3
"""mac_release.py <AuthKey .p8> <build number> <version> [--yes]

Puts a processed Mac App Store build on the macOS App Store version of Xrero Office and sends it to App Review:
  1. waits until the macOS build is VALID;
  2. if the macOS version is still waiting for / in review with an older build, withdraws it from review
     (the developer's own "Remove from Review" - nothing is rejected by Apple);
  3. renames the version to <version>, selects the build, adds the account paragraph to the review notes;
  4. with --yes: submits it for review (otherwise stops before submitting)."""
import sys, time
import upload_listing as U

BUILD, VERSION = sys.argv[2], sys.argv[3]
YES = "--yes" in sys.argv
ACCOUNT_NOTE = (
    "\n\nXRERO ACCOUNT (optional, new in 20.1)\n"
    "On first launch a card offers an optional Xrero account (email + password, the same account as Xrero Office for "
    "Windows and iPhone). \"Continue without an account\" skips it; every feature works without an account and all "
    "documents stay on the Mac. An account can be created in the app (Create account), and deleted in the app: start "
    "page > account button (top corner) or the editor's account menu > Delete account (asks for the password). "
    "No third-party sign-in is offered. No demo account is needed; you can create one in the app if you wish.")


def api(method, path, body=None, what=""):
    return U.must(*U.api(method, path, body), what or path)


def main():
    app_id = api("GET", "/v1/apps?filter[bundleId]=com.xrero.office")["data"][0]["id"]

    # 1. the build
    for i in range(90):
        bs = api("GET", f"/v1/builds?filter[app]={app_id}&filter[version]={BUILD}&include=preReleaseVersion&limit=5")
        b = next(iter(bs["data"]), None)
        state = b["attributes"]["processingState"] if b else "NOT_SEEN_YET"
        print(time.strftime("%H:%M:%S"), "mac build", BUILD, state, flush=True)
        if state in ("VALID", "FAILED", "INVALID"):
            break
        time.sleep(30)
    if state != "VALID":
        raise SystemExit("build not usable: " + state)
    plat = [x["attributes"].get("platform") for x in bs.get("included", [])]
    print("pre-release platform:", plat)

    # 2. the macOS version; withdraw it from review if needed
    def mac_version():
        vs = api("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=MAC_OS&limit=10")["data"]
        live = [v for v in vs if v["attributes"]["appStoreState"] not in ("READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION",
                                                                            "REMOVED_FROM_SALE")]
        return live[0] if live else None
    v = mac_version()
    if not v:
        raise SystemExit("no editable macOS version")
    print("macOS version", v["attributes"]["versionString"], v["attributes"]["appStoreState"])
    if v["attributes"]["appStoreState"] in ("WAITING_FOR_REVIEW", "IN_REVIEW"):
        subs = api("GET", f"/v1/reviewSubmissions?filter[app]={app_id}&filter[platform]=MAC_OS&limit=20")["data"]
        for s in subs:
            if s["attributes"]["state"] in ("WAITING_FOR_REVIEW", "IN_REVIEW", "READY_FOR_REVIEW"):
                print("withdrawing review submission", s["id"], s["attributes"]["state"])
                api("PATCH", f"/v1/reviewSubmissions/{s['id']}",
                    {"data": {"type": "reviewSubmissions", "id": s["id"], "attributes": {"canceled": True}}}, "cancel")
        for i in range(40):
            time.sleep(15)
            v = mac_version()
            print("  version state:", v["attributes"]["appStoreState"], flush=True)
            if v["attributes"]["appStoreState"] in ("DEVELOPER_REJECTED", "PREPARE_FOR_SUBMISSION"):
                break
        else:
            raise SystemExit("the version did not leave review")

    # 3. version number, build, review notes
    vid = v["id"]
    if v["attributes"]["versionString"] != VERSION:
        api("PATCH", f"/v1/appStoreVersions/{vid}", {"data": {"type": "appStoreVersions", "id": vid,
            "attributes": {"versionString": VERSION}}}, "rename version")
        print("version renamed to", VERSION)
    api("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build", {"data": {"type": "builds", "id": b["id"]}}, "select build")
    print("build", BUILD, "selected")
    rd = api("GET", f"/v1/appStoreVersions/{vid}/appStoreReviewDetail")["data"]
    if rd:
        notes = rd["attributes"].get("notes") or ""
        if "XRERO ACCOUNT (optional" not in notes:
            notes = (notes.rstrip() + ACCOUNT_NOTE)[:4000]
            api("PATCH", f"/v1/appStoreReviewDetails/{rd['id']}", {"data": {"type": "appStoreReviewDetails",
                "id": rd["id"], "attributes": {"notes": notes}}}, "review notes")
            print("review notes: account paragraph added (%d chars)" % len(notes))
    if not YES:
        print("ready - not submitted (run with --yes)")
        return

    # 4. submit
    subs = api("GET", f"/v1/reviewSubmissions?filter[app]={app_id}&filter[platform]=MAC_OS&filter[state]=READY_FOR_REVIEW&limit=5")["data"]
    sub = subs[0] if subs else api("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions",
        "attributes": {"platform": "MAC_OS"}, "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}},
        "new submission")["data"]
    items = api("GET", f"/v1/reviewSubmissions/{sub['id']}/items")["data"]
    if not items:
        api("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub["id"]}},
            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}}, "add version")
    r = api("PATCH", f"/v1/reviewSubmissions/{sub['id']}", {"data": {"type": "reviewSubmissions", "id": sub["id"],
        "attributes": {"submitted": True}}}, "submit")
    print("review submission", sub["id"], "state:", r["data"]["attributes"]["state"])
    time.sleep(5)
    print("version state:", mac_version()["attributes"]["appStoreState"])


if __name__ == "__main__":
    main()
