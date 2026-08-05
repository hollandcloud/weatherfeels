#!/usr/bin/env python3
"""Push the store listing in Store/ to App Store Connect.

Needs an App Store Connect API key with App Manager rights:

    export ASC_KEY_ID=XXXXXXXXXX          # the .p8's key id
    export ASC_ISSUER_ID=<uuid>           # Users and Access -> Integrations
    # key read from ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8

Then:

    Tools/asc.py status                   # what ASC currently has. Run this first.
    Tools/asc.py text                     # name, subtitle, description, keywords, URLs
    Tools/asc.py screenshots              # upload Store/screenshots/<platform>/
    Tools/asc.py all

`status` is read-only and is the only way to confirm two things this script cannot
know on its own: whether the tvOS and macOS platforms exist on the app record yet, and
what screenshot display types ASC wants for each of them. Two of the display-type
constants below are educated guesses — Apple has renamed them before — so check them
against `status` output before trusting `screenshots`.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
from base64 import urlsafe_b64encode
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils as asym_utils

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "net.hlnd.weatherstar"
ROOT = Path(__file__).resolve().parent.parent
STORE = ROOT / "Store"
LOCALE = "en-US"

# ASC platform values, and the directory under Store/screenshots each one draws from.
PLATFORMS = {
    "IOS": ["iphone", "ipad"],
    "TV_OS": ["tvos"],
    "MAC_OS": ["mac"],
}

# `appScreenshotSet.screenshotDisplayType` per directory.
#
# APP_APPLE_TV and APP_DESKTOP are stable. The other two are the ones to verify with
# `status`: Apple folded the 6.9" iPhone into the 6.7" slot rather than adding a new
# type, and the iPad 13" slot has carried more than one name.
DISPLAY_TYPES = {
    "iphone": "APP_IPHONE_67",
    "ipad": "APP_IPAD_PRO_3GEN_129",
    "tvos": "APP_APPLE_TV",
    "mac": "APP_DESKTOP",
}


def token() -> str:
    key_id = os.environ.get("ASC_KEY_ID")
    issuer = os.environ.get("ASC_ISSUER_ID")
    if not key_id or not issuer:
        sys.exit("set ASC_KEY_ID and ASC_ISSUER_ID (see the docstring)")

    path = Path(
        os.environ.get(
            "ASC_KEY_PATH",
            Path.home() / ".appstoreconnect/private_keys" / f"AuthKey_{key_id}.p8",
        )
    )
    if not path.exists():
        sys.exit(f"no private key at {path}")

    key = serialization.load_pem_private_key(path.read_bytes(), password=None)

    def segment(payload: dict) -> bytes:
        raw = json.dumps(payload, separators=(",", ":")).encode()
        return urlsafe_b64encode(raw).rstrip(b"=")

    header = segment({"alg": "ES256", "kid": key_id, "typ": "JWT"})
    now = int(time.time())
    claims = segment(
        {"iss": issuer, "iat": now, "exp": now + 20 * 60, "aud": "appstoreconnect-v1"}
    )
    signing_input = header + b"." + claims

    # ASC wants JOSE (r || s), not the DER sequence `cryptography` returns.
    der = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = asym_utils.decode_dss_signature(der)
    jose = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return (signing_input + b"." + urlsafe_b64encode(jose).rstrip(b"=")).decode()


JWT = None


def call(method: str, path: str, body: dict | None = None, raw: bytes | None = None,
         headers: dict | None = None) -> dict:
    global JWT
    if JWT is None:
        JWT = token()

    url = path if path.startswith("http") else API + path
    data = raw if raw is not None else (json.dumps(body).encode() if body else None)
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {JWT}")
    if raw is None and data:
        request.add_header("Content-Type", "application/json")
    for name, value in (headers or {}).items():
        request.add_header(name, value)

    try:
        with urllib.request.urlopen(request) as response:
            payload = response.read()
            return json.loads(payload) if payload else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        # ASC's errors are specific and worth showing verbatim — they name the field.
        sys.exit(f"{method} {url}\n  HTTP {error.code}\n  {detail}")


def read(name: str) -> str | None:
    path = STORE / "metadata" / LOCALE / f"{name}.txt"
    return path.read_text().strip() if path.exists() else None


def app_id() -> str:
    apps = call("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not apps:
        sys.exit(f"no app record for {BUNDLE_ID}")
    return apps[0]["id"]


def status() -> None:
    app = app_id()
    info = call("GET", f"/v1/apps/{app}")["data"]["attributes"]
    print(f"app {app}  {info.get('name')}  sku={info.get('sku')}")
    print(f"  primary locale: {info.get('primaryLocale')}")

    versions = call(
        "GET",
        f"/v1/apps/{app}/appStoreVersions?limit=200"
        "&fields[appStoreVersions]=platform,versionString,appStoreState,createdDate",
    )["data"]
    seen = set()
    print("\n  versions:")
    for version in versions:
        attributes = version["attributes"]
        seen.add(attributes["platform"])
        print(
            f"    {attributes['platform']:<7} {attributes['versionString']:<6} "
            f"{attributes['appStoreState']:<28} {version['id']}"
        )
    missing = set(PLATFORMS) - seen
    if missing:
        print(
            f"\n  NO VERSION FOR: {', '.join(sorted(missing))}"
            "\n  A platform has to be added to the app record in App Store Connect"
            "\n  (App Store tab -> the + beside iOS App) before builds or metadata for"
            "\n  it are accepted. That cannot be done through this API."
        )

    print("\n  existing screenshot sets (confirm DISPLAY_TYPES against these):")
    for version in versions:
        localizations = call(
            "GET", f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations"
        )["data"]
        for localization in localizations:
            sets = call(
                "GET",
                f"/v1/appStoreVersionLocalizations/{localization['id']}/appScreenshotSets",
            )["data"]
            for screenshot_set in sets:
                kind = screenshot_set["attributes"]["screenshotDisplayType"]
                shots = call(
                    "GET", f"/v1/appScreenshotSets/{screenshot_set['id']}/appScreenshots"
                )["data"]
                print(
                    f"    {version['attributes']['platform']:<7} "
                    f"{localization['attributes']['locale']:<6} {kind:<28} "
                    f"{len(shots)} image(s)"
                )


def editable_versions() -> dict[str, str]:
    """The version each platform's metadata should be written to, keyed by platform."""
    app = app_id()
    versions = call(
        "GET",
        f"/v1/apps/{app}/appStoreVersions?limit=200"
        "&fields[appStoreVersions]=platform,versionString,appStoreState",
    )["data"]
    # States where the listing can still be edited. Anything else is locked and would
    # need a new version created, which is deliberately left to a human.
    open_states = {
        "PREPARE_FOR_SUBMISSION",
        "DEVELOPER_REJECTED",
        "REJECTED",
        "METADATA_REJECTED",
        "WAITING_FOR_REVIEW",
    }
    found = {}
    for version in versions:
        attributes = version["attributes"]
        if attributes["appStoreState"] in open_states:
            found.setdefault(attributes["platform"], version["id"])
    return found


