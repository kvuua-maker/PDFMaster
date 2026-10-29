#!/usr/bin/env python3
"""Final check of the Pro purchase using the v2 endpoints."""
import json, os, urllib.request, urllib.error

API = "https://api.appstoreconnect.apple.com"
TOKEN = os.environ["ASC_TOKEN"]


def call(path):
    req = urllib.request.Request(API + path)
    req.add_header("Authorization", "Bearer " + TOKEN)
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read()
            return r.status, (json.loads(body) if body else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except Exception:
            return e.code, {"raw": raw.decode(errors="ignore")[:200]}


code, d = call("/v2/apps/6827264813/inAppPurchases?limit=20")
print("v2 list ->", code)
iap_id = None
for item in (d.get("data") or []):
    a = item["attributes"]
    print("  ", item["id"], a.get("productId"), a.get("inAppPurchaseType"), a.get("state"), a.get("name"))
    iap_id = item["id"]

if not iap_id:
    raise SystemExit("no purchase found")

for include in ["inAppPurchaseLocalizations", "appStoreReviewScreenshot", "inAppPurchasePriceSchedule"]:
    code, d = call(f"/v2/inAppPurchases/{iap_id}?include={include}")
    print(f"detail include={include} -> {code}")
    if code != 200:
        for e in (d.get("errors") or [])[:1]:
            print("   ", e.get("detail"))
        continue
    attrs = (d.get("data") or {}).get("attributes", {})
    print("   attributes:", json.dumps(attrs, ensure_ascii=False)[:300])
    for inc in (d.get("included") or []):
        print("   included:", inc["type"], inc["id"],
              json.dumps(inc.get("attributes", {}), ensure_ascii=False)[:220])

code, d = call(f"/v1/inAppPurchasePriceSchedules?filter%5BinAppPurchase%5D={iap_id}&include=manualPrices")
print("price schedule ->", code)
if code == 200:
    for inc in (d.get("included") or [])[:5]:
        print("   price:", inc["id"], json.dumps(inc.get("attributes", {}), ensure_ascii=False)[:200])
