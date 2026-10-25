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
            (ROOT / "MKTownEditorMobile.xcodeproj/project.pbxproj").read_text())
        self.info = plistlib.loads((ROOT / "Support/Mobile-Info.plist").read_bytes())

    def target(self, name):
        return next(obj for obj in self.objects.values()
                    if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == name)

    def sources(self, target):
        phases = [self.objects[key] for key in target["buildPhases"]]
        return {self.objects[self.objects[key]["fileRef"]]["path"]
                for phase in phases if phase["isa"] == "PBXSourcesBuildPhase"
                for key in phase["files"]}

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
        scheme = ET.parse(ROOT / "MKTownEditorMobile.xcodeproj/xcshareddata/xcschemes/MKTownEditorMobile.xcscheme")
        reference = scheme.find("./TestAction/Testables/TestableReference/BuildableReference")
        self.assertEqual(self.objects[reference.attrib["BlueprintIdentifier"]], target)
        self.assertEqual(reference.attrib["ReferencedContainer"], "container:MKTownEditorMobile.xcodeproj")

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

    def test_mobile_and_desktop_declare_the_same_markdown_type(self):
        desktop = plistlib.loads((ROOT / "Support/Info.plist").read_bytes())
        self.assertEqual(self.info["UTImportedTypeDeclarations"], desktop["UTImportedTypeDeclarations"])
        self.assertEqual(self.info["CFBundleDocumentTypes"], desktop["CFBundleDocumentTypes"])


if __name__ == "__main__":
    unittest.main()
