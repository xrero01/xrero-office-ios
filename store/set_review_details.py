"""set_review_details.py <AuthKey .p8> <review-contact.json> - App Review contact + notes for the iOS version being
prepared. The contact (contactFirstName, contactLastName, contactPhone, contactEmail) lives in a private JSON file
outside this repo; the notes come from store/listing.json reviewNotes. No demo account: the app has no sign-in."""
import json, sys
import upload_listing as U

def main():
    contact = json.load(open(sys.argv[2], encoding="utf-8"))
    attrs = {k: contact[k] for k in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail")}
    attrs.update(demoAccountRequired=False, notes=U.L["reviewNotes"])
    app_id = U.must(*U.api("GET", "/v1/apps?filter[bundleId]=com.xrero.office"), "find app")["data"][0]["id"]
    vers = U.must(*U.api("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS"), "versions")["data"]
    ver = next(v for v in vers if v["attributes"]["appStoreState"] in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"))
    st, cur = U.api("GET", f"/v1/appStoreVersions/{ver['id']}/appStoreReviewDetail")
    if st == 200 and cur.get("data"):
        rid = cur["data"]["id"]
        res = U.must(*U.api("PATCH", f"/v1/appStoreReviewDetails/{rid}", {"data": {"type": "appStoreReviewDetails", "id": rid, "attributes": attrs}}), "update review details")
    else:
        res = U.must(*U.api("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
              "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver["id"]}}}}}), "create review details")
    a = res["data"]["attributes"]
    print("review details set for", ver["attributes"]["versionString"], "- demo account:", a.get("demoAccountRequired"), "- notes:", len(a.get("notes") or ""), "chars")

if __name__ == "__main__":
    main()
