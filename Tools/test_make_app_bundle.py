"""Test the app bundle assembly without compiling: python3 Tools/test_make_app_bundle.py."""

import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
SCRIPT = REPOSITORY / "Tools" / "make-app-bundle.sh"


def configurations(project, owner):
    """Map configuration names to the build settings of a configuration list in project.pbxproj."""
    configuration_list = re.search(
        r"/\* Build configuration list for " + re.escape(owner) + r" \*/ = "
        r"\{[^}]*?buildConfigurations = \(([^)]*)\)", project)
    result = {}
    for identifier in re.findall(r"[0-9A-F]{24}", configuration_list.group(1)):
        block = re.search(re.escape(identifier) + r" /\* \w+ \*/ = \{\s*isa = XCBuildConfiguration;"
                          r"\s*buildSettings = \{(.*?)\};\s*name = (\w+);", project, re.S)
        settings = re.findall(r"(\w+) = (\"[^\"]*\"|[^;]+);", block.group(1))
        result[block.group(2)] = {key: value.strip().strip('"') for key, value in settings}
    return result


def app_target_build_settings():
    """Return the settings the Debug and Release builds of the Xcode app target agree on."""
    project = (REPOSITORY / "MKTownEditor.xcodeproj" / "project.pbxproj").read_text()
    project_level = configurations(project, 'PBXProject "MKTownEditor"')
    target = configurations(project, 'PBXNativeTarget "MKTownEditor"')
    merged = [{**project_level[name], **settings} for name, settings in target.items()]
    return {key: value for key, value in merged[0].items()
            if all(other.get(key) == value for other in merged)}


class MakeAppBundleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.products = self.root / "products with spaces"
        self.products.mkdir()
        # Any Mach-O executable works; codesign replaces its signature in the copy.
        shutil.copyfile("/usr/bin/true", self.products / "MKTownEditor")
        (self.products / "MKTownEditor").chmod(0o755)
        for name in ("MKTownEditor_MKTownEditor", "SwiftMath_SwiftMath"):
            resources = self.products / f"{name}.bundle" / "Contents" / "Resources"
            resources.mkdir(parents=True)
            (resources / "resource.txt").write_text(name)
        english = self.products / "MKTownEditor_MKTownEditor.bundle" / "Contents" / "Resources" / "en.lproj"
        english.mkdir()
        (english / "Localizable.strings").write_text('"保存" = "Save";\n')
        swift_math_french = self.products / "SwiftMath_SwiftMath.bundle" / "Contents" / "Resources" / "fr.lproj"
        swift_math_french.mkdir()
        (self.products / "MKTownEditor.swiftmodule").write_text("not a resource bundle")
        self.app = self.root / "build" / "MKTownEditor.app"

    def run_script(self, *arguments, script=SCRIPT):
        return subprocess.run(["/bin/bash", str(script), *arguments], cwd=self.root,
                              env={**os.environ, "PATH": "/usr/bin:/bin"},
                              capture_output=True, text=True)

    def info(self):
        with (self.app / "Contents" / "Info.plist").open("rb") as file:
            return plistlib.load(file)

    def test_expands_info_plist_with_the_xcode_app_target_settings(self):
        result = self.run_script(str(self.products), str(self.app))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.app))
        text = (self.app / "Contents" / "Info.plist").read_text()
        self.assertNotIn("$(", text)
        settings = app_target_build_settings()
        info = self.info()
        self.assertEqual(info["CFBundleExecutable"], "MKTownEditor")
        self.assertEqual(settings["PRODUCT_NAME"], "$(TARGET_NAME)")
        self.assertEqual(info["CFBundleName"], "MKTownEditor")
        self.assertEqual(info["CFBundleIdentifier"], settings["PRODUCT_BUNDLE_IDENTIFIER"])
        self.assertEqual(info["LSMinimumSystemVersion"], settings["MACOSX_DEPLOYMENT_TARGET"])
        catalog = json.loads((REPOSITORY / "Sources" / "MKTownEditor" / "Localizable.xcstrings").read_text())
        self.assertEqual(info["CFBundleDevelopmentRegion"], catalog["sourceLanguage"])
        self.assertEqual(info["NSServices"][0]["NSPortName"], info["CFBundleName"])
        self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"], ["mktowneditor"])
        self.assertIn("NSLocalNetworkUsageDescription", info)
        self.assertEqual((self.app / "Contents" / "PkgInfo").read_text(), "APPL????")

    def test_places_executable_and_resource_bundles_where_bundle_module_looks(self):
        self.assertEqual(self.run_script(str(self.products), str(self.app)).returncode, 0)
        executable = self.app / "Contents" / "MacOS" / "MKTownEditor"
        self.assertTrue(os.access(executable, os.X_OK))
        resources = self.app / "Contents" / "Resources"
        self.assertEqual(sorted(path.name for path in resources.iterdir()),
                         ["MKTownEditor_MKTownEditor.bundle", "SwiftMath_SwiftMath.bundle", "en.lproj"])
        self.assertEqual(
            (resources / "SwiftMath_SwiftMath.bundle" / "Contents" / "Resources" / "resource.txt")
            .read_text(), "SwiftMath_SwiftMath")

    def test_copies_the_app_string_tables_to_the_main_bundle(self):
        """SwiftUI resolves `Text` keys in Bundle.main, so the tables cannot stay in the module bundle."""
        self.assertEqual(self.run_script(str(self.products), str(self.app)).returncode, 0)
        table = self.app / "Contents" / "Resources" / "en.lproj" / "Localizable.strings"
        self.assertEqual(table.read_text(), '"保存" = "Save";\n')
        self.assertFalse((self.app / "Contents" / "Resources" / "fr.lproj").exists())
        self.assertEqual(self.info()["CFBundleLocalizations"], ["ja", "en"])

    def test_copies_string_tables_from_a_flat_resource_bundle(self):
        module = self.products / "MKTownEditor_MKTownEditor.bundle"
        shutil.rmtree(module)
        (module / "en.lproj").mkdir(parents=True)
        (module / "en.lproj" / "Localizable.strings").write_text("flat")
        self.assertEqual(self.run_script(str(self.products), str(self.app)).returncode, 0)
        self.assertEqual((self.app / "Contents" / "Resources" / "en.lproj" / "Localizable.strings")
                         .read_text(), "flat")

    def test_signs_the_bundle_ad_hoc(self):
        self.assertEqual(self.run_script(str(self.products), str(self.app)).returncode, 0)
        verify = subprocess.run(["codesign", "--verify", "--strict", str(self.app)],
                                capture_output=True, text=True)
        self.assertEqual(verify.returncode, 0, verify.stderr)
        details = subprocess.run(["codesign", "--display", "--verbose=2", str(self.app)],
                                 capture_output=True, text=True)
        self.assertIn("Signature=adhoc", details.stderr)
        self.assertIn("Identifier=com.mktown.editor", details.stderr)

    def test_replaces_a_previous_bundle_without_leaving_staging_files(self):
        stale = self.app / "Contents" / "Resources" / "Stale.bundle"
        stale.mkdir(parents=True)
        self.assertEqual(self.run_script(str(self.products), str(self.app)).returncode, 0)
        self.assertFalse(stale.exists())
        self.assertEqual([path.name for path in self.app.parent.iterdir()], ["MKTownEditor.app"])

    def test_missing_executable_fails_and_keeps_the_previous_bundle(self):
        (self.products / "MKTownEditor").unlink()
        previous = self.app / "Contents" / "Info.plist"
        previous.parent.mkdir(parents=True)
        previous.write_text("previous")
        result = self.run_script(str(self.products), str(self.app))
        self.assertEqual(result.returncode, 1)
        self.assertIn("swift build", result.stderr)
        self.assertEqual(previous.read_text(), "previous")

    def test_unknown_build_setting_in_info_plist_fails(self):
        project = self.root / "project"
        (project / "Tools").mkdir(parents=True)
        (project / "Support").mkdir()
        script = project / "Tools" / "make-app-bundle.sh"
        shutil.copy2(SCRIPT, script)
        template = (REPOSITORY / "Support" / "Info.plist").read_text()
        (project / "Support" / "Info.plist").write_text(
            template.replace("<string>1.0</string>", "<string>$(MARKETING_VERSION)</string>"))
        result = self.run_script(str(self.products), str(self.app), script=script)
        self.assertEqual(result.returncode, 1)
        self.assertIn("$(MARKETING_VERSION)", result.stderr)
        self.assertFalse(self.app.exists())
        self.assertEqual(list(self.app.parent.iterdir()), [])

    def test_invalid_arguments_print_usage(self):
        for arguments in [(), (str(self.products),), ("", str(self.app)),
                          (str(self.products), str(self.app), "extra")]:
            with self.subTest(arguments=arguments):
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, 2)
                self.assertIn("Usage:", result.stderr)
                self.assertFalse(self.app.exists())


if __name__ == "__main__":
    unittest.main()
