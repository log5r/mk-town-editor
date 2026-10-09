"""Check that MKTownEditor.xcodeproj stays in step with the Swift package: python3 Tools/test_xcode_project.py."""

from pathlib import Path
import plistlib
import re
import subprocess
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
PROJECT = REPOSITORY / "MKTownEditor.xcodeproj" / "project.pbxproj"


def project_objects(source):
    """Read OpenStep plist objects without depending on Xcode's text formatting."""
    result = subprocess.run(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", "-"],
                            input=source.encode(), capture_output=True, check=True)
    return plistlib.loads(result.stdout)["objects"]


class XcodeProjectTests(unittest.TestCase):
    def setUp(self):
        self.project = PROJECT.read_text()
        self.objects = project_objects(self.project)

    def target(self, name):
        targets = [obj for obj in self.objects.values()
                   if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == name]
        self.assertEqual(len(targets), 1, f"Expected one native target named {name}")
        return targets[0]

    def app_sources(self):
        """Return the file names compiled by the app target's Sources build phase."""
        phases = [self.objects[identifier] for identifier in self.target("MKTownEditor")["buildPhases"]]
        sources = [phase for phase in phases if phase["isa"] == "PBXSourcesBuildPhase"]
        self.assertEqual(len(sources), 1)
        return [Path(self.objects[self.objects[identifier]["fileRef"]]["path"]).name
                for identifier in sources[0]["files"]]

    def test_app_target_compiles_every_package_source_file(self):
        """The app target lists sources one by one; a file added only to the package breaks the Xcode build."""
        package_sources = sorted(path.name for path in (REPOSITORY / "Sources" / "MKTownEditor").glob("*.swift"))
        self.assertEqual(sorted(self.app_sources()), package_sources)

    def test_app_target_compiles_the_icon_composer_document(self):
        """Tools/make-app-bundle.sh compiles the same document; the two builds must name the same icon."""
        target = self.target("MKTownEditor")
        phases = [self.objects[identifier] for identifier in target["buildPhases"]]
        resources = [phase for phase in phases if phase["isa"] == "PBXResourcesBuildPhase"]
        self.assertEqual(len(resources), 1)
        icons = [self.objects[self.objects[identifier]["fileRef"]] for identifier in resources[0]["files"]
                 if self.objects[self.objects[identifier]["fileRef"]].get("path") == "AppIcon.icon"]
        self.assertEqual(len(icons), 1)
        self.assertEqual(icons[0]["lastKnownFileType"], "folder.iconcomposer.icon")
        support = [obj for obj in self.objects.values() if obj.get("isa") == "PBXGroup" and obj.get("path") == "Support"]
        self.assertEqual(len(support), 1)
        self.assertIn(icons[0], [self.objects[identifier] for identifier in support[0]["children"]])
        self.assertTrue((REPOSITORY / "Support" / "AppIcon.icon" / "icon.json").is_file())
        configurations = self.objects[target["buildConfigurationList"]]["buildConfigurations"]
        self.assertEqual(len(configurations), 2)
        for identifier in configurations:
            self.assertEqual(self.objects[identifier]["buildSettings"]["ASSETCATALOG_COMPILER_APPICON_NAME"],
                             "AppIcon")
        script = (REPOSITORY / "Tools" / "make-app-bundle.sh").read_text()
        self.assertIn("app_icon_name=AppIcon\n", script)

    def test_unit_test_target_compiles_the_package_tests_hosted_by_the_app(self):
        target = self.target("MKTownEditorTests")
        self.assertEqual(target["productType"], "com.apple.product-type.bundle.unit-test")
        groups = [self.objects[identifier] for identifier in target["fileSystemSynchronizedGroups"]]
        self.assertTrue(any(group["isa"] == "PBXFileSystemSynchronizedRootGroup"
                            and group.get("path") == "Tests/MKTownEditorTests" for group in groups))
        dependencies = [self.objects[identifier] for identifier in target["dependencies"]]
        self.assertTrue(any(dependency["isa"] == "PBXTargetDependency"
                            and self.objects[dependency["target"]] == self.target("MKTownEditor")
                            for dependency in dependencies))
        configurations = self.objects[target["buildConfigurationList"]]["buildConfigurations"]
        self.assertEqual(len(configurations), 2)
        for identifier in configurations:
            settings = self.objects[identifier]["buildSettings"]
            self.assertEqual(settings["TEST_HOST"],
                             "$(BUILT_PRODUCTS_DIR)/MKTownEditor.app/Contents/MacOS/MKTownEditor")
            self.assertEqual(settings["BUNDLE_LOADER"], "$(TEST_HOST)")

    def test_shared_scheme_runs_the_unit_tests(self):
        scheme = (REPOSITORY / "MKTownEditor.xcodeproj" / "xcshareddata" / "xcschemes"
                  / "MKTownEditor.xcscheme").read_text()
        testables = re.search(r"<Testables>(.*?)</Testables>", scheme, re.S).group(1)
        self.assertIn('BlueprintName = "MKTownEditorTests"', testables)
        target_id = next(identifier for identifier, obj in self.objects.items()
                         if obj == self.target("MKTownEditorTests"))
        self.assertIn(f'BlueprintIdentifier = "{target_id}"', testables)


class ProjectParsingTests(unittest.TestCase):
    def test_synchronized_group_survives_xcode_formatting_and_nested_dictionaries(self):
        group_id = "D20000000000000000000001"
        target_id = "D40000000000000000000001"
        for separator in (" ", "\n\t\t\t\t"):
            for comment in ("MKTownEditorTests", "Tests/MKTownEditorTests", "A group with spaces"):
                with self.subTest(separator=separator, comment=comment):
                    source = f'''{{ objects = {{
                        {group_id} /* {comment} */ = {{
                            isa = PBXFileSystemSynchronizedRootGroup;
                            explicitFileTypes = {{}}; explicitFolders = ();
                            path = Tests/MKTownEditorTests;
                        }};
                        {target_id} /* MKTownEditorTests */ = {{
                            isa = PBXNativeTarget;
                            fileSystemSynchronizedGroups = ({separator}{group_id},);
                        }};
                    }}; }}'''
                    objects = project_objects(source)
                    groups = objects[target_id]["fileSystemSynchronizedGroups"]
                    self.assertEqual(groups, [group_id])
                    self.assertEqual(objects[groups[0]]["path"], "Tests/MKTownEditorTests")
                    self.assertEqual(objects[groups[0]]["explicitFileTypes"], {})
                    compact = " ".join(line.strip() for line in source.splitlines())
                    self.assertEqual(project_objects(compact), objects)

    def test_invalid_project_is_rejected(self):
        with self.assertRaises(subprocess.CalledProcessError):
            project_objects("{ objects = {")


if __name__ == "__main__":
    unittest.main()
