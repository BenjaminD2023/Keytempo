#!/usr/bin/env python3
"""Release-note extraction fixtures; no networking, build or signing access."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_notes", Path(__file__).with_name("release-notes.py"))
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


class ReleaseNoteTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "CHANGELOG.md"

    def extract(self, text, version="0.3.2"):
        self.path.write_text(text, encoding="utf-8")
        return notes.release_changes(self.path, version)

    def test_only_current_version_changes_preserve_categories_and_unicode(self):
        actual = self.extract("""# Changelog
## [Unreleased]
- Future change.
## [0.3.2] - 2026-10-23
### Fixed
- 中文菜单栏标签。
### Changed
- Show only current release changes.
## [0.3.1] - 2026-10-23
- Older changes.
[0.3.2]: https://example.invalid/compare
""")
        self.assertEqual(actual, "## 0.3.2 - 2026-10-23\n### Fixed\n- 中文菜单栏标签。\n### Changed\n- Show only current release changes.\n")

    def test_final_section_does_not_include_global_version_references(self):
        actual = self.extract("## [0.3.2]\n- Current change.\n\n[Unreleased]: https://example.invalid/future\n[0.3.1]: https://example.invalid/old\n")
        self.assertEqual(actual, "## 0.3.2\n- Current change.\n")

    def test_missing_duplicate_or_empty_section_fails_closed(self):
        for text in ["## [0.3.1]\n- Old.\n", "## [0.3.2]\n- One.\n## [0.3.2]\n- Two.\n", "## [0.3.2]\n### Fixed\n\n## [0.3.1]\n- Old.\n"]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.extract(text)

    def test_invalid_version_and_oversized_changelog_are_rejected(self):
        for version in ["0.3", "0.3.2.*", "../0.3.2", "00.3.2"]:
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.extract("## [0.3.2]\n- Change.\n", version)
        with self.assertRaises(ValueError):
            self.extract("x" * 1_000_001)

    def test_cli_returns_nonzero_without_falling_back_to_full_changelog(self):
        self.path.write_text("## [0.3.1]\n- Historical private fixture.\n", encoding="utf-8")
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("release-notes.py")), str(self.path), "0.3.2"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("Expected exactly one changelog section", result.stderr)
        self.assertNotIn("Historical private fixture", result.stderr)


if __name__ == "__main__":
    unittest.main()
