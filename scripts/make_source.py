#!/usr/bin/env python3
# Writes the AltStore/SideStore source for a release: a JSON file that lists Tether.ipa, so people can
# add one URL in AltStore or SideStore and install and update Tether from there. The release workflow
# attaches it to each release, and https://github.com/viktor-svirsky/tether/releases/latest/download/source.json
# always points at the newest one. Field reference: https://faq.altstore.io/developers/make-a-source
#   scripts/make_source.py Tether.ipa v1.2.0 > source.json
import datetime
import json
import os
import plistlib
import re
import sys
import zipfile
from pathlib import Path

# The repo the release is in, from the workflow, so a fork's source points at its own ipa (#147).
DEFAULT_REPO = "viktor-svirsky/tether"


def info_plist(ipa):
    with zipfile.ZipFile(ipa) as archive:
        paths = [n for n in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(paths) != 1:
            sys.exit(f"{ipa}: no app in Payload/, or more than one")
        return plistlib.loads(archive.read(paths[0]))


def source(ipa, tag, date, repo=DEFAULT_REPO):
    repo_url = f"https://github.com/{repo}"
    # The release's own tag, so each release's screenshots get new URLs: SideStore keeps showing
    # what it cached for an unchanged URL, even after the file changed on main.
    raw = f"https://raw.githubusercontent.com/{repo}/{tag}"
    info = info_plist(ipa)
    version = info["CFBundleShortVersionString"]
    if tag != f"v{version}":
        sys.exit(f"the tag {tag} doesn't match the app's version {version}")
    build = info["CFBundleVersion"]
    if not re.fullmatch(r"[0-9]+", build):
        sys.exit(f"the app's build number is {build!r}, not a commit count")
    return {
        "name": "Tether",
        "subtitle": "Share your iPhone's internet without the hotspot speed cap.",
        "website": repo_url,
        "nsfw": False,
        "apps": [
            {
                "name": "Tether",
                "bundleIdentifier": info["CFBundleIdentifier"],
                "developerName": "Viktor Svirsky",
                "subtitle": "Hotspot traffic that leaves as the iPhone's own.",
                "localizedDescription": (
                    "Tether runs a WireGuard server on your iPhone's Personal Hotspot. Your laptop "
                    "(Windows, Mac or Linux), Android phone, iPad or travel router connects to it with a WireGuard client, and Tether makes every connection "
                    "again from the iPhone, so the traffic counts as the phone's own. "
                    f"Setup and caveats: {repo_url}#readme"
                ),
                "iconURL": f"{raw}/Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
                "screenshots": [f"{raw}/docs/{name}.png" for name in ("sharing", "add-device", "notifications")],
                "category": "utilities",
                # The IPA is unsigned and has no entitlements. The signing app adds its own.
                "appPermissions": {
                    "entitlements": [],
                    "privacy": {k: v for k, v in info.items() if k.endswith("UsageDescription")},
                },
                "versions": [
                    {
                        "version": version,
                        "buildVersion": build,
                        "date": date,
                        "downloadURL": f"{repo_url}/releases/download/{tag}/{Path(ipa).name}",
                        "size": Path(ipa).stat().st_size,
                        "minOSVersion": info["MinimumOSVersion"],
                        "localizedDescription": f"{repo_url}/releases/tag/{tag}",
                    }
                ],
            }
        ],
    }


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: make_source.py <Tether.ipa> <tag>")
    today = datetime.date.today().isoformat()
    json.dump(source(sys.argv[1], sys.argv[2], today, os.environ.get("GITHUB_REPOSITORY") or DEFAULT_REPO), sys.stdout, indent=2)
    print()
