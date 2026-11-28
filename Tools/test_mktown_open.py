"""Exercise mktown-open arguments without asking Launch Services to open a window."""

from pathlib import Path
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qs, unquote, urlsplit


class MKTownOpenTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temporary.cleanup)
        directory = Path(temporary.name).resolve()
        cls.module_cache = directory / "module-cache"
        cls.file = directory / "記事 と図.md"
        cls.file.write_text("# 原稿\n", encoding="utf-8")
        cls.script = directory / "mktown-open.swift"
        source = Path(__file__).with_name("mktown-open.swift").read_text(encoding="utf-8")
        cls.script.write_text(source + """

// Capture the URL handed to AppKit without launching the app.
private struct NSWorkspace {
    static let shared = NSWorkspace()
    func open(_ url: URL) -> Bool {
        print(url.absoluteString)
        return true
    }
}
""", encoding="utf-8")

    def run_cli(self, *arguments):
        return subprocess.run(["swift", "-module-cache-path", str(self.module_cache),
                               str(self.script), *arguments],
                              capture_output=True, text=True)

    def assert_open_request(self, result, expected_options):
        self.assertEqual(result.returncode, 0, result.stderr)
        url = urlsplit(result.stdout.strip())
        self.assertEqual((url.scheme, url.netloc), ("mktowneditor", "open"))
        query = parse_qs(url.query)
        file_url, = query.pop("url")
        file = urlsplit(file_url)
        self.assertEqual(file.scheme, "file")
        self.assertEqual(Path(unquote(file.path)).resolve(), self.file)
        self.assertEqual(query, expected_options)

    def test_read_only_and_line_can_be_combined_in_either_order(self):
        for options in (("--readonly", "--line", "42"), ("--line", "42", "--readonly")):
            with self.subTest(options=options):
                result = self.run_cli(*options, str(self.file))
                self.assert_open_request(result, {"line": ["42"], "readonly": ["1"]})

    def test_read_only_without_line_and_existing_line_only_open(self):
        for options, query in ((["--readonly"], {"readonly": ["1"]}),
                               (["--line", "12"], {"line": ["12"]})):
            with self.subTest(options=options):
                result = self.run_cli(*options, self.file.as_uri())
                self.assert_open_request(result, query)

    def test_duplicate_read_only_option_does_not_open_file(self):
        result = self.run_cli("--readonly", "--readonly", str(self.file))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--readonly can only be specified once", result.stderr)
        self.assertEqual(result.stdout, "")
