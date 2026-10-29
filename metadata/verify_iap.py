#!/usr/bin/env python3
"""Report exactly what the Pro purchase currently has in App Store Connect."""
import json, os, urllib.request, urllib.error

API = "https://api.appstoreconnect.apple.com/v1"
TOKEN = os.environ["ASC_TOKEN"]


def call(path, raw=False):
    req = urllib.request.Request((path if raw else API + path))
    req.add_header("Authorization", "Bearer " + TOKEN)
    try:
        with urllib.request.urlopen(req) as r:
            payload = r.read()
            return r.status, (json.loads(payload) if payload else {})
    except urllib.error.HTTPError as e:
        raw_body = e.read()
        try:
            return e.code, json.loads(raw_body or b"{}")
        except Exception:
            return e.code, {"raw": raw_body.decode(errors="ignore")[:200]}


code, d = call("/apps?filter%5BbundleId%5D=com.kvuua.pdfmaster")
app_id = d["data"][0]["id"]

code, d = call(f"/apps/{app_id}/inAppPurchasesV2?limit=50")
print("=== purchases ===")
for item in (d.get("data") or []):
    attrs = item["attributes"]
    print(" id:", item["id"], "| product:", attrs.get("productId"),
          "| type:", attrs.get("inAppPurchaseType"), "| state:", attrs.get("state"),
          "| name:", attrs.get("name"))
    iap_id = item["id"]

code, d = call(f"/inAppPurchases/{iap_id}")
print("=== detail ===", code)
print(" attributes:", json.dumps((d.get("data") or {}).get("attributes", {}), ensure_ascii=False))

for label, path in [
    ("localizations", f"/inAppPurchases/{iap_id}/inAppPurchaseLocalizations"),
    ("localizations(v1 filter)", f"/inAppPurchaseLocalizations?filter%5BinAppPurchase%5D={iap_id}"),
    ("price points", f"/inAppPurchases/{iap_id}/pricePoints?filter%5Bterritory%5D=USA"),
    ("price schedule", f"/inAppPurchases/{iap_id}/inAppPurchasePriceSchedule"),
    ("screenshot(v2)", f"/inAppPurchases/{iap_id}/appStoreReviewScreenshot"),
    ("screenshot(v1)", f"/inAppPurchases/{iap_id}/appStoreReviewScreenshot"),
]:
    code, d = call(path)
    print(f"=== {label} -> {code}")
    if code == 200:
        data = d.get("data")
        if isinstance(data, list):
            for x in data[:5]:
                print("   ", x["id"], json.dumps(x.get("attributes", {}), ensure_ascii=False)[:220])
            print("   total:", len(data))
        elif isinstance(data, dict):
            print("   ", data.get("id"), json.dumps(data.get("attributes", {}), ensure_ascii=False)[:220])
    else:
        for e in (d.get("errors") or [])[:2]:
            print("   ", e.get("title"), "|", e.get("detail"))
