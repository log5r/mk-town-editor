"""Verify CI failure propagation without compiling or launching the app."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class WorkflowConfigurationTests(unittest.TestCase):
    def workflow(self, name):
        # Use macOS's built-in YAML parser so CI needs no third-party Python modules.
        path = Path(__file__).resolve().parents[1] / ".github" / "workflows" / name
        result = subprocess.run(
            ["/usr/bin/ruby", "-rjson", "-ryaml", "-e",
             "puts JSON.generate(YAML.load_file(ARGV.fetch(0)))", str(path)],
            capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_runner_context_is_not_used_in_workflow_or_job_environment(self):
        for name in ("ci.yml", "release.yml"):
            workflow = self.workflow(name)
            environments = [workflow.get("env", {})]
            environments.extend(job.get("env", {}) for job in workflow["jobs"].values())
            for environment in environments:
                for key, value in environment.items():
                    with self.subTest(workflow=name, variable=key):
                        self.assertNotRegex(str(value), r"\$\{\{[^}]*\brunner\s*\.")

    def test_release_build_publish_and_diagnostics_share_the_output_directory(self):
        job = self.workflow("release.yml")["jobs"]["release"]
        output = "${{ runner.temp }}/release-output"
        for command in ("bash Tools/build-release.sh", "bash Tools/publish-release.sh"):
            step = next(step for step in job["steps"] if step.get("run") == command)
            self.assertEqual(step["env"]["RELEASE_OUTPUT_DIR"], output)
        upload = next(step for step in job["steps"]
                      if step.get("uses", "").startswith("actions/upload-artifact@"))
        self.assertTrue(upload["with"]["path"].startswith(output + "/notarization-"))
        self.assertEqual(upload["if"], "${{ always() }}")


class CIScriptTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.project = self.root / "project with spaces"
        tools = self.project / "Tools"
        tools.mkdir(parents=True)
        self.script = tools / "ci.sh"
        shutil.copy2(Path(__file__).with_name("ci.sh"), self.script)
        self.log = self.root / "calls.log"
        binaries = self.root / "bin"
        binaries.mkdir()
        for name in ("python3", "swift"):
            binary = binaries / name
            binary.write_text(
                '#!/bin/bash\n'
                'printf "%s|%s|%s\\n" "$PWD" "${0##*/}" "$*" >> "$CALL_LOG"\n'
                'if [[ "${0##*/}" == "python3" ]]; then\n'
                '    exit "$PYTHON_STATUS"\n'
                'elif [[ "$1" == "test" ]]; then\n'
                '    exit "$TEST_STATUS"\n'
                'fi\n'
                'exit "$BUILD_STATUS"\n'
            )
            binary.chmod(0o755)
        self.environment = {
            **os.environ,
            "PATH": f"{binaries}:/usr/bin:/bin",
            "CALL_LOG": str(self.log),
            "PYTHON_STATUS": "0",
            "TEST_STATUS": "0",
            "BUILD_STATUS": "0",
        }

    def run_script(self, *, pipeline=False):
        if pipeline:
            command = ["/bin/bash", "--noprofile", "--norc", "-e", "-o", "pipefail",
                       "-c", 'bash "$1" 2>&1 | tee "$2"', "ci-test",
                       str(self.script), str(self.root / "ci.log")]
        else:
            command = ["/bin/bash", str(self.script)]
        return subprocess.run(command, cwd=self.root, env=self.environment,
                              capture_output=True, text=True)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_success_runs_all_test_suites_and_release_build_from_project_root(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        prefix = f"{self.project}|"
        self.assertEqual(self.calls(), [
            prefix + "python3|-B -m unittest discover -s Tools -p test_*.py -v",
            prefix + "swift|test --force-resolved-versions",
            prefix + "swift|build --configuration release --force-resolved-versions",
        ])

    def test_python_failure_stops_before_swift(self):
        self.environment["PYTHON_STATUS"] = "17"
        self.assertEqual(self.run_script().returncode, 17)
        self.assertEqual(len(self.calls()), 1)

    def test_unit_test_failure_stops_before_release_build(self):
        self.environment["TEST_STATUS"] = "23"
        self.assertEqual(self.run_script().returncode, 23)
        self.assertEqual(len(self.calls()), 2)

    def test_release_build_failure_fails_ci(self):
        self.environment["BUILD_STATUS"] = "31"
        self.assertEqual(self.run_script().returncode, 31)
        self.assertEqual(len(self.calls()), 3)

    def test_log_pipeline_preserves_test_failure(self):
        self.environment["TEST_STATUS"] = "23"
        self.assertEqual(self.run_script(pipeline=True).returncode, 23)
        self.assertTrue((self.root / "ci.log").is_file())

if __name__ == "__main__":
    unittest.main()
