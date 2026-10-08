"""Test the launcher without rebuilding or opening the GUI: python3 Tools/test_start.py."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


RECORDER = (
    '#!/bin/bash\n'
    'printf "%s|%s|%s\\n" "$PWD" "${0##*/}" "$(printf "[%s]" "$@")" >> "$CALL_LOG"\n'
)


class StartScriptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.project = self.root / "project with spaces"
        (self.project / "Tools").mkdir(parents=True)
        self.script = self.project / "start.sh"
        shutil.copy2(Path(__file__).resolve().parents[1] / "start.sh", self.script)
        self.products = self.project / ".build" / "out" / "Products" / "Release"
        self.app = self.project / ".build" / "MKTownEditor.app"
        self.log = self.root / "calls.log"
        binary_dir = self.root / "bin"
        binary_dir.mkdir()
        self.write_executable(binary_dir / "swift", RECORDER + (
            'if [[ "$1" == "package" ]]; then\n'
            '    exit "$CLEAN_STATUS"\n'
            'elif [[ "$*" == *--show-bin-path* ]]; then\n'
            '    echo "$PRODUCTS"\n'
            '    exit 0\n'
            'fi\n'
            'exit "$BUILD_STATUS"\n'
        ))
        self.write_executable(binary_dir / "open", RECORDER + 'exit "$OPEN_STATUS"\n')
        self.write_executable(self.project / "Tools" / "make-app-bundle.sh",
                              RECORDER + 'exit "$BUNDLE_STATUS"\n')
        self.environment = {
            **os.environ,
            "PATH": f"{binary_dir}:/usr/bin:/bin",
            "CALL_LOG": str(self.log),
            "PRODUCTS": str(self.products),
            "CLEAN_STATUS": "0",
            "BUILD_STATUS": "0",
            "BUNDLE_STATUS": "0",
            "OPEN_STATUS": "0",
        }

    @staticmethod
    def write_executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    def run_script(self, *arguments):
        return subprocess.run(
            [str(self.script), *arguments],
            cwd=self.root,
            env=self.environment,
            capture_output=True,
            text=True,
        )

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def call(self, name, *arguments):
        return f"{self.project}|{name}|{''.join(f'[{argument}]' for argument in arguments)}"

    def launch_calls(self, *documents):
        return [
            self.call("swift", "build", "--configuration", "release"),
            self.call("swift", "build", "--configuration", "release", "--show-bin-path"),
            self.call("make-app-bundle.sh", str(self.products), str(self.app)),
            self.call("open", "-a", str(self.app), *documents),
        ]

    def test_normal_start_builds_bundles_and_opens_the_release_app(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), self.launch_calls())

    def test_no_running_warning_when_the_app_is_not_running(self):
        for _ in range(5):
            result = self.run_script()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("already running", result.stderr)

    def test_warns_when_the_bundled_app_is_already_running(self):
        executable = self.app / "Contents" / "MacOS" / "MKTownEditor"
        self.write_executable(Path(self.environment["PATH"].split(":")[0]) / "ps",
                              f'#!/bin/bash\necho /usr/bin/grep\necho "{executable}"\n')
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already running", result.stderr)

    def test_rebuild_cleans_before_building_and_opening(self):
        result = self.run_script("rebuild")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [self.call("swift", "package", "clean"), *self.launch_calls()])

    def test_documents_are_opened_by_absolute_path_relative_to_the_caller(self):
        (self.root / "notes").mkdir()
        relative = self.root / "notes" / "日本語 メモ.md"
        relative.write_text("# a\n")
        absolute = self.root / "b.markdown"
        absolute.write_text("b\n")
        result = self.run_script("rebuild", "notes/日本語 メモ.md", str(absolute))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [
            self.call("swift", "package", "clean"),
            *self.launch_calls(str(relative), str(absolute)),
        ])

    def test_clean_failure_prevents_start(self):
        self.environment["CLEAN_STATUS"] = "17"
        self.assertEqual(self.run_script("rebuild").returncode, 17)
        self.assertEqual(self.calls(), [self.call("swift", "package", "clean")])

    def test_build_failure_prevents_bundling_and_opening(self):
        self.environment["BUILD_STATUS"] = "23"
        self.assertEqual(self.run_script().returncode, 23)
        self.assertEqual(self.calls(), self.launch_calls()[:1])

    def test_bundle_failure_prevents_opening(self):
        self.environment["BUNDLE_STATUS"] = "29"
        self.assertEqual(self.run_script().returncode, 29)
        self.assertEqual(self.calls(), self.launch_calls()[:3])

    def test_open_failure_is_propagated(self):
        self.environment["OPEN_STATUS"] = "31"
        self.assertEqual(self.run_script().returncode, 31)

    def test_invalid_arguments_do_not_clean_or_start(self):
        (self.root / "folder").mkdir()
        for arguments in [("unknown",), ("",), ("rebuild", "extra"), ("folder",),
                          ("rebuild", "rebuild")]:
            with self.subTest(arguments=arguments):
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, 2)
                self.assertIn("Usage:", result.stderr)
                self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
