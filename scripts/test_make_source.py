# Tests for make_source.py. Run with `python3 scripts/test_make_source.py`, CI runs them too.
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

import make_source

INFO = {
    "CFBundleIdentifier": "com.vsvirskyi.phoneshare",
    "CFBundleShortVersionString": "1.2.0",
    "CFBundleVersion": "57",
    "MinimumOSVersion": "17.0",
    "NSLocalNetworkUsageDescription": "Tether accepts connections on the hotspot network.",
    "UIBackgroundModes": ["audio"],
}


def fake_ipa(directory, info=INFO, app="Tether.app"):
    path = Path(directory) / "Tether.ipa"
    with zipfile.ZipFile(path, "w") as ipa:
        ipa.writestr(f"Payload/{app}/Info.plist", plistlib.dumps(info))
        ipa.writestr(f"Payload/{app}/Tether", b"\0" * 1000)
    return path


class MakeSourceTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.ipa = fake_ipa(self.dir.name)

    def tearDown(self):
        self.dir.cleanup()

    def source(self, tag="v1.2.0", date="2026-10-29"):
        return make_source.source(self.ipa, tag, date)

    def app(self):
        return self.source()["apps"][0]

    def test_the_app_matches_the_ipa(self):
        app = self.app()
        self.assertEqual(app["bundleIdentifier"], "com.vsvirskyi.phoneshare")
        self.assertEqual(app["name"], "Tether")

    def test_the_version_matches_the_ipa(self):
        [version] = self.app()["versions"]
        self.assertEqual(version["version"], "1.2.0")
        self.assertEqual(version["buildVersion"], "57")
        self.assertEqual(version["minOSVersion"], "17.0")
        self.assertEqual(version["date"], "2026-10-29")
        self.assertEqual(version["size"], self.ipa.stat().st_size)

    def test_the_download_points_at_this_release(self):
        [version] = self.app()["versions"]
        self.assertEqual(
            version["downloadURL"],
            "https://github.com/viktor-svirsky/tether/releases/download/v1.2.0/Tether.ipa",
        )

    # A fork's release points at the fork's own ipa and images, not this repo's (#147).
    def test_a_fork_points_at_itself(self):
        app = make_source.source(self.ipa, "v1.2.0", "2026-10-29", "someone/tether")["apps"][0]
        [version] = app["versions"]
        self.assertEqual(version["downloadURL"], "https://github.com/someone/tether/releases/download/v1.2.0/Tether.ipa")
        self.assertTrue(app["iconURL"].startswith("https://raw.githubusercontent.com/someone/tether/v1.2.0/"))

    # The release workflow runs the script with GITHUB_REPOSITORY set, so that path is what ships.
    def run_cli(self, repo):
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_REPOSITORY"}
        if repo is not None:
            env["GITHUB_REPOSITORY"] = repo
        out = subprocess.run([sys.executable, str(Path(__file__).with_name("make_source.py")), str(self.ipa), "v1.2.0"],
                             env=env, capture_output=True, text=True, check=True).stdout
        [version] = json.loads(out)["apps"][0]["versions"]
        return version["downloadURL"]

    def test_the_command_reads_the_repo_from_the_workflow(self):
        self.assertEqual(self.run_cli("someone/tether"), "https://github.com/someone/tether/releases/download/v1.2.0/Tether.ipa")
        self.assertEqual(self.run_cli(None), "https://github.com/viktor-svirsky/tether/releases/download/v1.2.0/Tether.ipa")

    # SideStore keeps showing what it cached for an unchanged URL, so each release's images are its tag's.
    def test_the_images_point_at_this_release(self):
        app = self.app()
        raw = "https://raw.githubusercontent.com/viktor-svirsky/tether/v1.2.0"
        self.assertEqual(app["iconURL"], f"{raw}/Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
        self.assertEqual(app["screenshots"], [f"{raw}/docs/sharing.png", f"{raw}/docs/add-device.png", f"{raw}/docs/notifications.png"])

    # AltStore refuses an app whose permissions don't match the IPA, so every usage description is listed.
    def test_the_privacy_keys_are_every_usage_description(self):
        self.assertEqual(
            self.app()["appPermissions"],
            {"entitlements": [], "privacy": {"NSLocalNetworkUsageDescription": INFO["NSLocalNetworkUsageDescription"]}},
        )

    def test_a_tag_that_doesnt_match_the_version_is_refused(self):
        with self.assertRaisesRegex(SystemExit, "v1.3.0"):
            self.source(tag="v1.3.0")

    # SideStore orders updates by the build number, so a release without one would never be offered.
    def test_an_ipa_without_a_build_number_is_refused(self):
        for build in ["", "1.0"]:
            with self.subTest(build=build):
                ipa = fake_ipa(self.dir.name, {**INFO, "CFBundleVersion": build})
                with self.assertRaisesRegex(SystemExit, "build number"):
                    make_source.source(ipa, "v1.2.0", "2026-10-29")

    def test_an_ipa_without_an_app_is_refused(self):
        bad = Path(self.dir.name) / "bad.ipa"
        with zipfile.ZipFile(bad, "w") as ipa:
            ipa.writestr("Payload/readme.txt", "")
        with self.assertRaisesRegex(SystemExit, "no app"):
            make_source.source(bad, "v1.2.0", "2026-10-29")

    def test_the_output_is_json(self):
        json.dumps(self.source())


if __name__ == "__main__":
    unittest.main()
