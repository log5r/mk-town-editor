"""Test the launcher without rebuilding or opening the GUI: python3 Tools/test_start.py."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class StartScriptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.project = self.root / "project with spaces"
        self.project.mkdir()
        self.script = self.project / "start.sh"
        shutil.copy2(Path(__file__).resolve().parents[1] / "start.sh", self.script)
        self.log = self.root / "calls.log"
        binary_dir = self.root / "bin"
        binary_dir.mkdir()
        swift = binary_dir / "swift"
        swift.write_text(
            '#!/bin/bash\n'
            'printf "%s|%s\\n" "$PWD" "$*" >> "$CALL_LOG"\n'
            'if [[ "$1" == "package" ]]; then\n'
            '    exit "${CLEAN_STATUS:-0}"\n'
            'fi\n'
            'exit "${RUN_STATUS:-0}"\n'
        )
        swift.chmod(0o755)
        self.environment = {
            **os.environ,
            "PATH": f"{binary_dir}:/usr/bin:/bin",
            "CALL_LOG": str(self.log),
            "CLEAN_STATUS": "0",
            "RUN_STATUS": "0",
        }

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

    def expected_call(self, arguments):
        return f"{self.project.resolve()}|{arguments}"

    def test_normal_start_builds_and_runs_release_from_project_directory(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [
            self.expected_call("run --configuration release MKTownEditor"),
        ])

    def test_rebuild_cleans_before_building_and_running_release(self):
        result = self.run_script("rebuild")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [
            self.expected_call("package clean"),
            self.expected_call("run --configuration release MKTownEditor"),
        ])

    def test_clean_failure_prevents_start(self):
        self.environment["CLEAN_STATUS"] = "17"
        self.assertEqual(self.run_script("rebuild").returncode, 17)
        self.assertEqual(self.calls(), [self.expected_call("package clean")])

    def test_run_failure_is_propagated(self):
        self.environment["RUN_STATUS"] = "23"
        self.assertEqual(self.run_script().returncode, 23)

    def test_invalid_arguments_do_not_clean_or_start(self):
        for arguments in [("unknown",), ("",), ("rebuild", "extra")]:
            with self.subTest(arguments=arguments):
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, 2)
                self.assertIn("Usage:", result.stderr)
                self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