def push_text() -> None:
    app = app_id()

    # Name, subtitle and the privacy policy URL hang off appInfos, not off a version.
    for info in call("GET", f"/v1/apps/{app}/appInfos")["data"]:
        for localization in call(
            "GET", f"/v1/appInfos/{info['id']}/appInfoLocalizations"
        )["data"]:
            if localization["attributes"]["locale"] != LOCALE:
                continue
            attributes = {
                "name": read("name"),
                "subtitle": read("subtitle"),
                "privacyPolicyUrl": read("privacy_policy_url"),
            }
            attributes = {k: v for k, v in attributes.items() if v}
            if not attributes:
                continue
            call(
                "PATCH",
                f"/v1/appInfoLocalizations/{localization['id']}",
                {
                    "data": {
                        "type": "appInfoLocalizations",
                        "id": localization["id"],
                        "attributes": attributes,
                    }
                },
            )
            print(f"  appInfo {localization['id']}: {', '.join(attributes)}")

    # Everything else is per-version, and therefore per-platform.
    for platform, version_id in editable_versions().items():
        for localization in call(
            "GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations"
        )["data"]:
            if localization["attributes"]["locale"] != LOCALE:
                continue
            attributes = {
                "description": read("description"),
                "keywords": read("keywords"),
                "promotionalText": read("promotional_text"),
                "whatsNew": read("release_notes"),
                "supportUrl": read("support_url"),
                "marketingUrl": read("marketing_url"),
            }
            attributes = {k: v for k, v in attributes.items() if v}
            call(
                "PATCH",
                f"/v1/appStoreVersionLocalizations/{localization['id']}",
                {
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "id": localization["id"],
                        "attributes": attributes,
                    }
                },
            )
            print(f"  {platform}: {', '.join(attributes)}")


