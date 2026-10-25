"""Guard the native iOS target's source sharing and resizability configuration."""

from pathlib import Path
import plistlib
import unittest
import xml.etree.ElementTree as ET

from test_xcode_project import project_objects

ROOT = Path(__file__).resolve().parents[1]


class MobileProjectTests(unittest.TestCase):
    def setUp(self):
        self.objects = project_objects(
            (ROOT / "MKTownEditor.xcodeproj/project.pbxproj").read_text())
        self.info = plistlib.loads((ROOT / "Support/Mobile-Info.plist").read_bytes())

    def target(self, name):
        return next(obj for obj in self.objects.values()
                    if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == name)

    def sources(self, target):
        phases = [self.objects[key] for key in target["buildPhases"]]
        return {self.file_path(self.objects[key]["fileRef"])
                for phase in phases if phase["isa"] == "PBXSourcesBuildPhase"
                for key in phase["files"]}

    def file_path(self, identifier):
        obj = self.objects[identifier]
        path = Path(obj.get("path", ""))
        parents = [key for key, group in self.objects.items()
                   if group.get("isa") == "PBXGroup" and identifier in group["children"]]
        self.assertLessEqual(len(parents), 1, f"Ambiguous group for {identifier}")
        return str(Path(self.file_path(parents[0])) / path) if parents else str(path)

    def test_mobile_target_reuses_document_io_and_includes_all_mobile_sources(self):
        sources = self.sources(self.target("MKTownEditorMobile"))
        expected = {str(p.relative_to(ROOT)) for directory in ("MKTownMobile", "MKTownMobileCore")
                    for p in (ROOT / "Sources" / directory).glob("*.swift")}
        expected.update({"Sources/MKTownEditor/MarkdownDocument.swift",
                         "Sources/MKTownEditor/MarkdownTextFormat.swift"})
        self.assertEqual(sources, expected)
        for path in sources:
            self.assertNotIn("import AppKit", (ROOT / path).read_text())

    def test_adaptive_layout_has_no_device_or_screen_size_assumptions(self):
        source = (ROOT / "Sources/MKTownMobile/MobileEditorWorkspace.swift").read_text()
        for forbidden in ("UIScreen.main", "userInterfaceIdiom", "UIDevice.current.orientation",
                          "ignoresSafeArea", "UIViewRepresentable"):
            self.assertNotIn(forbidden, source)
        self.assertIn("GeometryReader", source)
        self.assertIn("TextEditor", source)

    def test_all_mobile_unit_tests_are_in_the_shared_scheme(self):
        target = self.target("MKTownEditorMobileTests")
        expected = {str(p.relative_to(ROOT))
                    for directory in ("MKTownMobileTests", "MKTownMobileCoreTests")
                    for p in (ROOT / "Tests" / directory).glob("*.swift")}
        self.assertEqual(self.sources(target), expected)
        scheme = ET.parse(ROOT / "MKTownEditor.xcodeproj/xcshareddata/xcschemes/MKTownEditorMobile.xcscheme")
        reference = scheme.find("./TestAction/Testables/TestableReference/BuildableReference")
        self.assertEqual(self.objects[reference.attrib["BlueprintIdentifier"]], target)
        self.assertEqual(reference.attrib["ReferencedContainer"], "container:MKTownEditor.xcodeproj")

    def test_document_browser_opens_files_in_place_and_supports_all_orientations(self):
        self.assertTrue(self.info["UISupportsDocumentBrowser"])
        self.assertTrue(self.info["LSSupportsOpeningDocumentsInPlace"])
        self.assertTrue(self.info["UIApplicationSceneManifest"]["UIApplicationSupportsMultipleScenes"])
        self.assertNotIn("UIRequiresFullScreen", self.info)
        self.assertNotIn("UISupportedInterfaceOrientations~ipad", self.info)
        self.assertEqual(set(self.info["UISupportedInterfaceOrientations"]), {
            "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"})

    def test_target_supports_both_phone_and_tablet_and_uses_current_sdk(self):
        target = self.target("MKTownEditorMobile")
        configurations = self.objects[target["buildConfigurationList"]]["buildConfigurations"]
        for key in configurations:
            settings = self.objects[key]["buildSettings"]
            self.assertEqual(settings["TARGETED_DEVICE_FAMILY"], "1,2")
            self.assertEqual(settings["SDKROOT"], "iphoneos")
            self.assertEqual(settings["SUPPORTED_PLATFORMS"], "iphoneos iphonesimulator")
            self.assertEqual(settings["IPHONEOS_DEPLOYMENT_TARGET"], "18.0")

    def test_mobile_tests_depend_on_and_load_the_ios_app(self):
        target = self.target("MKTownEditorMobileTests")
        dependencies = [self.objects[key] for key in target["dependencies"]]
        self.assertEqual(len(dependencies), 1)
        dependency = dependencies[0]
        self.assertEqual(self.objects[dependency["target"]], self.target("MKTownEditorMobile"))
        proxy = self.objects[dependency["targetProxy"]]
        self.assertEqual(proxy["remoteGlobalIDString"], dependency["target"])
        self.assertEqual(self.objects[proxy["containerPortal"]]["isa"], "PBXProject")
        for key in self.objects[target["buildConfigurationList"]]["buildConfigurations"]:
            settings = self.objects[key]["buildSettings"]
            self.assertEqual(settings["TEST_HOST"],
                             "$(BUILT_PRODUCTS_DIR)/MKTownEditorMobile.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/MKTownEditorMobile")
            self.assertEqual(settings["BUNDLE_LOADER"], "$(TEST_HOST)")
            self.assertEqual(settings["SDKROOT"], "iphoneos")
            self.assertEqual(settings["SUPPORTED_PLATFORMS"], "iphoneos iphonesimulator")
            if self.objects[key]["name"] == "Debug":
                self.assertEqual(settings["ENABLE_TESTABILITY"], "YES")

    def test_document_sources_and_icon_use_the_desktop_file_references(self):
        for path in ("Sources/MKTownEditor/MarkdownDocument.swift",
                     "Sources/MKTownEditor/MarkdownTextFormat.swift", "Support/AppIcon.icon"):
            references = [key for key, obj in self.objects.items()
                          if obj.get("isa") == "PBXFileReference" and self.file_path(key) == path]
            self.assertEqual(len(references), 1, path)
            for name in ("MKTownEditor", "MKTownEditorMobile"):
                phases = [self.objects[key] for key in self.target(name)["buildPhases"]]
                files = [self.objects[key]["fileRef"] for phase in phases
                         if phase["isa"] in ("PBXSourcesBuildPhase", "PBXResourcesBuildPhase")
                         for key in phase["files"]]
                self.assertEqual(files.count(references[0]), 1, (name, path))

    def test_mobile_and_desktop_declare_the_same_markdown_type(self):
        desktop = plistlib.loads((ROOT / "Support/Info.plist").read_bytes())
        self.assertEqual(self.info["UTImportedTypeDeclarations"], desktop["UTImportedTypeDeclarations"])
        self.assertEqual(self.info["CFBundleDocumentTypes"], desktop["CFBundleDocumentTypes"])


if __name__ == "__main__":
    unittest.main()
