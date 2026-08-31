#!/usr/bin/env python3
"""Push the store listing in Store/ to App Store Connect.

Needs an App Store Connect API key with App Manager rights:

    export ASC_KEY_ID=XXXXXXXXXX          # the .p8's key id
    export ASC_ISSUER_ID=<uuid>           # Users and Access -> Integrations
    # key read from ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8

Then:

    Tools/asc.py status                   # what ASC currently has. Run this first.
    Tools/asc.py version 1.1.1            # open a new version once the last one is on sale
    Tools/asc.py text                     # name, subtitle, description, keywords, URLs
                                          # release notes come from
                                          # release_notes-<PLATFORM>.txt where present
    Tools/asc.py screenshots              # upload Store/screenshots/<platform>/
    Tools/asc.py review                   # App Review contact details and notes
    Tools/asc.py agerating                # the questionnaire, all answers "none"
    Tools/asc.py attach [build]           # point the editable versions at a build
                                          # (defaults to CURRENT_PROJECT_VERSION)
    Tools/asc.py submit                   # put them in front of App Review
    Tools/asc.py all

`status` is read-only; run it first and after anything else. It prints which platforms
exist on the record and the `screenshotDisplayType` of every set, which is how the
constants below were confirmed rather than assumed.

`submit` cannot rescue a rejected submission. Once App Review returns a submission with
UNRESOLVED_ISSUES, the API will neither resubmit it ("Version is not ready to be
submitted yet", forever) nor let the version out of it ("Item was already submitted").
That has to be closed out in Resolution Center in the browser first; everything up to
and including attaching the new build can be done from here.

`text` will happily overwrite a name or subtitle edited in the browser, because the
files under Store/metadata are the source of truth. If someone has changed either in
App Store Connect, copy it back into the .txt first — `status` shows the current value.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
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


class ASCError(Exception):
    """An HTTP error from ASC, with the body kept so a caller can act on it."""

    def __init__(self, status: int, body: str):
        super().__init__(f"HTTP {status}: {body}")
        self.status = status
        self.body = body

    def uneditable_attribute(self) -> str | None:
        """The attribute ASC refused, if it refused one.

        A first version has no "What's New" — it is only meaningful on an update — and
        ASC reports that as a 409 naming the attribute rather than ignoring it. Reading
        the name back out lets the caller drop that one field and keep the rest, instead
        of the whole listing failing on a field that was never going to apply.

        Apple words this refusal two different ways, and which one you get depends on the
        field. `privacyPolicyUrl` on a live version gives the second, so matching only the
        first meant the whole run died on it once 1.0 was on sale.
        """
        for pattern in (
            r"Attribute '(\w+)' cannot be edited",
            r"field '(\w+)' can ?not be modified",
        ):
            match = re.search(pattern, self.body)
            if match:
                return match.group(1)
        return None


def call(method: str, path: str, body: dict | None = None, raw: bytes | None = None,
         headers: dict | None = None, tolerate: bool = False) -> dict:
    global JWT
    if JWT is None:
        JWT = token()

    url = path if path.startswith("http") else API + path
    data = raw if raw is not None else (json.dumps(body).encode() if body else None)
    request = urllib.request.Request(url, data=data, method=method)

    # The bearer token goes to the API and nowhere else. Screenshot bytes are PUT to
    # Apple's object storage on a presigned URL whose signature covers `host` alone, so an
    # extra Authorization header makes it a different request than the one that was signed
    # and the upload comes back 400 "Invalid request".
    if url.startswith(API):
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
        if tolerate:
            raise ASCError(error.code, detail) from None
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

            # Same drop-and-retry as the per-version fields below, and for the same
            # reason: an app with a live version has more than one `appInfo`, and the one
            # attached to what is on sale is frozen. Patching it used to abort the whole
            # run — including the description and release notes for the version actually
            # being prepared, which is the part that matters.
            dropped = []
            while attributes:
                try:
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
                        tolerate=True,
                    )
                    break
                except ASCError as error:
                    name = error.uneditable_attribute()
                    if name is None or name not in attributes:
                        print(f"  appInfo {localization['id']}: skipped — {error}")
                        attributes = {}
                        break
                    del attributes[name]
                    dropped.append(name)

            if attributes:
                note = f" (locked: {', '.join(dropped)})" if dropped else ""
                print(f"  appInfo {localization['id']}: {', '.join(attributes)}{note}")

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
                # Per platform where a file exists, falling back to the shared one.
                # What is new is genuinely different per platform here: the television is
                # the headline on iPhone and iPad, is reachable on a Mac only by making
                # the window tall, and does not exist on Apple TV, which never has a
                # portrait screen. One set of notes for all three meant the Apple TV
                # listing opening with "Turn your iPhone or iPad upright".
                "whatsNew": read(f"release_notes-{platform}") or read("release_notes"),
                "supportUrl": read("support_url"),
                "marketingUrl": read("marketing_url"),
            }
            attributes = {k: v for k, v in attributes.items() if v}

            # Retried with the offending field removed rather than failing outright: on a
            # first version ASC refuses `whatsNew`, and losing the description over a
            # release note that cannot exist yet would be a poor trade.
            dropped = []
            while attributes:
                try:
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
                        tolerate=True,
                    )
                    break
                except ASCError as error:
                    name = error.uneditable_attribute()
                    if name is None or name not in attributes:
                        sys.exit(f"  {platform}: {error}")
                    del attributes[name]
                    dropped.append(name)

            note = f"  (not editable yet: {', '.join(dropped)})" if dropped else ""
            print(f"  {platform}: {', '.join(attributes)}{note}")


def reviewer_notes() -> str | None:
    """The reviewer-facing block out of `review-notes.md`.

    Taken from between the first pair of `---` fences in that file, so the prose and the
    table around it stay readable as documentation while the part a reviewer actually
    sees has exactly one home.
    """
    path = STORE / "metadata" / "review-notes.md"
    if not path.exists():
        return None
    parts = path.read_text().split("\n---\n")
    return parts[1].strip() if len(parts) > 2 else None


def push_review() -> None:
    """App Review Information: who to contact, and what to tell them."""
    contact = {
        "contactFirstName": "Kevin",
        "contactLastName": "Holland",
        "contactPhone": "844-247-4274",
        "contactEmail": "hollandkevin@icloud.com",
        "demoAccountRequired": False,
    }
    notes = reviewer_notes()
    if notes:
        contact["notes"] = notes

    for platform, version_id in editable_versions().items():
        existing = call(
            "GET", f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail"
        ).get("data")

        if existing:
            call(
                "PATCH",
                f"/v1/appStoreReviewDetails/{existing['id']}",
                {
                    "data": {
                        "type": "appStoreReviewDetails",
                        "id": existing["id"],
                        "attributes": contact,
                    }
                },
            )
        else:
            call(
                "POST",
                "/v1/appStoreReviewDetails",
                {
                    "data": {
                        "type": "appStoreReviewDetails",
                        "attributes": contact,
                        "relationships": {
                            "appStoreVersion": {
                                "data": {"type": "appStoreVersions", "id": version_id}
                            }
                        },
                    }
                },
            )
        print(f"  {platform}: contact set{', notes ' + str(len(notes)) + ' chars' if notes else ''}")


def push_age_rating() -> None:
    """The age-rating questionnaire: every content answer is "none"."""
    # Field names and types as the API spells them. Frequency questions take an enum,
    # does-it-contain questions take a boolean, and the API is strict about which is
    # which — sending "NONE" for a boolean is a 409, not a coercion. The newer half of
    # this list (advertising through userGeneratedContent) is required now and was not
    # when this was first written, so the types were read back off the API's own
    # complaints rather than guessed.
    answers = {
        # Frequency: NONE | INFREQUENT_OR_MILD | FREQUENT_OR_INTENSE
        "alcoholTobaccoOrDrugUseOrReferences": "NONE",
        "contests": "NONE",
        "gamblingSimulated": "NONE",
        "gunsOrOtherWeapons": "NONE",
        "horrorOrFearThemes": "NONE",
        "matureOrSuggestiveThemes": "NONE",
        "medicalOrTreatmentInformation": "NONE",
        "profanityOrCrudeHumor": "NONE",
        "sexualContentGraphicAndNudity": "NONE",
        "sexualContentOrNudity": "NONE",
        "violenceCartoonOrFantasy": "NONE",
        "violenceRealistic": "NONE",
        "violenceRealisticProlongedGraphicOrSadistic": "NONE",
        # Presence: all false. No advertising, no chat, nothing user-submitted, no
        # in-app purchases of any kind, and nothing that needs an age check.
        "advertising": False,
        "ageAssurance": False,
        "gambling": False,
        "healthOrWellnessTopics": False,
        "lootBox": False,
        "messagingAndChat": False,
        "parentalControls": False,
        "socialMedia": False,
        "unrestrictedWebAccess": False,
        "userGeneratedContent": False,
    }

    for info in call("GET", f"/v1/apps/{app_id()}/appInfos")["data"]:
        declaration = call(
            "GET", f"/v1/appInfos/{info['id']}/ageRatingDeclaration"
        ).get("data")
        if not declaration:
            print(f"  appInfo {info['id']}: no age rating declaration")
            continue

        remaining = dict(answers)
        dropped = []
        while remaining:
            try:
                call(
                    "PATCH",
                    f"/v1/ageRatingDeclarations/{declaration['id']}",
                    {
                        "data": {
                            "type": "ageRatingDeclarations",
                            "id": declaration["id"],
                            "attributes": remaining,
                        }
                    },
                    tolerate=True,
                )
                break
            except ASCError as error:
                # Apple renames these occasionally; drop what it rejects by name and keep
                # the rest rather than losing the whole questionnaire to one stale key.
                bad = re.findall(r"'?/?data/attributes/(\w+)", error.body)
                bad = [name for name in bad if name in remaining]
                if not bad:
                    sys.exit(f"  age rating: {error}")
                for name in bad:
                    del remaining[name]
                    dropped.append(name)

        note = f"  (rejected: {', '.join(dropped)})" if dropped else ""
        print(f"  appInfo {info['id']}: {len(remaining)} answers set{note}")


def project_build_version() -> str | None:
    """`CURRENT_PROJECT_VERSION` from project.yml — the build this tree produces."""
    match = re.search(
        r'CURRENT_PROJECT_VERSION:\s*"([^"]+)"', (ROOT / "project.yml").read_text()
    )
    return match.group(1) if match else None


def latest_build(app: str, platform: str, version: str | None = None) -> dict | None:
    """The newest processed build for one platform, or a named one.

    Filtered by platform, which is not optional: a build belongs to exactly one, and an
    App Store version will only accept its own. Picking the newest build overall and
    attaching it to all three versions — which is what this did — can only ever succeed
    for whichever platform happened to upload last, and fails the other two with "The
    specified build has a different platform than the version". That went unnoticed while
    only iOS had builds.
    """
    query = (
        f"/v1/builds?filter[app]={app}"
        f"&filter[preReleaseVersion.platform]={platform}"
        "&limit=20&sort=-uploadedDate"
        "&fields[builds]=version,processingState,uploadedDate"
    )
    for build in call("GET", query)["data"]:
        attributes = build["attributes"]
        if attributes.get("processingState") != "VALID":
            continue
        if version is None or attributes.get("version") == version:
            return build
    return None


def attach_build(version: str | None = None) -> None:
    """Point each editable version at the build this working tree produced.

    Defaulting to `CURRENT_PROJECT_VERSION` rather than to whatever uploaded most recently,
    because "most recent" is wrong in the one case that matters. Apple processes the three
    platforms at their own pace, so minutes after an upload the newest *processed* build for
    a platform can still be the previous release's — and that one is already attached to a
    version on sale, so ASC refuses it with "The specified pre-release build could not be
    added". The failure at least made itself known here; the same fallback silently
    attaching a superseded build to a new version would not have.
    """
    app = app_id()
    version = version or project_build_version()
    if version:
        print(f"  attaching build {version}")
    waiting = []

    for platform, version_id in editable_versions().items():
        build = latest_build(app, platform, version)
        if not build:
            # Not fatal, and usually just a matter of time: Apple takes several minutes to
            # process an upload, and the three platforms finish at their own pace. Report
            # and carry on, so the ones that are ready get attached.
            waiting.append(platform)
            print(f"  {platform}: build {version or 'latest'} has not finished processing")
            continue

        call(
            "PATCH",
            f"/v1/appStoreVersions/{version_id}/relationships/build",
            {"data": {"type": "builds", "id": build["id"]}},
        )
        print(f"  {platform}: build {build['attributes']['version']} attached")

    if waiting:
        print(f"\nStill processing: {', '.join(waiting)}. Re-run `attach` in a few minutes.")


def submit_for_review() -> None:
    """Put the editable versions in front of App Review.

    Two steps, because a submission is a container: create one for the platform, add
    the version to it as an item, then flip it to submitted. Re-running is safe — an
    existing submission for the platform is reused rather than duplicated.
    """
    app = app_id()
    existing = {
        item["attributes"]["platform"]: item
        for item in call(
            "GET", f"/v1/reviewSubmissions?filter[app]={app}&filter[state]=READY_FOR_REVIEW"
        )["data"]
    }

    for platform, version_id in editable_versions().items():
        submission = existing.get(platform)
        if submission is None:
            submission = call(
                "POST",
                "/v1/reviewSubmissions",
                {
                    "data": {
                        "type": "reviewSubmissions",
                        "attributes": {"platform": platform},
                        "relationships": {
                            "app": {"data": {"type": "apps", "id": app}}
                        },
                    }
                },
            )["data"]

        call(
            "POST",
            "/v1/reviewSubmissionItems",
            {
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": {
                            "data": {"type": "reviewSubmissions", "id": submission["id"]}
                        },
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": version_id}
                        },
                    },
                }
            },
        )

        call(
            "PATCH",
            f"/v1/reviewSubmissions/{submission['id']}",
            {
                "data": {
                    "type": "reviewSubmissions",
                    "id": submission["id"],
                    "attributes": {"submitted": True},
                }
            },
        )
        print(f"  {platform}: submitted for review ({submission['id']})")


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


def create_version(version_string: str) -> None:
    """Open a new App Store version on every platform that does not have one.

    The last step of a release that was not scripted. Once a version goes on sale its
    listing is frozen, so `editable_versions()` finds nothing and every other command here
    has nothing to write to — which looks like the tool being broken rather than the app
    simply having shipped.

    Safe to re-run: a platform that already has this version, editable or not, is left
    alone rather than being sent a duplicate.
    """
    app = app_id()
    existing = {}
    for version in call(
        "GET",
        f"/v1/apps/{app}/appStoreVersions?limit=200"
        "&fields[appStoreVersions]=platform,versionString,appStoreState",
    )["data"]:
        attributes = version["attributes"]
        existing.setdefault((attributes["platform"], attributes["versionString"]), version)

    for platform in PLATFORMS:
        if (platform, version_string) in existing:
            state = existing[(platform, version_string)]["attributes"]["appStoreState"]
            print(f"  {platform}: {version_string} already exists ({state})")
            continue

        created = call(
            "POST",
            "/v1/appStoreVersions",
            {
                "data": {
                    "type": "appStoreVersions",
                    "attributes": {
                        "platform": platform,
                        "versionString": version_string,
                    },
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": app}}
                    },
                }
            },
        )["data"]
        print(f"  {platform}: created {version_string} ({created['id']})")


def main() -> None:
    command = sys.argv[1] if len(sys.argv) > 1 else "status"
    if command == "status":
        status()
    elif command == "text":
        push_text()
    elif command == "screenshots":
        push_screenshots()
    elif command == "review":
        push_review()
    elif command == "agerating":
        push_age_rating()
    elif command == "version":
        if len(sys.argv) < 3:
            sys.exit("usage: asc.py version <version-string>")
        create_version(sys.argv[2])
    elif command == "attach":
        attach_build(sys.argv[2] if len(sys.argv) > 2 else None)
    elif command == "submit":
        submit_for_review()
    elif command == "all":
        push_text()
        push_screenshots()
        push_review()
        push_age_rating()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
