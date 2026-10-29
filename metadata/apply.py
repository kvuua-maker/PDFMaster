#!/usr/bin/env python3
"""Fill App Store Connect metadata for the uk localization and attach the build."""
import json, os, subprocess, sys, urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
TOKEN = os.environ["ASC_TOKEN"]
DESC = open("metadata/description-uk.txt", encoding="utf-8").read().strip()
KEYWORDS = "pdf,сканер,ocr,редактор,pdf-конвертер,підпис,word,excel,документ,об'єднати,пароль,файли"
SUBTITLE = "Сканер, OCR і PDF-редактор"
SUPPORT = "https://kvuua-maker.github.io/PDFMaster/support.html"
PRIVACY = "https://kvuua-maker.github.io/PDFMaster/privacy.html"
PROMO = "Скануйте документи, розпізнавайте текст, конвертуйте Word та Excel у PDF і підписуйте — швидко й безпечно."


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
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def find_app():
    code, d = call("GET", "/apps?filter%5BbundleId%5D=com.kvuua.pdfmaster")
    return d["data"][0]["id"]


def find_version(app_id):
    code, d = call("GET", f"/apps/{app_id}/appStoreVersions?filter%5Bplatform%5D=IOS")
    return d["data"][0]["id"], d["data"][0]["attributes"].get("versionString")


def find_loc(version_id):
    code, d = call("GET", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations")
    for loc in d["data"]:
        if loc["attributes"]["locale"] == "uk":
            return loc["id"]
    return d["data"][0]["id"]


def find_info_loc(app_id):
    code, d = call("GET", f"/apps/{app_id}/appInfos")
    info_id = d["data"][0]["id"]
    code, d = call("GET", f"/appInfos/{info_id}/appInfoLocalizations")
    for loc in d["data"]:
        if loc["attributes"]["locale"] == "uk":
            return loc["id"]
    return d["data"][0]["id"]


def attach_build(version_id):
    code, d = call("GET", f"/builds?filter%5Bapp%5D={app_id}&limit=5&sort=-version")
    builds = d.get("data", [])
    for b in builds:
        print("  build", b["attributes"]["version"], "id", b["id"])
    # pick the highest build number
    target = max(builds, key=lambda b: int(b["attributes"]["version"])) if builds else None
    if not target:
        print("  no builds found")
        return None
    code, d = call("GET", f"/appStoreVersions/{version_id}/relationships/build")
    current = (d.get("data") or {}).get("id")
    print("  currently attached:", current)
    if current != target["id"]:
        code, d = call("PATCH", f"/appStoreVersions/{version_id}/relationships/build",
                       {"data": {"type": "builds", "id": target["id"]}})
        print("  attach ->", code, d.get("errors") or "ok")
    return target["attributes"]["version"]


app_id = find_app()
version_id, version_string = find_version(app_id)
loc_id = find_loc(version_id)
info_loc_id = find_info_loc(app_id)
print("app", app_id, "| version", version_string, "| loc", loc_id, "| infoLoc", info_loc_id)

code, d = call("PATCH", f"/appStoreVersionLocalizations/{loc_id}", {
    "data": {"type": "appStoreVersionLocalizations", "id": loc_id, "attributes": {
        "description": DESC, "keywords": KEYWORDS, "supportUrl": SUPPORT, "promotionalText": PROMO,
    }}
})
print("version localization ->", code, d.get("errors") or "ok")

code, d = call("PATCH", f"/appInfoLocalizations/{info_loc_id}", {
    "data": {"type": "appInfoLocalizations", "id": info_loc_id, "attributes": {
        "subtitle": SUBTITLE, "privacyPolicyUrl": PRIVACY,
    }}
})
print("app info localization ->", code, d.get("errors") or "ok")

print("build attach:")
attached = attach_build(version_id)
print("RESULT build attached:", attached)

code, d = call("GET", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations")
loc = [x for x in d["data"] if x["id"] == loc_id][0]["attributes"]
print("verify description chars:", len(loc.get("description") or ""))
print("verify keywords:", loc.get("keywords"))
print("verify supportUrl:", loc.get("supportUrl"))
