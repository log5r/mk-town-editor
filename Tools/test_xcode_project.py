"""Check that MKTownEditor.xcodeproj stays in step with the Swift package: python3 Tools/test_xcode_project.py."""

from pathlib import Path
import re
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
PROJECT = REPOSITORY / "MKTownEditor.xcodeproj" / "project.pbxproj"


class XcodeProjectTests(unittest.TestCase):
    def setUp(self):
        self.project = PROJECT.read_text()

    def app_sources(self):
        """Return the file names compiled by the app target's Sources build phase."""
        target = re.search(r"/\* MKTownEditor \*/ = \{\s*isa = PBXNativeTarget;.*?buildPhases = \((.*?)\);",
                           self.project, re.S)
        phase_id = re.search(r"([0-9A-F]{24}) /\* Sources \*/", target.group(1)).group(1)
        phase = re.search(re.escape(phase_id) + r" /\* Sources \*/ = \{.*?files = \((.*?)\);",
                          self.project, re.S)
        return re.findall(r"/\* (\S+\.swift) in Sources \*/", phase.group(1))

    def test_app_target_compiles_every_package_source_file(self):
        """The app target lists sources one by one; a file added only to the package breaks the Xcode build."""
        package_sources = sorted(path.name for path in (REPOSITORY / "Sources" / "MKTownEditor").glob("*.swift"))
        self.assertEqual(sorted(self.app_sources()), package_sources)


if __name__ == "__main__":
    unittest.main()