def upload_one(set_id: str, image: Path) -> None:
    payload = image.read_bytes()
    reservation = call(
        "POST",
        "/v1/appScreenshots",
        {
            "data": {
                "type": "appScreenshots",
                "attributes": {
                    "fileName": image.name,
                    "fileSize": len(payload),
                },
                "relationships": {
                    "appScreenshotSet": {
                        "data": {"type": "appScreenshotSets", "id": set_id}
                    }
                },
            }
        },
    )["data"]

    for operation in reservation["attributes"]["uploadOperations"]:
        offset = operation["offset"]
        chunk = payload[offset:offset + operation["length"]]
        call(
            operation["method"],
            operation["url"],
            raw=chunk,
            headers={h["name"]: h["value"] for h in operation.get("requestHeaders", [])},
        )

    call(
        "PATCH",
        f"/v1/appScreenshots/{reservation['id']}",
        {
            "data": {
                "type": "appScreenshots",
                "id": reservation["id"],
                "attributes": {
                    "uploaded": True,
                    "sourceFileChecksum": hashlib.md5(payload).hexdigest(),
                },
            }
        },
    )
    print(f"    {image.name} ({len(payload) // 1024} KiB)")


def push_screenshots() -> None:
    versions = editable_versions()
    for platform, directories in PLATFORMS.items():
        version_id = versions.get(platform)
        if not version_id:
            print(f"  {platform}: no editable version, skipped")
            continue

        localizations = [
            item
            for item in call(
                "GET",
                f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations",
            )["data"]
            if item["attributes"]["locale"] == LOCALE
        ]
        if not localizations:
            print(f"  {platform}: no {LOCALE} localization, skipped")
            continue
        localization_id = localizations[0]["id"]

        for directory in directories:
            images = sorted((STORE / "screenshots" / directory).glob("*.png"))
            if not images:
                print(f"  {platform}/{directory}: no images, skipped")
                continue

            kind = DISPLAY_TYPES[directory]
            existing = [
                item
                for item in call(
                    "GET",
                    f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets",
                )["data"]
                if item["attributes"]["screenshotDisplayType"] == kind
            ]
            if existing:
                set_id = existing[0]["id"]
                # Cleared rather than appended to: re-running should replace the set, not
                # accumulate ten near-identical shots and then fail on the eleventh.
                for shot in call(
                    "GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots"
                )["data"]:
                    call("DELETE", f"/v1/appScreenshots/{shot['id']}")
            else:
                set_id = call(
                    "POST",
                    "/v1/appScreenshotSets",
                    {
                        "data": {
                            "type": "appScreenshotSets",
                            "attributes": {"screenshotDisplayType": kind},
                            "relationships": {
                                "appStoreVersionLocalization": {
                                    "data": {
                                        "type": "appStoreVersionLocalizations",
                                        "id": localization_id,
                                    }
                                }
                            },
                        }
                    },
                )["data"]["id"]

            print(f"  {platform}/{directory} -> {kind}")
            for image in images:
                upload_one(set_id, image)


def main() -> None:
    command = sys.argv[1] if len(sys.argv) > 1 else "status"
    if command == "status":
        status()
    elif command == "text":
        push_text()
    elif command == "screenshots":
        push_screenshots()
    elif command == "all":
        push_text()
        push_screenshots()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
