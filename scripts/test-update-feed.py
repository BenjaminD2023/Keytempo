#!/usr/bin/env python3
"""Fixture checks for signed-update metadata; no networking or keychain access."""
import base64
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("update_feed", Path(__file__).with_name("update-feed.py"))
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)


class UpdateFeedTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.previous = Path(self.directory.name) / "appcast.xml"
        self.previous.write_text('<rss version="2.0"><channel><title>Keytempo</title></channel></rss>')
        self.values = dict(version="1.1.2", build="9", signature=base64.b64encode(bytes(64)).decode(),
                           length=1000, public_key=base64.b64encode(bytes(32)).decode(),
                           team="45PVRUCTSQ", minimum_os="13.0",
                           signing_channel="local-development", requirement_hash="a" * 64,
                           published_at=datetime(2026, 10, 22, tzinfo=timezone.utc))

    def generate(self, **changes):
        return feed.make_feed(self.previous, **(self.values | changes))

    def test_release_fields_and_https_asset_are_exact(self):
        root = ET.fromstring(self.generate())
        item = root.find("channel/item")
        self.assertEqual(item.findtext(feed.tag(feed.SPARKLE, "version")), "9")
        self.assertEqual(item.findtext(feed.tag(feed.SPARKLE, "minimumSystemVersion")), "13.0")
        self.assertEqual(item.find("enclosure").get("url"), "https://github.com/BenjaminD2023/Keytempo/releases/download/v1.1.2/Keytempo-1.1.2-macos-arm64.zip")
        self.assertEqual(item.find("enclosure").get("length"), "1000")

    def test_beta_and_rc_versions_share_preview_channel_and_safe_asset_path(self):
        for version in ["0.5.0-beta", "0.5.0-beta.0", "0.5.0-beta.12",
                        "0.5.0-rc", "0.5.0-rc.0", "0.5.0-rc.12"]:
            with self.subTest(version=version):
                root = ET.fromstring(self.generate(version=version, build="19"))
                item = root.find("channel/item")
                self.assertEqual(item.findtext(feed.tag(feed.SPARKLE, "channel")), "beta")
                self.assertEqual(item.findtext(feed.tag(feed.SPARKLE, "shortVersionString")), version)
                self.assertIn(f"/v{version}/Keytempo-{version}-", item.find("enclosure").get("url"))
        stable = ET.fromstring(self.generate(version="0.5.0", build="19")).find("channel/item")
        self.assertIsNone(stable.find(feed.tag(feed.SPARKLE, "channel")))

    def test_unapproved_prerelease_suffixes_and_unsafe_versions_are_rejected(self):
        versions = ["0.5.0-beta.01", "0.5.0-beta.", "0.5.0-beta.1.2", "0.5.0-alpha",
                    "0.5.0-rc.01", "0.5.0-rc.", "0.5.0-rc.1.2", "0.5.0-RC", "0.5.0-rc1",
                    "0.5.0-beta+build", "0.5.0-rc+build", "0.5.0-beta/../../secret",
                    "0.5.0-rc/../../secret", "0.5.0-beta\\payload", "0.5.0-rc\\payload",
                    "0.5.0-beta\n", "0.5.0-rc\n", "00.5.0-beta", "1" * 129 + ".0.0"]
        for version in versions:
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.generate(version=version)

    def test_preview_channel_metadata_cannot_be_missing_changed_or_duplicated(self):
        for version in ["0.5.0-beta", "0.5.0-rc"]:
            self.previous.write_text('<rss version="2.0"><channel><title>Keytempo</title></channel></rss>')
            original = self.generate(version=version, build="19")
            for mode in ["missing", "stable", "duplicated", "wrong", "rc-channel"]:
                with self.subTest(version=version, mode=mode):
                    root = ET.fromstring(original)
                    item = root.find("channel/item")
                    channel = item.find(feed.tag(feed.SPARKLE, "channel"))
                    if mode == "missing":
                        item.remove(channel)
                    elif mode == "stable":
                        item.find(feed.tag(feed.SPARKLE, "shortVersionString")).text = "0.5.0"
                    elif mode == "duplicated":
                        ET.SubElement(item, feed.tag(feed.SPARKLE, "channel")).text = "beta"
                    else:
                        channel.text = "rc" if mode == "rc-channel" else "nightly"
                    self.previous.write_bytes(ET.tostring(root))
                    with self.assertRaises(ValueError):
                        self.generate(version="0.5.1-rc", build="20")

    def test_tracked_signed_beta_feed_accepts_rc_and_preserves_release_elements(self):
        # This reads the published signed feed but never signs or changes it.
        source = Path(__file__).resolve().parents[1] / "appcast.xml"
        data = source.read_bytes()
        self.assertIn(b"<!-- sparkle-signatures:", data)
        self.previous.write_bytes(data)
        channel = feed.load_feed(self.previous).find("channel")
        items = channel.findall("item")
        self.assertTrue(any(item.findtext(feed.tag(feed.SPARKLE, "shortVersionString")) == "0.5.0-beta" for item in items))
        versions = {item.findtext(feed.tag(feed.SPARKLE, "shortVersionString")) for item in items}
        version, suffix = "0.5.0-rc", 0
        while version in versions:
            suffix += 1
            version = f"0.5.0-rc.{suffix}"
        build = str(max(int(item.findtext(feed.tag(feed.SPARKLE, "version"))) for item in items) + 1)
        metadata = {key: channel.findtext(feed.tag(feed.KEYTEMPO, name)) for key, name in [
            ("public_key", "publicEDKey"), ("team", "signingTeamIdentifier"),
            ("signing_channel", "signingChannel"), ("requirement_hash", "designatedRequirementSHA256")]}
        generated = self.generate(version=version, build=build, **metadata)
        historical = feed.raw_release_items(data)[:feed.MAX_ITEMS - 1]
        self.assertEqual(feed.raw_release_items(generated)[1:], historical)
        self.previous.write_bytes(generated)
        updated = feed.load_feed(self.previous).find("channel/item")
        self.assertEqual(updated.findtext(feed.tag(feed.SPARKLE, "channel")), "beta")
        self.assertEqual(updated.findtext(feed.tag(feed.SPARKLE, "shortVersionString")), version)

    def test_publisher_marks_beta_and_rc_as_prereleases_without_replacing_latest(self):
        script = Path(__file__).with_name("publish-release.sh").read_text()
        # Exercise the exact option selection without GitHub/keychain/build work.
        options = script.split("prerelease_options=()", 1)[1].split("head_commit=", 1)[0]
        command = 'app_version="$1"; prerelease_options=(); ' + options + '\nprint -r -- "${(j: :)prerelease_options}"; print -r -- "${(j: :)publication_options}"'
        for version in ["0.5.0-beta", "0.5.0-beta.2", "0.5.0-rc", "0.5.0-rc.2", "0.5.0"]:
            with self.subTest(version=version):
                result = subprocess.run(["zsh", "-c", command, "fixture", version], capture_output=True, text=True, check=True)
                expected = ["--prerelease", "--prerelease --latest=false"] if "-" in version else ["", "--latest"]
                self.assertEqual(result.stdout.splitlines(), expected)

    def test_beta_rc_stable_chain_preserves_historical_item_bytes_exactly(self):
        data = self.generate(version="0.4.1", build="17")
        data = data.replace(b"<description>", b"<description><![CDATA[keystrokes & XP ")
        data = data.replace(b"</description>", b"]]></description>")
        data = data.replace(b" />", b"></enclosure>")
        self.previous.write_bytes(data)
        historical = feed.raw_release_items(data)
        beta = self.generate(version="0.5.0-beta", build="19")
        self.assertEqual(feed.raw_release_items(beta)[1:], historical)
        # An old item's comment cannot be mistaken for a new placeholder.
        beta = beta.replace(b"<title>Keytempo 0.5.0-beta</title>", b"<title>Keytempo 0.5.0-beta</title><!--keytempo-preserve-release-1-->")
        self.previous.write_bytes(beta)
        feed.load_feed(self.previous)
        rc = self.generate(version="0.5.0-rc", build="20")
        self.assertEqual(feed.raw_release_items(rc)[1:], feed.raw_release_items(beta))
        self.previous.write_bytes(rc)
        feed.load_feed(self.previous)
        stable = self.generate(version="0.5.0", build="21")
        self.assertEqual(feed.raw_release_items(stable)[1:], feed.raw_release_items(rc))
        items = ET.fromstring(stable).findall("channel/item")
        self.assertIsNone(items[0].find(feed.tag(feed.SPARKLE, "channel")))
        self.assertEqual(items[1].findtext(feed.tag(feed.SPARKLE, "channel")), "beta")
        self.assertEqual(items[2].findtext(feed.tag(feed.SPARKLE, "channel")), "beta")

    def test_same_or_older_build_and_duplicate_version_are_rejected(self):
        self.previous.write_bytes(self.generate())
        for changes in [dict(version="1.1.3", build="9"), dict(version="1.1.3", build="8"), dict(build="10")]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.generate(**changes)

    def test_old_items_are_preserved_and_bounded(self):
        for value in range(1, 25):
            self.previous.write_bytes(self.generate(version=f"1.2.{value}", build=str(value)))
        items = ET.fromstring(self.previous.read_bytes()).findall("channel/item")
        self.assertEqual(len(items), 20)
        self.assertEqual([int(item.findtext(feed.tag(feed.SPARKLE, "version"))) for item in items], list(range(24, 4, -1)))

    def test_zero_major_renumbering_uses_increasing_build(self):
        self.previous.write_bytes(self.generate(version="1.2.1", build="10"))
        items = ET.fromstring(self.generate(version="0.3.0", build="11")).findall("channel/item")
        self.assertEqual([item.findtext(feed.tag(feed.SPARKLE, "shortVersionString")) for item in items], ["0.3.0", "1.2.1"])
        self.assertEqual([item.findtext(feed.tag(feed.SPARKLE, "version")) for item in items], ["11", "10"])
        self.assertIn("/v0.3.0/Keytempo-0.3.0-", items[0].find("enclosure").get("url"))

    def test_key_or_signing_team_cannot_change_silently(self):
        self.previous.write_bytes(self.generate())
        for changes in [dict(public_key=base64.b64encode(bytes([1]) * 32).decode()), dict(team="DIFFERENT1"), dict(signing_channel="developer-id"), dict(requirement_hash="b" * 64)]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.generate(version="1.1.3", build="10", **changes)

    def test_invalid_signature_key_length_and_metadata_rejected(self):
        for changes in [dict(signature="bad"), dict(public_key="AAAA"), dict(length=0), dict(length=1_000_000_001), dict(version="1.2"), dict(build="0"), dict(build="2147483648"), dict(minimum_os="13.0;echo"), dict(team="x"), dict(published_at=datetime(2026, 1, 1))]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.generate(**changes)

    def test_unsafe_old_enclosures_are_rejected(self):
        root = ET.fromstring(self.generate())
        root.find("channel/item/enclosure").set("url", "https://unrelated.example/Keytempo.zip")
        self.previous.write_bytes(ET.tostring(root))
        with self.assertRaises(ValueError):
            self.generate(version="1.1.3", build="10")

    def test_entities_oversized_and_malformed_feeds_are_rejected(self):
        for data in [b'<!DOCTYPE rss [<!ENTITY x "unsafe">]><rss version="2.0"><channel/></rss>', b"x" * (feed.MAX_FEED_BYTES + 1), b"<rss", b'<rss version="2.0"><channel/><channel/></rss>']:
            with self.subTest(data=data[:40]), self.assertRaises(ValueError):
                self.previous.write_bytes(data)
                self.generate()


if __name__ == "__main__":
    unittest.main()
