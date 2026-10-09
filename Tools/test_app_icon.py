"""Check the Icon Composer document of the app icon: python3 Tools/test_app_icon.py."""

import json
from pathlib import Path
import re
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
ICON = REPOSITORY / "Support" / "AppIcon.icon"


class AppIconTests(unittest.TestCase):
    def setUp(self):
        self.document = json.loads((ICON / "icon.json").read_text())

    def layers(self):
        return [layer for group in self.document["groups"] for layer in group["layers"]]

    def test_every_layer_image_is_in_the_document(self):
        """Icon Composer and actool look up layer images by name in Assets; a missing one renders nothing."""
        names = [layer["image-name"] for layer in self.layers()]
        self.assertTrue(names)
        self.assertEqual(sorted(names), sorted(path.name for path in (ICON / "Assets").iterdir()))

    def test_white_background_with_the_mt_monogram_in_the_brand_color(self):
        self.assertEqual(self.document["fill"], {"solid": "srgb:1.00000,1.00000,1.00000,1.00000"})
        self.assertEqual(self.document["supported-platforms"], {"squares": ["macOS"]})
        svg = (ICON / "Assets" / "MT.svg").read_text()
        self.assertEqual(re.findall(r'fill="([^"]+)"', svg), ["#26325C"])
        self.assertIn('viewBox="0 0 1024 1024"', svg)

    def test_monogram_uses_liquid_glass(self):
        group = self.document["groups"][0]
        self.assertTrue(group["specular"])
        self.assertTrue(group["translucency"]["enabled"])
        self.assertTrue(all(layer["glass"] for layer in self.layers()))


if __name__ == "__main__":
    unittest.main()
