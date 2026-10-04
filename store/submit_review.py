"""submit_review.py <AuthKey .p8> --yes - submits the prepared iOS version (with its selected build) to App Review.
Run ONLY after Moustafa approves the submission. Content rights: the app ships third-party material it is licensed to
use (open-licensed fonts, ONLYOFFICE AGPL code) -> USES_THIRD_PARTY_CONTENT (App Store Connect's "Yes, I have the rights")."""
import sys
import upload_listing as U

def main():
    if "--yes" not in sys.argv:
        raise SystemExit("refusing without --yes (submission needs Moustafa's approval)")
    app = U.must(*U.api("GET", "/v1/apps?filter[bundleId]=com.xrero.office"), "find app")["data"][0]
    app_id = app["id"]
    if app["attributes"].get("contentRightsDeclaration") != "USES_THIRD_PARTY_CONTENT":
        U.must(*U.api("PATCH", f"/v1/apps/{app_id}", {"data": {"type": "apps", "id": app_id, "attributes": {
            "contentRightsDeclaration": "USES_THIRD_PARTY_CONTENT"}}}), "content rights")
        print("content rights: uses third-party content (licensed)")
    vers = U.must(*U.api("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&include=build"), "versions")
    ver = next(v for v in vers["data"] if v["attributes"]["appStoreState"] in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"))
    builds = [i["attributes"]["version"] for i in vers.get("included", []) if i["type"] == "builds"]
    if not builds:
        raise SystemExit("no build selected for " + ver["attributes"]["versionString"])
    print("submitting", ver["attributes"]["versionString"], "build", builds[0])

    open_subs = [s for s in U.must(*U.api("GET", f"/v1/reviewSubmissions?filter[app]={app_id}&filter[platform]=IOS"), "submissions")["data"]
                 if s["attributes"]["state"] == "READY_FOR_REVIEW"]
    sub = open_subs[0] if open_subs else U.must(*U.api("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions",
          "attributes": {"platform": "IOS"}, "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}}), "create submission")["data"]
    items = U.must(*U.api("GET", f"/v1/reviewSubmissions/{sub['id']}/items"), "items")["data"]
    if not items:
        U.must(*U.api("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub["id"]}},
            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver["id"]}}}}}), "add version")
    res = U.must(*U.api("PATCH", f"/v1/reviewSubmissions/{sub['id']}", {"data": {"type": "reviewSubmissions", "id": sub["id"],
          "attributes": {"submitted": True}}}), "submit")
    print("review submission", sub["id"], "state:", res["data"]["attributes"]["state"])
    st = U.must(*U.api("GET", f"/v1/appStoreVersions/{ver['id']}"), "version")["data"]["attributes"]["appStoreState"]
    print("version state:", st)

if __name__ == "__main__":
    main()
