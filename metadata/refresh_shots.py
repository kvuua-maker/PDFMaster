#!/usr/bin/env python3
"""Delete and re-upload the screenshots so Apple's Asset Library re-validates them."""
import json, os, urllib.request, urllib.error

API = "https://api.appstoreconnect.apple.com"
TOKEN = os.environ["ASC_TOKEN"]
APP = "6827264813"


def call(method, path, body=None, url=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url or (API + path), data=data, method=method)
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


code, d = call("GET", f"/v1/apps/{APP}/appStoreVersions?filter%5Bplatform%5D=IOS")
VID = d["data"][0]["id"]
code, d = call("GET", f"/v1/appStoreVersions/{VID}/appStoreVersionLocalizations")
LOC = d["data"][0]["id"]
code, d = call("GET", f"/v1/appStoreVersionLocalizations/{LOC}/appScreenshotSets")
sets = {s["attributes"]["screenshotDisplayType"]: s["id"] for s in d.get("data", [])}
print("sets:", sets)

SET_ID = sets.get("APP_IPHONE_61") or sets.get("APP_IPHONE_67")
if not SET_ID:
    code, d = call("POST", "/v1/appScreenshotSets", {"data": {
        "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": "APP_IPHONE_61"},
        "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": LOC}}}}})
    SET_ID = (d.get("data") or {}).get("id")
    print("created set:", SET_ID)

code, d = call("GET", f"/v1/appScreenshotSets/{SET_ID}/appScreenshots")
for shot in d.get("data", []):
    code_del, _ = call("DELETE", f"/v1/appScreenshots/{shot['id']}")
    print("delete", shot["attributes"]["fileName"], "->", code_del)

files = sorted(f"docs/shots-61/{n}" for n in os.listdir("docs/shots-61") if "-uk-" in n)
print("uploading:", files)
for path in files:
    size = os.path.getsize(path)
    name = os.path.basename(path)
    code, d = call("POST", "/v1/appScreenshots", {"data": {
        "type": "appScreenshots", "attributes": {"fileSize": size, "fileName": name},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": SET_ID}}}}})
    if code != 201:
        print("create", name, "->", code, json.dumps(d)[:200])
        continue
    shot = d["data"]
    blob = open(path, "rb").read()
    for op in shot["attributes"].get("uploadOperations", []):
        req = urllib.request.Request(op["url"], data=blob[op["offset"]:op["offset"] + op["length"]], method=op["method"])
        for h in op["requestHeaders"]:
            req.add_header(h["name"], h["value"])
        urllib.request.urlopen(req).read()
    code, d = call("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {
        "type": "appScreenshots", "id": shot["id"], "attributes": {"uploaded": True}}})
    print("uploaded", name, "->", code)

code, d = call("GET", f"/v1/appScreenshotSets/{SET_ID}/appScreenshots?fields%5BappScreenshots%5D=fileName,assetDeliveryState")
for shot in d.get("data", []):
    state = (shot["attributes"].get("assetDeliveryState") or {})
    print("  state:", shot["attributes"]["fileName"], state.get("state"), state.get("errors"))
