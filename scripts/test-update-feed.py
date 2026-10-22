#!/usr/bin/env python3
"""Fixture checks for signed-update metadata; no networking or keychain access."""
import base64
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
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
