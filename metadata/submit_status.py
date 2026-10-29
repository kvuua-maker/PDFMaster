#!/usr/bin/env python3
"""Add the version and purchase to the draft submission, then submit it."""
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
            return e.code, {"raw": raw.decode(errors="ignore")[:500]}


def dump(label, code, d):
    print(f"{label} -> {code}")
    if code in (200, 201):
        print("   ok", json.dumps(d.get("data", {}).get("id", ""))[:120])
        return
    for e in (d.get("errors") or [])[:4]:
        print("   ", e.get("code"), "|", e.get("detail"))
        for path, items in (e.get("meta") or {}).get("associatedErrors", {}).items():
            for a in items:
                print("      ", path, "->", a.get("code"), "|", a.get("title"))


code, d = call("GET", f"/v1/apps/{APP}/appStoreVersions?filter%5Bplatform%5D=IOS")
version = d["data"][0]
VID = version["id"]
print("version:", version["attributes"]["versionString"], version["attributes"]["appStoreState"], VID)

code, d = call("GET", f"/v1/apps/{APP}/inAppPurchasesV2?limit=10")
IAP = next((i["id"] for i in d.get("data") or []
            if i["attributes"].get("productId") == "com.kvuua.pdfmaster.pro"), None)
print("purchase:", IAP)

code, d = call("GET", f"/v1/reviewSubmissions/{SUB}?include=items")
print("submission state:", (d.get("data") or {}).get("attributes", {}).get("state"))
existing = [i["type"] for i in (d.get("included") or [])]
print("existing items:", existing)

if "appStoreVersions" not in existing:
    code, d = call("POST", "/v1/reviewSubmissionItems", {"data": {
        "type": "reviewSubmissionItems",
        "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": SUB}},
            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": VID}}}}})
    dump("add version item", code, d)

for rel in ["inAppPurchaseVersion", "inAppPurchase", "inAppPurchaseV2"]:
    code, d = call("POST", "/v1/reviewSubmissionItems", {"data": {
        "type": "reviewSubmissionItems",
        "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": SUB}},
            rel: {"data": {"type": "inAppPurchases", "id": IAP}}}}})
    dump(f"add purchase item as {rel}", code, d)
    if code == 201:
        break

code, d = call("GET", f"/v1/reviewSubmissions/{SUB}?include=items")
print("items now:", [i["type"] for i in (d.get("included") or [])])

if SUBMIT:
    code, d = call("PATCH", f"/v1/reviewSubmissions/{SUB}",
                   {"data": {"type": "reviewSubmissions", "id": SUB, "attributes": {"submitted": True}}})
    dump("SUBMIT", code, d)
    code, d = call("GET", f"/v1/reviewSubmissions/{SUB}")
    print("final state:", (d.get("data") or {}).get("attributes", {}).get("state"))
