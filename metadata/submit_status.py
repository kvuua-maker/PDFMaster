#!/usr/bin/env python3
"""Report screenshot states and try to submit the draft review submission."""
import json, os, sys, urllib.request, urllib.error

API = "https://api.appstoreconnect.apple.com"
TOKEN = os.environ["ASC_TOKEN"]
APP = "6827264813"
SUB = os.environ.get("SUB_ID", "f9e768ca-199c-42ca-9c17-bd0febd69c43")
SUBMIT = os.environ.get("SUBMIT", "0") == "1"


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
    return " | ".join(out) or json.dumps(d, ensure_ascii=False)[:300]


code, d = call("GET", f"/v1/apps/{APP}/appStoreVersions?filter%5Bplatform%5D=IOS")
version = d["data"][0]
VID = version["id"]
print("version:", VID, version["attributes"]["versionString"], version["attributes"]["appStoreState"])

code, d = call("GET", f"/v1/apps/{APP}/builds?limit=10&sort=-version")
print("builds:", [b["attributes"]["version"] for b in d.get("data", [])])
code, d = call("GET", f"/v1/appStoreVersions/{VID}/relationships/build")
print("attached build:", (d.get("data") or {}).get("id"))

code, d = call("GET", f"/v1/appStoreVersions/{VID}/appStoreVersionLocalizations")
LOC = d["data"][0]["id"]
code, d = call("GET", f"/v1/appStoreVersionLocalizations/{LOC}/appScreenshotSets")
sets = d.get("data", [])
print("screenshot sets:", [(s["attributes"]["screenshotDisplayType"], s["id"]) for s in sets])

pending = 0
for s in sets:
    code, d = call("GET", f"/v1/appScreenshotSets/{s['id']}/appScreenshots?fields%5BappScreenshots%5D=fileName,assetDeliveryState")
    for shot in d.get("data", []):
        state = (shot["attributes"].get("assetDeliveryState") or {}).get("state")
        errors = (shot["attributes"].get("assetDeliveryState") or {}).get("errors") or []
        print(f"  {s['attributes']['screenshotDisplayType']:>16} {shot['attributes']['fileName']:<28} {state}"
              + (f" errors={[e.get('code') for e in errors]}" if errors else ""))
        if state != "COMPLETE":
            pending += 1

print("pending assets:", pending)

code, d = call("GET", f"/v1/reviewSubmissions/{SUB}?include=items")
print("submission:", code, (d.get("data") or {}).get("attributes", {}).get("state"))
for item in (d.get("included") or []):
    print("  item:", item["type"], item["id"])

if SUBMIT and pending == 0:
    code, d = call("PATCH", f"/v1/reviewSubmissions/{SUB}",
                   {"data": {"type": "reviewSubmissions", "id": SUB, "attributes": {"submitted": True}}})
    print("SUBMIT ->", code, err(d))
    code, d = call("GET", f"/v1/reviewSubmissions/{SUB}")
    print("state after:", (d.get("data") or {}).get("attributes", {}).get("state"))
