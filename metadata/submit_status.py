#!/usr/bin/env python3
"""Add the version (and the purchase, if Apple exposes it) to the draft and submit."""
import json, os, urllib.request, urllib.error

API = "https://api.appstoreconnect.apple.com"
TOKEN = os.environ["ASC_TOKEN"]
APP = "6827264813"
SUB = os.environ.get("SUB_ID", "f9e768ca-199c-42ca-9c17-bd0febd69c43")
SUBMIT = os.environ.get("SUBMIT", "1") == "1"


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except Exception:
            return e.code, {"raw": raw.decode(errors="ignore")[:300]}


def dump(label, code, d):
    print(f"{label} -> {code}")
    if code in (200, 201, 204):
        return True
    for e in (d.get("errors") or [])[:4]:
        print("   ", e.get("code"), "|", e.get("detail"))
        for path, items in (e.get("meta") or {}).get("associatedErrors", {}).items():
            for a in items:
                print("      ", path, "->", a.get("code"), "|", a.get("title"))
    return False


code, d = call("GET", f"/v1/apps/{APP}/appStoreVersions?filter%5Bplatform%5D=IOS")
version = d["data"][0]
VID = version["id"]
print("version:", version["attributes"]["versionString"], version["attributes"]["appStoreState"])

code, d = call("GET", f"/v1/appStoreVersions/{VID}/appStoreVersionLocalizations")
LOC = d["data"][0]["id"]
code, d = call("GET", f"/v1/appStoreVersionLocalizations/{LOC}/appScreenshotSets")
for s in d.get("data", []):
    kind = s["attributes"]["screenshotDisplayType"]
    code, shots = call("GET", f"/v1/appScreenshotSets/{s['id']}/appScreenshots?fields%5BappScreenshots%5D=fileName,assetDeliveryState")
    items = shots.get("data") or []
    print(f"{kind}: {len(items)} shots")
    for shot in items:
        st = shot["attributes"].get("assetDeliveryState") or {}
        print("   ", shot["attributes"]["fileName"], st.get("state"))
    stale = [sh for sh in items
             if (sh["attributes"].get("assetDeliveryState") or {}).get("state") in ("AWAITING_UPLOAD", "FAILED")]
    if not items or stale:
        for sh in stale:
            code, _ = call("DELETE", f"/v1/appScreenshots/{sh['id']}")
            print("   delete stale shot", sh["attributes"]["fileName"], "->", code)
        code, _ = call("DELETE", f"/v1/appScreenshotSets/{s['id']}")
        print("   delete set", kind, "->", code)

code, d = call("GET", f"/v1/apps/{APP}/inAppPurchasesV2?limit=10")
IAP = next((i["id"] for i in d.get("data") or []
            if i["attributes"].get("productId") == "com.kvuua.pdfmaster.pro"), None)
print("purchase:", IAP)

code, d = call("GET", f"/v1/reviewSubmissions/{SUB}?include=items")
print("existing items:", [i["type"] for i in (d.get("included") or [])])

code, d = call("POST", "/v1/reviewSubmissionItems", {"data": {
    "type": "reviewSubmissionItems",
    "relationships": {
        "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": SUB}},
        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": VID}}}}})
dump("add version item", code, d)

# the purchase link uses its own resource type
for candidate in [
    ("/v1/inAppPurchaseVersions?filter%5BinAppPurchase%5D=" + str(IAP), None),
    (f"/v1/inAppPurchases/{IAP}/inAppPurchaseVersions", None),
]:
    path, _ = candidate
    code, d = call("GET", path)
    print("probe", path, "->", code, json.dumps(d)[:160])
    ids = [x["id"] for x in (d.get("data") or [])]
    if ids:
        code, d = call("POST", "/v1/reviewSubmissionItems", {"data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": SUB}},
                "inAppPurchaseVersion": {"data": {"type": "inAppPurchaseVersions", "id": ids[0]}}}}})
        dump("add purchase item", code, d)
        break

code, d = call("GET", f"/v1/reviewSubmissions/{SUB}?include=items")
print("items now:", [i["type"] for i in (d.get("included") or [])])

if SUBMIT:
    code, d = call("PATCH", f"/v1/reviewSubmissions/{SUB}",
                   {"data": {"type": "reviewSubmissions", "id": SUB, "attributes": {"submitted": True}}})
    dump("SUBMIT", code, d)
    code, d = call("GET", f"/v1/reviewSubmissions/{SUB}")
    print("final state:", (d.get("data") or {}).get("attributes", {}).get("state"))
    code, d = call("GET", f"/v1/appStoreVersions/{VID}")
    print("version state:", (d.get("data") or {}).get("attributes", {}).get("appStoreState"))
