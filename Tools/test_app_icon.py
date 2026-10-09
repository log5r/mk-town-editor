"""Check the Icon Composer document of the app icon: python3 Tools/test_app_icon.py."""

import json
from pathlib import Path
import re
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
ICON = REPOSITORY / "Support" / "AppIcon.icon"
# The lightest background pixel ictool renders for the Dark rendition (see docs/app-icon.md).
DARK_BACKGROUND = (0x1E, 0x1E, 0x1E)


def relative_luminance(rgb):
    def linear(component):
        value = component / 255
        return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4
    red, green, blue = (linear(component) for component in rgb)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def contrast_ratio(first, second):
    lighter, darker = sorted((relative_luminance(first), relative_luminance(second)), reverse=True)
    return (lighter + 0.05) / (darker + 0.05)


def srgb(value):
    """Convert an icon.json color such as "srgb:1.00000,1.00000,1.00000,1.00000" to 8-bit RGB."""
    space, components = value.split(":")
    if space != "srgb":
        raise ValueError(f"unexpected color space: {value}")
    return tuple(round(float(component) * 255) for component in components.split(",")[:3])


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

    def test_dark_appearance_paints_the_monogram_light(self):
        """The Dark rendition swaps the white background for near black, where #26325C is unreadable."""
        svg_color = (0x26, 0x32, 0x5C)
        self.assertGreaterEqual(contrast_ratio(svg_color, srgb(self.document["fill"]["solid"])), 4.5)
        self.assertLess(contrast_ratio(svg_color, DARK_BACKGROUND), 1.5)
        for layer in self.layers():
            dark = [specialization["value"] for specialization in layer.get("fill-specializations", [])
                    if specialization.get("appearance") == "dark"]
            self.assertEqual(len(dark), 1, layer["name"])
            self.assertGreaterEqual(contrast_ratio(srgb(dark[0]["solid"]), DARK_BACKGROUND), 4.5)

    def test_clear_and_tinted_appearances_paint_the_monogram_white(self):
        """The one-hue styles keep the lightest layers prominent; the navy monogram blended into the background."""
        for layer in self.layers():
            tinted = [specialization["value"] for specialization in layer.get("fill-specializations", [])
                      if specialization.get("appearance") == "tinted"]
            self.assertEqual(tinted, [{"solid": "srgb:1.00000,1.00000,1.00000,1.00000"}], layer["name"])

    def test_monogram_uses_liquid_glass(self):
        group = self.document["groups"][0]
        self.assertTrue(group["specular"])
        self.assertTrue(group["translucency"]["enabled"])
        self.assertTrue(all(layer["glass"] for layer in self.layers()))


if __name__ == "__main__":
    unittest.main()
