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

    def test_unit_test_target_compiles_the_package_tests_hosted_by_the_app(self):
        target = re.search(r"/\* MKTownEditorTests \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};",
                           self.project, re.S).group(1)
        self.assertIn('productType = "com.apple.product-type.bundle.unit-test";', target)
        group_id = re.search(r"fileSystemSynchronizedGroups = \(([0-9A-F]{24})", target).group(1)
        group = re.search(re.escape(group_id) + r" /\* \w+ \*/ = \{(.*?)\};", self.project, re.S).group(1)
        self.assertIn("isa = PBXFileSystemSynchronizedRootGroup;", group)
        self.assertIn("path = Tests/MKTownEditorTests;", group)
        self.assertRegex(self.project, r"/\* PBXTargetDependency \*/ = \{\s*isa = PBXTargetDependency;"
                                       r"\s*target = [0-9A-F]{24} /\* MKTownEditor \*/;")
        hosts = re.findall(r'TEST_HOST = "([^"]+)";', self.project)
        self.assertEqual(hosts, ["$(BUILT_PRODUCTS_DIR)/MKTownEditor.app/Contents/MacOS/MKTownEditor"] * 2)

    def test_shared_scheme_runs_the_unit_tests(self):
        scheme = (REPOSITORY / "MKTownEditor.xcodeproj" / "xcshareddata" / "xcschemes"
                  / "MKTownEditor.xcscheme").read_text()
        testables = re.search(r"<Testables>(.*?)</Testables>", scheme, re.S).group(1)
        self.assertIn('BlueprintName = "MKTownEditorTests"', testables)
        target_id = re.search(r"([0-9A-F]{24}) /\* MKTownEditorTests \*/ = \{\s*isa = PBXNativeTarget;",
                              self.project).group(1)
        self.assertIn(f'BlueprintIdentifier = "{target_id}"', testables)


if __name__ == "__main__":
    unittest.main()
