#!/usr/bin/env python3
"""Exercise source archive names and release allowlists in isolated fixtures."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile


class SourcePackageTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "scripts").mkdir()
        (self.root / "Resources").mkdir()
        shutil.copyfile(Path(__file__).with_name("package-source.sh"), self.root / "scripts/package-source.sh")
        (self.root / "Package.swift").write_text("// source fixture\n")
        (self.root / "LICENSE").write_text("Fixture license\n")
        (self.root / "README.md").write_text("Fixture source\n")

    def package(self, version):
        (self.root / "Resources/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": version}))
        return subprocess.run(["zsh", str(self.root / "scripts/package-source.sh")], capture_output=True, text=True)

    def test_stable_and_restricted_beta_names_produce_valid_archives(self):
        for version in ["0.5.0", "0.5.0-beta", "0.5.0-beta.0", "0.5.0-beta.12"]:
            with self.subTest(version=version):
                result = self.package(version)
                self.assertEqual(result.returncode, 0, result.stderr)
                archive = self.root / "dist" / f"Keytempo-{version}-source.zip"
                with zipfile.ZipFile(archive) as source:
                    self.assertIsNone(source.testzip())
                    self.assertIn("Keytempo/LICENSE", source.namelist())
                    self.assertTrue(all(name.startswith("Keytempo/") and ".." not in Path(name).parts for name in source.namelist()))

    def test_unapproved_suffixes_and_path_components_fail_before_writing(self):
        for version in ["0.5.0-beta.01", "0.5.0-beta/../escape", "../0.5.0", "0.5.0-alpha", "0.5.0-beta+metadata", "0.5.0-beta\n"]:
            with self.subTest(version=version):
                result = self.package(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "dist").exists())
                self.assertIn("optional -beta", result.stderr)


if __name__ == "__main__":
    unittest.main()
