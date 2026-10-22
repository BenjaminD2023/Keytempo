#!/usr/bin/env python3
"""Build a bounded Sparkle appcast using public release metadata only."""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import re
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
KEYTEMPO = "https://github.com/BenjaminD2023/Keytempo/update-channel"
REPOSITORY = "BenjaminD2023/Keytempo"
FEED_URL = f"https://raw.githubusercontent.com/{REPOSITORY}/main/appcast.xml"
MAX_FEED_BYTES = 512 * 1024
MAX_ITEMS = 20
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("keytempo", KEYTEMPO)


def tag(namespace: str, name: str) -> str:
    return f"{{{namespace}}}{name}"


def decoded_base64(value: str, size: int, name: str) -> str:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError(f"Invalid {name}") from error
    if len(decoded) != size:
        raise ValueError(f"Invalid {name} length")
    return value


def numeric_build(value: str) -> int:
    if not re.fullmatch(r"[1-9][0-9]{0,9}", value) or int(value) > 2_147_483_647:
        raise ValueError("Build must be a positive 32-bit integer")
    return int(value)


def release_version(value: str) -> str:
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value):
        raise ValueError("Version must have three numeric components")
    return value


def load_feed(path: Path) -> ET.Element:
    if not path.exists():
        raise ValueError("The tracked appcast is missing")
    data = path.read_bytes()
    if len(data) > MAX_FEED_BYTES or b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
        raise ValueError("Appcast exceeds limits or contains a document type/entity")
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise ValueError("Appcast XML is invalid") from error
    if root.tag != "rss" or root.get("version") != "2.0" or len(root.findall("channel")) != 1:
        raise ValueError("Expected exactly one RSS 2.0 channel")
    channel = root.find("channel")
    assert channel is not None
    items = channel.findall("item")
    if len(items) > MAX_ITEMS:
        raise ValueError("Previous feed exceeds the item limit")
    builds: set[int] = set()
    versions: set[str] = set()
    for item in items:
        build = numeric_build(item.findtext(tag(SPARKLE, "version"), ""))
        version = release_version(item.findtext(tag(SPARKLE, "shortVersionString"), ""))
        if build in builds or version in versions:
            raise ValueError("Duplicate release version or build")
        builds.add(build)
        versions.add(version)
        enclosure = item.find("enclosure")
        if enclosure is None:
            raise ValueError("Release enclosure is missing")
        archive = f"Keytempo-{version}-macos-arm64.zip"
        expected = f"https://github.com/{REPOSITORY}/releases/download/v{version}/{archive}"
        if enclosure.get("url") != expected or enclosure.get("type") != "application/octet-stream":
            raise ValueError("Release enclosure is outside the supported update channel")
        decoded_base64(enclosure.get(tag(SPARKLE, "edSignature"), ""), 64, "archive signature")
        length = enclosure.get("length", "")
        if not length.isdigit() or not 0 < int(length) <= 1_000_000_000:
            raise ValueError("Archive length is out of bounds")
    return root


def make_feed(previous: Path, *, version: str, build: str, signature: str,
              length: int, public_key: str, team: str, minimum_os: str,
              signing_channel: str, requirement_hash: str,
              published_at: datetime | None = None) -> bytes:
    version = release_version(version)
    build_number = numeric_build(build)
    decoded_base64(signature, 64, "archive signature")
    decoded_base64(public_key, 32, "public key")
    if not 0 < length <= 1_000_000_000:
        raise ValueError("Archive length is out of bounds")
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Invalid signing team")
    if signing_channel not in {"local-development", "developer-id"}:
        raise ValueError("A stable certificate signing channel is required")
    if not re.fullmatch(r"[0-9a-f]{64}", requirement_hash):
        raise ValueError("Invalid designated requirement digest")
    if not re.fullmatch(r"[1-9][0-9]*(?:\.[0-9]+){1,2}", minimum_os):
        raise ValueError("Invalid minimum macOS version")
    root = load_feed(previous)
    channel = root.find("channel")
    assert channel is not None
    items = channel.findall("item")
    if any(numeric_build(item.findtext(tag(SPARKLE, "version"), "")) >= build_number for item in items):
        raise ValueError("New build must be newer than every published update")
    if any(item.findtext(tag(SPARKLE, "shortVersionString")) == version for item in items):
        raise ValueError("The version is already in the update feed")
    for name, value in [("publicEDKey", public_key), ("signingTeamIdentifier", team),
                        ("signingChannel", signing_channel), ("designatedRequirementSHA256", requirement_hash)]:
        element = channel.find(tag(KEYTEMPO, name))
        if element is not None and element.text != value:
            raise ValueError(f"Update channel {name} changed; a separate migration is required")
        if element is None:
            element = ET.SubElement(channel, tag(KEYTEMPO, name))
        element.text = value

    for item in items:
        channel.remove(item)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Keytempo {version}"
    ET.SubElement(item, "link").text = f"https://github.com/{REPOSITORY}/releases/tag/v{version}"
    instant = published_at or datetime.now(timezone.utc)
    if instant.tzinfo is None:
        raise ValueError("Publication time must have a timezone")
    ET.SubElement(item, "pubDate").text = format_datetime(instant.astimezone(timezone.utc), usegmt=True)
    ET.SubElement(item, tag(SPARKLE, "version")).text = build
    ET.SubElement(item, tag(SPARKLE, "shortVersionString")).text = version
    ET.SubElement(item, tag(SPARKLE, "minimumSystemVersion")).text = minimum_os
    ET.SubElement(item, "description").text = "See the linked release for changes, signing details and known limitations."
    archive = f"Keytempo-{version}-macos-arm64.zip"
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/{REPOSITORY}/releases/download/v{version}/{archive}",
        "type": "application/octet-stream", "length": str(length),
        tag(SPARKLE, "edSignature"): signature,
    })
    channel.append(item)
    for previous_item in sorted(items, key=lambda value: numeric_build(value.findtext(tag(SPARKLE, "version"), "")), reverse=True)[:MAX_ITEMS - 1]:
        channel.append(previous_item)
    ET.indent(root, space="  ")
    result = ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"
    if len(result) > MAX_FEED_BYTES:
        raise ValueError("Generated feed exceeds the size limit")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count-items", type=Path)
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--build")
    parser.add_argument("--signature")
    parser.add_argument("--length", type=int)
    parser.add_argument("--public-key")
    parser.add_argument("--team")
    parser.add_argument("--minimum-os")
    parser.add_argument("--signing-channel")
    parser.add_argument("--requirement-hash")
    args = parser.parse_args()
    try:
        if args.count_items:
            channel = load_feed(args.count_items).find("channel")
            assert channel is not None
            print(len(channel.findall("item")))
            return
        if any(getattr(args, name) is None for name in ("previous", "output", "version", "build", "signature", "length", "public_key", "team", "minimum_os", "signing_channel", "requirement_hash")):
            parser.error("Generating a feed requires every release metadata option")
        data = make_feed(args.previous, version=args.version, build=args.build, signature=args.signature,
                         length=args.length, public_key=args.public_key, team=args.team, minimum_os=args.minimum_os,
                         signing_channel=args.signing_channel, requirement_hash=args.requirement_hash)
        args.output.write_bytes(data)
        print(f"Prepared appcast: {args.output}")
    except (OSError, ValueError) as error:
        parser.exit(1, f"Appcast validation failed: {error}\n")


if __name__ == "__main__":
    main()
