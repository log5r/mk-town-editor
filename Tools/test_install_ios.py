"""Test the iOS device installer with fake Xcode tools: python3 Tools/test_install_ios.py."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


RECORDER = (
    '#!/bin/bash\n'
    'printf "%s|%s\\n" "${0##*/}" "$(printf "[%s]" "$@")" >> "$CALL_LOG"\n'
)

FAKE_XCRUN = RECORDER + r'''
[[ "$1" == devicectl ]] || exit 99
shift
case "$1 $2" in
  "list devices")
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --json-output ]]; then cp "$DEVICES_JSON" "$2"; fi
      shift
    done
    exit "$LIST_STATUS" ;;
  "device install") exit "$INSTALL_STATUS" ;;
  "device process") exit "$LAUNCH_STATUS" ;;
esac
exit 98
'''

FAKE_XCODEBUILD = RECORDER + r'''
team="$PROJECT_TEAM"
for argument in "$@"; do
  [[ "$argument" == DEVELOPMENT_TEAM=* ]] && team="${argument#DEVELOPMENT_TEAM=}"
done
if [[ " $* " == *" -showBuildSettings "* ]]; then
  cat <<JSON
[{"target": "MKTownEditorMobileTests", "buildSettings": {"WRAPPER_EXTENSION": "xctest",
  "PLATFORM_NAME": "iphoneos", "TARGET_BUILD_DIR": "$PRODUCTS", "FULL_PRODUCT_NAME": "T.xctest"}},
 {"target": "MKTownEditorMobile", "buildSettings": {"WRAPPER_EXTENSION": "app",
  "PLATFORM_NAME": "iphoneos", "TARGET_BUILD_DIR": "$PRODUCTS",
  "FULL_PRODUCT_NAME": "MKTownEditorMobile.app", "DEVELOPMENT_TEAM": "$team"}}]
JSON
  exit "$SETTINGS_STATUS"
fi
echo "compiling sources"
[[ "$BUILD_STATUS" -eq 0 ]] || { echo "error: build failed"; exit "$BUILD_STATUS"; }
app="$PRODUCTS/MKTownEditorMobile.app"
mkdir -p "$app"
cat > "$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>MKTownEditorMobile</string>
<key>CFBundleIdentifier</key><string>jp.mktowneditor.mobile</string>
</dict></plist>
PLIST
printf 'binary' > "$app/MKTownEditorMobile"
'''


def device(name, udid, *, reality="physical", platform="iOS", paired=True,
           state="disconnected", transport="localNetwork", developer_mode="enabled"):
    return {
        "identifier": f"core-{udid}",
        "properties": {
            "connection": {"pairingState": "paired" if paired else "unpaired",
                           "state": state, "transportType": transport},
            "hardware": {"reality": reality, "platform": platform, "udid": udid,
                         "marketingName": "iPhone 18 Pro"},
            "state": {"name": name, "developerModeStatus": developer_mode},
        },
    }


class InstallIOSScriptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.project = self.root / "project with spaces"
        (self.project / "MKTownEditor.xcodeproj").mkdir(parents=True)
        self.script = self.project / "install-ios.sh"
        shutil.copy2(Path(__file__).resolve().parents[1] / "install-ios.sh", self.script)
        self.products = self.project / "build" / "Release-iphoneos"
        self.log = self.root / "calls.log"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.write_executable(self.bin / "xcrun", FAKE_XCRUN)
        self.write_executable(self.bin / "xcodebuild", FAKE_XCODEBUILD)
        self.devices_json = self.root / "devices.json"
        self.set_devices(device("Work iPhone", "UDID-1"))
        self.environment = {
            "HOME": str(self.root),
            "TMPDIR": str(self.root),
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "CALL_LOG": str(self.log),
            "DEVICES_JSON": str(self.devices_json),
            "PRODUCTS": str(self.products),
            "PROJECT_TEAM": "",
            "LIST_STATUS": "0",
            "SETTINGS_STATUS": "0",
            "BUILD_STATUS": "0",
            "INSTALL_STATUS": "0",
            "LAUNCH_STATUS": "0",
        }

    @staticmethod
    def write_executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    def set_devices(self, *devices):
        self.devices_json.write_text(json.dumps({"info": {"outcome": "success"},
                                                 "result": {"devices": list(devices)}}))

    def run_script(self, *arguments):
        return subprocess.run([str(self.script), *arguments], cwd=self.root, env=self.environment,
                              capture_output=True, text=True)

    def calls(self, name=None):
        lines = self.log.read_text().splitlines() if self.log.exists() else []
        return [line for line in lines if name is None or line.startswith(f"{name}|")]

    @staticmethod
    def call(name, *arguments):
        return f"{name}|{''.join(f'[{argument}]' for argument in arguments)}"

    def build_arguments(self, *settings):
        return (
            "-project", str(self.project / "MKTownEditor.xcodeproj"),
            "-scheme", "MKTownEditorMobile", "-configuration", "Release",
            "-destination", "generic/platform=iOS",
            "-derivedDataPath", str(self.project / "build" / "InstallDerivedData-iOS"),
            "-allowProvisioningUpdates", *settings,
        )

    def install_call(self, identifier="core-UDID-1"):
        return self.call("xcrun", "devicectl", "device", "install", "app", "--device", identifier,
                         str(self.products / "MKTownEditorMobile.app"))

    def installed(self):
        return any(line.startswith("xcrun|[devicectl][device][install]") for line in self.calls("xcrun"))

    def test_builds_with_team_and_installs_on_the_only_reachable_device(self):
        result = self.run_script("--team", "ABCDE12345")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("xcodebuild"), [
            self.call("xcodebuild", *self.build_arguments("DEVELOPMENT_TEAM=ABCDE12345"), "-showBuildSettings", "-json"),
            self.call("xcodebuild", *self.build_arguments("DEVELOPMENT_TEAM=ABCDE12345"), "build"),
        ])
        self.assertEqual(self.calls("xcrun")[-1], self.install_call())
        self.assertIn("Work iPhone（iPhone 18 Pro・ネットワーク）", result.stdout)
        self.assertIn("インストールしました: jp.mktowneditor.mobile", result.stdout)
        self.assertNotIn("[process]", self.log.read_text())

    def test_simulators_unpaired_and_unavailable_devices_are_not_selected(self):
        self.set_devices(
            device("Simulator", "SIM", reality="simulated", state="connected"),
            device("Stranger", "UDID-2", paired=False),
            device("Off iPhone", "UDID-3", state="unavailable"),
            device("Mac", "UDID-4", platform="macOS"),
            device("Desk iPhone", "UDID-1", state="connected", transport="wired"),
        )
        result = self.run_script("--team", "ABCDE12345")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Desk iPhone（iPhone 18 Pro・USB）", result.stdout)
        self.assertEqual(self.calls("xcrun")[-1], self.install_call())

    def test_several_reachable_devices_require_choosing_before_building(self):
        self.set_devices(device("Work iPhone", "UDID-1"), device("Home iPad", "UDID-2"))
        result = self.run_script("--team", "ABCDE12345")
        self.assertEqual(result.returncode, 1)
        self.assertIn("--deviceで指定", result.stderr)
        self.assertIn("Work iPhone", result.stderr)
        self.assertIn("Home iPad", result.stderr)
        self.assertEqual(self.calls("xcodebuild"), [])

    def test_device_can_be_chosen_by_name_udid_or_identifier(self):
        self.set_devices(device("Work iPhone", "UDID-1"), device("Home iPad", "UDID-2"))
        for query in ("Home iPad", "home ipad", "UDID-2", "core-UDID-2"):
            with self.subTest(query=query):
                self.log.unlink(missing_ok=True)
                result = self.run_script("--team", "ABCDE12345", "--device", query)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls("xcrun")[-1], self.install_call("core-UDID-2"))

    def test_ambiguous_device_names_require_a_udid(self):
        self.set_devices(device("iPhone", "UDID-1"), device("iPhone", "UDID-2"))
        result = self.run_script("--team", "ABCDE12345", "--device", "iPhone")
        self.assertEqual(result.returncode, 1)
        self.assertIn("UDIDで指定", result.stderr)
        self.assertEqual(self.calls("xcodebuild"), [])

    def test_unusable_devices_fail_before_building(self):
        cases = [
            ((device("Off iPhone", "UDID-1", state="unavailable"),), (), "接続できるiPhone・iPadがありません"),
            ((device("Off iPhone", "UDID-1", state="unavailable"),), ("--device", "Off iPhone"), "端末に接続できません"),
            ((device("Stranger", "UDID-1", paired=False),), ("--device", "Stranger"), "ペアリングしていない"),
            ((device("Work iPhone", "UDID-1"),), ("--device", "Other"), "端末が見つかりません: Other"),
            ((device("Work iPhone", "UDID-1", developer_mode="disabled"),), (), "デベロッパモードが無効"),
            ((), (), "接続できるiPhone・iPadがありません"),
        ]
        for devices, arguments, message in cases:
            with self.subTest(message=message, arguments=arguments):
                self.log.unlink(missing_ok=True)
                self.set_devices(*devices)
                result = self.run_script("--team", "ABCDE12345", *arguments)
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.calls("xcodebuild"), [])

    def test_deprecated_device_fields_are_still_read(self):
        self.set_devices({
            "identifier": "core-UDID-1",
            "hardwareProperties": {"reality": "physical", "platform": "iOS", "udid": "UDID-1",
                                   "marketingName": "iPhone 18 Pro"},
            "connectionProperties": {"pairingState": "paired", "tunnelState": "disconnected",
                                     "transportType": "localNetwork"},
            "deviceProperties": {"name": "Old iPhone", "developerModeStatus": "enabled"},
        })
        result = self.run_script("--team", "ABCDE12345")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Old iPhone", result.stdout)
        self.assertEqual(self.calls("xcrun")[-1], self.install_call())

    def test_device_list_failure_is_reported(self):
        self.environment["LIST_STATUS"] = "3"
        result = self.run_script("--team", "ABCDE12345")
        self.assertEqual(result.returncode, 1)
        self.assertIn("端末の一覧を取得できませんでした", result.stderr)

    def test_list_devices_prints_physical_devices_without_building(self):
        self.set_devices(device("Work iPhone", "UDID-1"), device("Simulator", "SIM", reality="simulated"),
                         device("Off iPhone", "UDID-2", state="unavailable"))
        result = self.run_script("--list-devices")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Work iPhone（iPhone 18 Pro・ネットワーク）  UDID-1", result.stdout)
        self.assertIn("Off iPhone（iPhone 18 Pro・接続できません）  UDID-2", result.stdout)
        self.assertNotIn("Simulator", result.stdout)
        self.assertEqual(self.calls("xcodebuild"), [])

    def test_team_comes_from_environment_then_project_settings(self):
        self.environment["APPLE_TEAM_ID"] = "ZYXWV98765"
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[DEVELOPMENT_TEAM=ZYXWV98765]", self.calls("xcodebuild")[-1])

        del self.environment["APPLE_TEAM_ID"]
        self.environment["PROJECT_TEAM"] = "LOCAL12345"
        self.log.unlink()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("xcodebuild")[-1], self.call("xcodebuild", *self.build_arguments(), "build"))

    def test_missing_team_fails_before_building(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Signing.local.xcconfig", result.stderr)
        self.assertFalse(any(line.endswith("[build]") for line in self.calls("xcodebuild")))

    def test_invalid_team_and_build_settings_are_rejected_before_any_tool_runs(self):
        for arguments in (("--team", "abc"), ("--team", "ABCDE12345", "--", "-quiet")):
            with self.subTest(arguments=arguments):
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(self.calls(), [])

    def test_extra_build_settings_are_passed_to_xcodebuild(self):
        result = self.run_script("--team", "ABCDE12345", "--", "SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEMO")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("xcodebuild")[-1], self.call(
            "xcodebuild", *self.build_arguments("DEVELOPMENT_TEAM=ABCDE12345",
                                                "SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEMO"), "build"))

    def test_build_failure_keeps_the_full_log_and_skips_installing(self):
        self.environment["BUILD_STATUS"] = "65"
        result = self.run_script("--team", "ABCDE12345")
        self.assertEqual(result.returncode, 65)
        self.assertIn("ビルドに失敗しました", result.stderr)
        logs = list((self.project / ".build-logs").glob("install-ios-*.log"))
        self.assertEqual(len(logs), 1)
        self.assertIn(f"全ログ: {logs[0]}", result.stdout)
        self.assertIn("error: build failed", logs[0].read_text())
        self.assertFalse(self.installed())

    def test_each_run_keeps_its_own_log(self):
        for _ in range(2):
            self.assertEqual(self.run_script("--team", "ABCDE12345").returncode, 0)
        self.assertEqual(len(list((self.project / ".build-logs").glob("install-ios-*.log"))), 2)

    def test_build_output_is_formatted_by_xcsift_when_available(self):
        self.write_executable(self.bin / "xcsift", RECORDER + 'sed "s/^/sifted: /"\n')
        result = self.run_script("--team", "ABCDE12345")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.call("xcsift", "-f", "toon", "-w"), self.calls("xcsift"))
        self.assertIn("sifted: compiling sources", result.stdout)

    def test_launch_after_install_and_report_launch_failure(self):
        result = self.run_script("--team", "ABCDE12345", "--launch")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("xcrun")[-2:], [
            self.install_call(),
            self.call("xcrun", "devicectl", "device", "process", "launch", "--device", "core-UDID-1",
                      "--terminate-existing", "jp.mktowneditor.mobile"),
        ])

        self.environment["LAUNCH_STATUS"] = "1"
        result = self.run_script("--team", "ABCDE12345", "--launch")
        self.assertEqual(result.returncode, 1)
        self.assertIn("インストールは完了しましたが、起動できませんでした", result.stderr)

    def test_install_failure_is_reported(self):
        self.environment["INSTALL_STATUS"] = "1"
        result = self.run_script("--team", "ABCDE12345", "--launch")
        self.assertEqual(result.returncode, 1)
        self.assertIn("インストールに失敗しました", result.stderr)
        self.assertNotIn("[process]", "".join(self.calls("xcrun")))

    def test_prebuilt_app_is_installed_without_building(self):
        self.assertEqual(self.run_script("--team", "ABCDE12345").returncode, 0)
        self.log.unlink()
        result = self.run_script("--app", str(self.products / "MKTownEditorMobile.app"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("xcodebuild"), [])
        self.assertEqual(self.calls("xcrun")[-1], self.install_call())

    def test_invalid_prebuilt_apps_and_option_mixes_are_rejected(self):
        not_app = self.root / "Folder.app"
        not_app.mkdir()
        for arguments, message in [
            (("--app", str(self.root / "missing.app")), ".appがありません"),
            (("--app", str(not_app)), "iOSアプリのバンドルではありません"),
            (("--app", str(not_app), "--team", "ABCDE12345"), "併用できません"),
            (("--app", str(not_app), "--scheme", "Other"), "併用できません"),
        ]:
            with self.subTest(arguments=arguments):
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.calls(), [])

    def test_unknown_arguments_and_missing_values_are_rejected(self):
        for arguments in (("--bogus",), ("--device",), ("--team", "")):
            with self.subTest(arguments=arguments):
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
