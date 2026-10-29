#!/usr/bin/env python3
"""Create the Pro non-consumable, its uk localization, price and review screenshot."""
import json, os, urllib.request, urllib.error, urllib.parse

API = "https://api.appstoreconnect.apple.com/v1"
TOKEN = os.environ["ASC_TOKEN"]
PRODUCT_ID = "com.kvuua.pdfmaster.pro"
SCREENSHOT = "docs/iap-1024.png"


def call(method, path, body=None, raw_url=None):
    url = raw_url or (API + path)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            payload = r.read()
            return r.status, (json.loads(payload) if payload else {})
    except urllib.error.HTTPError as e:
        body_text = e.read()
        try:
            parsed = json.loads(body_text or b"{}")
        except Exception:
            parsed = {"raw": body_text.decode(errors="ignore")[:400]}
        return e.code, parsed


def show(label, code, d):
    errs = d.get("errors") if isinstance(d, dict) else None
    print(f"{label} -> HTTP {code}")
    if errs:
        for e in errs:
            print("   ", e.get("title"), "|", e.get("detail"))


code, d = call("GET", "/apps?filter%5BbundleId%5D=com.kvuua.pdfmaster")
app_id = d["data"][0]["id"]
print("app", app_id)

# 1. existing purchases
code, d = call("GET", f"/apps/{app_id}/inAppPurchasesV2?limit=50")
show("list inAppPurchasesV2", code, d)
iap_id = None
for item in (d.get("data") or []):
    print("   existing:", item["id"], item["attributes"].get("productId"), item["attributes"].get("state"))
    if item["attributes"].get("productId") == PRODUCT_ID:
        iap_id = item["id"]

if not iap_id:
    body = {"data": {"type": "inAppPurchases", "attributes": {
        "name": "PDF Master Pro",
        "productId": PRODUCT_ID,
        "inAppPurchaseType": "NON_CONSUMABLE",
        "reviewNote": "Unlocks unlimited Word/Excel conversion and removes the export watermark.",
    }, "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}}
    code, d = call("POST", "/inAppPurchases", body)
    show("create IAP", code, d)
    iap_id = (d.get("data") or {}).get("id")
print("iap id:", iap_id)
if not iap_id:
    raise SystemExit(1)

# 2. uk localization
code, d = call("GET", f"/inAppPurchases/{iap_id}/inAppPurchaseLocalizations")
show("list localizations", code, d)
existing_locales = {x["attributes"].get("locale") for x in (d.get("data") or [])}
if "uk" not in existing_locales:
    body = {"data": {"type": "inAppPurchaseLocalizations", "attributes": {
        "name": "PDF Master Pro",
        "description": "Безлімітна конвертація Word/Excel, експорт без водяних знаків, OCR та захист паролем назавжди.",
        "locale": "uk",
    }, "relationships": {"inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}}}}}
    code, d = call("POST", "/inAppPurchaseLocalizations", body)
    show("create uk localization", code, d)

# 3. price points for USA
code, d = call("GET", f"/inAppPurchases/{iap_id}/pricePoints?filter%5Bterritory%5D=USA&limit=200")
show("list price points", code, d)
point = None
for p in (d.get("data") or []):
    if p["attributes"].get("customerPrice") in ("7.99", "7.99 "):
        point = p
        break
print("chosen point:", point["id"] if point else None,
      point["attributes"].get("customerPrice") if point else None)

if point:
    body = {"data": {"type": "inAppPurchasePriceSchedules", "attributes": {"baseTerritory": "USA"},
                     "relationships": {
                         "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
                         "manualPrices": {"data": [{"type": "inAppPurchasePrices", "id": "${price1}"}]}}},
            "included": [{"type": "inAppPurchasePrices", "id": "${price1}",
                          "attributes": {"startDate": None},
                          "relationships": {
                              "inAppPurchasePricePoint": {"data": {"type": "inAppPurchasePricePoints", "id": point["id"]}},
                              "territory": {"data": {"type": "territories", "id": "USA"}}}}]}
    code, d = call("POST", "/inAppPurchasePriceSchedules", body)
    show("create price schedule", code, d)

# 4. review screenshot
size = os.path.getsize(SCREENSHOT)
body = {"data": {"type": "inAppPurchaseAppStoreReviewScreenshots",
                 "attributes": {"fileSize": size, "fileName": os.path.basename(SCREENSHOT)},
                 "relationships": {"inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}}}}}
code, d = call("POST", "/inAppPurchaseAppStoreReviewScreenshots", body)
show("create screenshot", code, d)
shot = (d.get("data") or {})
if shot.get("id"):
    ops = shot["attributes"].get("uploadOperations") or []
    with open(SCREENSHOT, "rb") as fh:
        blob = fh.read()
    for op in ops:
        headers = {h["name"]: h["value"] for h in op["requestHeaders"]}
        req = urllib.request.Request(op["url"], data=blob[op["offset"]:op["offset"] + op["length"]],
                                     method=op["method"])
        for k, v in headers.items():
            req.add_header(k, v)
        with urllib.request.urlopen(req) as r:
            print("   upload part ->", r.status)
    code, d = call("PATCH", f"/inAppPurchaseAppStoreReviewScreenshots/{shot['id']}",
                   {"data": {"type": "inAppPurchaseAppStoreReviewScreenshots", "id": shot["id"],
                             "attributes": {"uploaded": True}}})
    show("commit screenshot", code, d)

# 5. final state
code, d = call("GET", f"/inAppPurchases/{iap_id}?include=appStoreReviewScreenshot")
show("final state", code, d)
print("FINAL:", json.dumps(d.get("data", {}).get("attributes", {}), ensure_ascii=False))
