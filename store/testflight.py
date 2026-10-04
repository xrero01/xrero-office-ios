"""testflight.py <AuthKey .p8> [build number] - after an appstore-ios upload: waits until App Store Connect has
processed the build, makes it available to the internal TestFlight group "Xrero team" (created on first use; every
App Store Connect user with the Account Holder / Admin role is added as a tester) and selects the build for the
iOS version being prepared. Does NOT submit anything for review."""
import sys, time
import upload_listing as U

GROUP = "Xrero team"

def main():
    want = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else None
    app_id = U.must(*U.api("GET", "/v1/apps?filter[bundleId]=com.xrero.office"), "find app")["data"][0]["id"]
    for i in range(90):                                     # up to ~45 min
        builds = U.must(*U.api("GET", f"/v1/builds?filter[app]={app_id}&sort=-uploadedDate&limit=5"), "builds")["data"]
        b = next((x for x in builds if want is None or x["attributes"]["version"] == want), None)
        state = b["attributes"]["processingState"] if b else "NOT_SEEN_YET"
        print(time.strftime("%H:%M:%S"), "build", want or (b and b["attributes"]["version"]), state, flush=True)
        if state in ("VALID", "FAILED", "INVALID"):
            break
        time.sleep(30)
    if state != "VALID":
        raise SystemExit("build not usable: " + state)
    bid = b["id"]

    # internal group with access to every build
    groups = U.must(*U.api("GET", f"/v1/apps/{app_id}/betaGroups"), "groups")["data"]
    g = next((x for x in groups if x["attributes"]["name"] == GROUP), None)
    if not g:
        g = U.must(*U.api("POST", "/v1/betaGroups", {"data": {"type": "betaGroups", "attributes": {
            "name": GROUP, "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}}), "create group")["data"]
    print("group", g["attributes"]["name"], g["id"])

    # testers: the team's App Store Connect users with the Account Holder / Admin role
    users = U.must(*U.api("GET", "/v1/users?limit=50"), "users")["data"]
    have = {t["attributes"].get("email", "").lower() for t in U.must(*U.api("GET", f"/v1/betaGroups/{g['id']}/betaTesters"), "testers")["data"]}
    for u in users:
        a = u["attributes"]
        if not set(a.get("roles", [])) & {"ACCOUNT_HOLDER", "ADMIN"} or a["username"].lower() in have:
            continue
        st, r = U.api("POST", "/v1/betaTesters", {"data": {"type": "betaTesters", "attributes": {
            "email": a["username"], "firstName": a.get("firstName", ""), "lastName": a.get("lastName", "")},
            "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": g["id"]}]}}}})
        print("tester", a.get("firstName"), a.get("lastName"), "added" if st in (200, 201) else ("HTTP %s %s" % (st, r)))

    # select this build for the version being prepared (still not submitted)
    vers = U.must(*U.api("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS"), "versions")["data"]
    ver = next(v for v in vers if v["attributes"]["appStoreState"] in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"))
    U.must(*U.api("PATCH", f"/v1/appStoreVersions/{ver['id']}/relationships/build", {"data": {"type": "builds", "id": bid}}), "select build")
    print("version", ver["attributes"]["versionString"], "now uses build", b["attributes"]["version"], "- not submitted for review")

if __name__ == "__main__":
    main()
