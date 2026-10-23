#!/usr/bin/env python3
"""Extract one release's changes from the complete Keep a Changelog file."""
from __future__ import annotations

import argparse
from pathlib import Path
import re


def release_changes(changelog: Path, version: str) -> str:
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        raise ValueError("Version must have three numeric components")
    if changelog.stat().st_size > 1_000_000:
        raise ValueError("Changelog exceeds the release-note size limit")
    lines = changelog.read_text(encoding="utf-8").splitlines()
    heading = re.compile(r"^## \[" + re.escape(version) + r"\](?:\s+-\s+\d{4}-\d{2}-\d{2})?\s*$")
    starts = [index for index, line in enumerate(lines) if heading.fullmatch(line)]
    if len(starts) != 1:
        raise ValueError("Expected exactly one changelog section for the release version")
    start = starts[0]
    end = next((index for index in range(start + 1, len(lines)) if lines[index].startswith("## ")), len(lines))
    # Global reference definitions are part of the full changelog, not changes.
    section = [line for line in lines[start:end] if not re.match(r"^\[[^]]+\]:\s", line)]
    if not any(line.strip() and not line.startswith("#") for line in section[1:]):
        raise ValueError("The release changelog section is empty")
    section[0] = section[0].replace(f"[{version}]", version, 1)
    return "\n".join(section).strip() + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("changelog", type=Path)
    parser.add_argument("version")
    args = parser.parse_args()
    try:
        print(release_changes(args.changelog, args.version), end="")
    except (OSError, UnicodeError, ValueError) as error:
        parser.exit(1, f"Release-note validation failed: {error}\n")


if __name__ == "__main__":
    main()
