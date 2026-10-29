#!/usr/bin/env python3
"""Attach the Pro purchase to the version through a draft review submission.

Apple's rule: the first non-consumable must be reviewed together with the app
version, so the only supported link is a review submission that contains both
items. This script builds that draft and leaves it unsubmitted.
"""
import json, os, urllib.request, urllib.error

API = "https://api.appstoreconnect.apple.com"
TOKEN = os.environ["ASC_TOKEN"]


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


def err(d):
    out = []
    for e in (d.get("errors") or [])[:3]:
        out.append(f"{e.get('code')}: {e.get('detail')}")
        for path, items in (e.get("meta") or {}).get("associatedErrors", {}).items():
            for a in items:
                out.append(f"   {path} -> {a.get('code')}: {a.get('title')}")
    return " | ".join(out)


APP = "6827264813"
code, d = call("GET", f"/v1/apps/{APP}/appStoreVersions?filter%5Bplatform%5D=IOS")
VER = d["data"][0]["id"]
print("version:", VER, d["data"][0]["attributes"]["versionString"])

code, d = call("GET", f"/v1/apps/{APP}/inAppPurchasesV2?limit=10")
IAP = None
for item in d.get("data") or []:
    if item["attributes"].get("productId") == "com.kvuua.pdfmaster.pro":
        IAP = item["id"]
print("purchase:", IAP)
if not IAP:
    raise SystemExit("purchase missing")

# 1. existing draft submission?
code, d = call("GET", f"/v1/apps/{APP}/reviewSubmissions?filter%5Bplatform%5D=IOS&limit=10")
sub_id = None
for s in d.get("data") or []:
    print("  existing submission:", s["id"], s["attributes"].get("state"))
    if s["attributes"].get("state") in ("READY_FOR_REVIEW", "UNRESOLVED_ISSUES", "COMPLETE"):
        sub_id = s["id"]

if not sub_id:
    code, d = call("POST", "/v1/reviewSubmissions", {"data": {
        "type": "reviewSubmissions", "attributes": {"platform": "IOS"},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
    print("create submission ->", code, err(d) if code != 201 else "ok")
    sub_id = (d.get("data") or {}).get("id")

print("submission id:", sub_id)
if not sub_id:
    raise SystemExit(1)

# 2. add the version and the purchase as items
for label, rel, typ, ident in [
    ("version", "appStoreVersion", "appStoreVersions", VER),
    ("purchase", "inAppPurchaseV2", "inAppPurchases", IAP),
]:
    code, d = call("POST", "/v1/reviewSubmissionItems", {"data": {
        "type": "reviewSubmissionItems",
        "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
            rel: {"data": {"type": typ, "id": ident}}}}})
    print(f"add {label} ->", code, err(d) if code != 201 else "ok")

# 3. read back
code, d = call("GET", f"/v1/reviewSubmissions/{sub_id}/items?include=appStoreVersion,inAppPurchaseV2")
print("items ->", code)
for item in (d.get("data") or []):
    print("  item", item["id"], json.dumps(item.get("relationships", {}), ensure_ascii=False)[:200])
code, d = call("GET", f"/v1/reviewSubmissions/{sub_id}")
print("submission state:", (d.get("data") or {}).get("attributes", {}).get("state"))
