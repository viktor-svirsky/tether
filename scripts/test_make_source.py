# Tests for make_source.py. Run with `python3 scripts/test_make_source.py`, CI runs them too.
import json
import plistlib
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
