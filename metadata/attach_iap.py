#!/usr/bin/env python3
"""Discover and create the link between app version 1.0 and the Pro purchase."""
import json, os, urllib.request, urllib.error

API = "https://api.appstoreconnect.apple.com"
TOKEN = os.environ["ASC_TOKEN"]


def call(method, path, body=None):
    url = API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
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
    return " | ".join(f"{e.get('title')}: {e.get('detail')}" for e in (d.get("errors") or [])[:2])


code, d = call("GET", "/v1/apps/6827264813/appStoreVersions?filter%5Bplatform%5D=IOS")
ver_id = d["data"][0]["id"]
print("version:", ver_id, d["data"][0]["attributes"]["versionString"])

code, d = call("GET", "/v1/apps/6827264813/inAppPurchasesV2?limit=10")
iap_id = None
for item in d.get("data") or []:
    if item["attributes"].get("productId") == "com.kvuua.pdfmaster.pro":
        iap_id = item["id"]
        print("purchase:", iap_id, item["attributes"].get("state"))
if not iap_id:
    raise SystemExit("purchase not found")

probes = [
    ("GET", f"/v1/appStoreVersions/{ver_id}/inAppPurchases"),
    ("GET", f"/v1/appStoreVersions/{ver_id}/relationships/inAppPurchases"),
    ("GET", f"/v1/inAppPurchases/{iap_id}/appStoreVersion"),
    ("GET", f"/v1/appStoreVersions/{ver_id}/appStoreVersionInAppPurchases"),
    ("GET", f"/v1/inAppPurchases/{iap_id}/inAppPurchaseVersions"),
]
for method, path in probes:
    code, d = call(method, path)
    print(f"{path} -> {code}", err(d) if code != 200 else json.dumps(d)[:200])

# Ask Apple what fields the submission resource actually expects.
code, d = call("POST", "/v1/inAppPurchaseSubmissions", {"data": {"type": "inAppPurchaseSubmissions", "attributes": {}}})
print("schema probe ->", code, json.dumps(d, ensure_ascii=False)[:600])
for rel in ["inAppPurchaseV2", "inAppPurchase"]:
    body = {"data": {"type": "inAppPurchaseSubmissions", "relationships": {
        rel: {"data": {"type": "inAppPurchases", "id": iap_id}}}}}
    code, d = call("POST", "/v1/inAppPurchaseSubmissions", body)
    print(f"POST inAppPurchaseSubmissions ({rel}) ->", code,
          json.dumps(d, ensure_ascii=False)[:400] if code != 201 else "created")

# and check whether the version already exposes the purchase through the submission list
code, d = call("GET", f"/v1/apps/6827264813/inAppPurchaseSubmissions?limit=10")
print("GET inAppPurchaseSubmissions ->", code, err(d) if code != 200 else json.dumps(d)[:300])
