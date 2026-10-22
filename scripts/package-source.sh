#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# An allowlist keeps local diagnostics, builds, databases and Git credentials out
# of the distributable. It also works before the first Git commit.
python3 - <<'PY'
from pathlib import Path
import fnmatch
import plistlib
import re
import shutil
import stat
import zipfile

root = Path.cwd()
version = plistlib.loads((root / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit("The release version must have three numeric components")

required = ["Package.swift", "LICENSE", "README.md", "Resources/Info.plist"]
for name in required:
    if not (root / name).is_file():
        raise SystemExit(f"Required release source is missing: {name}")

included = [
    "Package.swift", "Package.resolved", ".gitignore", "LICENSE", "NOTICE",
    "README.md", "README.zh-CN.md", "CHANGELOG.md", "CONTRIBUTING.md",
    "SECURITY.md", "ACKNOWLEDGMENTS.md", "ACKNOWLEDGEMENTS.md",
    "PERFORMANCE.md", "POWER.md", "Resources", "Sources", "Tests", "scripts",
    "docs", ".github",
]
excluded_parts = {".git", ".build", "dist", "artifacts", "__pycache__", ".DS_Store"}
excluded_files = ("*.sqlite*", "*.pyc", ".env", ".env.*", "*.p12", "*.mobileprovision")
files = set()
for name in included:
    path = root / name
    if path.is_symlink():
        raise SystemExit(f"Source archives cannot follow symbolic links: {name}")
    candidates = [path] if path.is_file() else path.rglob("*") if path.is_dir() else []
    for candidate in candidates:
        relative = candidate.relative_to(root)
        if any(part in excluded_parts for part in relative.parts):
            continue
        if any(fnmatch.fnmatch(candidate.name, pattern) for pattern in excluded_files):
            continue
        if candidate.is_symlink():
            raise SystemExit(f"Source archives cannot follow symbolic links: {relative}")
        if candidate.is_file():
            files.add(relative)

output = root / "dist" / f"Keytempo-{version}-source.zip"
output.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for relative in sorted(files):
        path = root / relative
        info = zipfile.ZipInfo("Keytempo/" + relative.as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
        info.create_system = 3
        info.external_attr = (stat.S_IFREG | (path.stat().st_mode & 0o777)) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, path.read_bytes())
with zipfile.ZipFile(output) as archive:
    if archive.testzip() is not None:
        raise SystemExit("Source archive failed its integrity check")
shutil.copyfile(output, root / "dist" / "Keytempo-source.zip")
print(f"Source archive: {output} ({len(files)} files)")
PY
