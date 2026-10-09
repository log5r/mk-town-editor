"""Exercise release failure gates without Apple credentials or GitHub writes."""

import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


REPOSITORY = Path(__file__).resolve().parents[1]
MOCK = r'''
import json, os, pathlib, plistlib, struct, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CALL_LOG'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\n')
stage = name
if name == 'security':
    stage += ':' + args[0]
elif name == 'xcrun':
    stage += ':' + ':'.join(args[:2])
elif name == 'codesign':
    stage += ':' + args[0]
elif name == 'gh':
    stage += ':' + ':'.join(args[:2])
if stage == os.environ.get('FAIL_STAGE'):
    sys.exit(23)
if name == 'security':
    if args[0] == 'list-keychains' and '-s' not in args:
        print('    "/original keychains/login.keychain-db"')
    if args[0] == 'find-identity':
        team = os.environ.get('IDENTITY_TEAM', os.environ['APPLE_TEAM_ID'])
        kind = os.environ.get('IDENTITY_KIND', 'Developer ID Application')
        print('  1) ' + 'A' * 40 + ' "' + kind + ': Test (' + team + ')"')
elif name == 'xcodebuild':
    archive = pathlib.Path(args[args.index('-archivePath') + 1])
    app = archive / 'Products/Applications/MKTownEditor.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    # Minimal Mach-O headers let the system lipo validate real CPU slices in one test.
    arm64 = struct.pack('<IIIIIIII', 0xfeedfacf, 0x0100000c, 0, 2, 0, 0, 0, 0)
    x86_64 = struct.pack('<IIIIIIII', 0xfeedfacf, 0x01000007, 3, 2, 0, 0, 0, 0)
    fat = (struct.pack('>II', 0xcafebabe, 2) +
           struct.pack('>IIIII', 0x0100000c, 0, 48, 32, 0) +
           struct.pack('>IIIII', 0x01000007, 3, 80, 32, 0) + arm64 + x86_64)
    (app / 'MacOS/MKTownEditor').write_bytes(arm64 if os.environ.get('THIN_ARCHIVE') else fat)
    source = next(a.split('=', 1)[1] for a in args if a.startswith('INFOPLIST_FILE='))
    (app / 'Info.plist').write_bytes(pathlib.Path(source).read_bytes())
    if os.environ.get('ARCHIVE_VERSION'):
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        info['CFBundleShortVersionString'] = os.environ['ARCHIVE_VERSION']
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    packages = pathlib.Path(args[args.index('-clonedSourcePackagesDirPath') + 1])
    license = packages / 'checkouts/SwiftMath/LICENSE'
    license.parent.mkdir(parents=True)
    license.write_text('MIT license fixture for SwiftMath')
elif name == 'codesign' and args[0] == '--display':
    signature = ['Authority=Developer ID Application: Test',
                 'TeamIdentifier=' + os.environ['APPLE_TEAM_ID'],
                 'flags=0x10000(runtime)', 'Timestamp=Oct 10, 2026']
    print('\n'.join(s for s in signature if os.environ.get('OMIT_SIGNATURE', '!') not in s), file=sys.stderr)
elif name == 'xcrun':
    if args[:2] == ['notarytool', 'submit']:
        print(json.dumps({'id': 'test-submission', 'status': os.environ.get('NOTARY_STATUS', 'Accepted')}))
    elif args[:2] == ['notarytool', 'log']:
        pathlib.Path(args[-1]).write_text('{"issues": []}')
    elif args[:2] == ['stapler', 'staple']:
        (pathlib.Path(args[2]) / 'Contents/stapled-ticket').write_text('ticket')
elif name == 'gh':
    if args[:2] == ['release', 'view']:
        state = os.environ.get('EXISTING_RELEASE', 'absent')
        if state == 'absent':
            sys.exit(1)
        print(json.dumps({'isDraft': state == 'draft'}))
'''


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.project = self.root / 'project with spaces'
        for folder in ('Tools', 'Support', 'docs'):
            (self.project / folder).mkdir(parents=True)
        for name in ('build-release.sh', 'publish-release.sh', 'release-common.sh'):
            shutil.copy2(REPOSITORY / 'Tools' / name, self.project / 'Tools' / name)
        for name in ('Support/Info.plist', 'LICENSE', 'docs/third-party-licenses.md'):
            shutil.copy2(REPOSITORY / name, self.project / name)
        binaries = self.root / 'bin'
        binaries.mkdir()
        for name in ('security', 'xcodebuild', 'codesign', 'xcrun', 'lipo', 'spctl', 'gh'):
            path = binaries / name
            path.write_text(f'#!{sys.executable}\n' + MOCK)
            path.chmod(0o755)
        (binaries / 'python3').symlink_to(sys.executable)
        self.output = self.root / 'output with spaces'
        self.log = self.root / 'calls.jsonl'
        self.environment = {
            **os.environ, 'PATH': f'{binaries}:/usr/bin:/bin', 'TMPDIR': str(self.root),
            'CALL_LOG': str(self.log), 'RELEASE_TAG': 'v1.2.3', 'RELEASE_BUILD_NUMBER': '42',
            'RELEASE_OUTPUT_DIR': str(self.output), 'APPLE_TEAM_ID': 'ABCDE12345',
            'APPLE_CERTIFICATE_P12_BASE64': base64.b64encode(b'fake certificate').decode(),
            'APPLE_CERTIFICATE_PASSWORD': 'fake p12 password', 'APPLE_ID': 'test@example.invalid',
            'APPLE_APP_SPECIFIC_PASSWORD': 'fake notary password',
        }

    def run_script(self, name='build-release.sh'):
        return subprocess.run(['/bin/bash', str(self.project / 'Tools' / name)], cwd=self.root,
                              env=self.environment, capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def asset(self):
        return self.output / f'MKTownEditor-{self.environment["RELEASE_TAG"][1:]}-macOS-universal.zip'

    def assert_cleaned_up(self):
        self.assertFalse(list(self.root.glob('mktown-release.*')))
        self.assertTrue(any(call[:2] == ['security', 'delete-keychain'] for call in self.calls()))
        self.assertIn(['security', 'list-keychains', '-d', 'user', '-s',
                       '/original keychains/login.keychain-db'], self.calls())

    def test_success_packages_stapled_app_with_versions_licenses_and_checksum(self):
        original = (self.project / 'Support/Info.plist').read_bytes()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(self.asset()) as archive:
            prefix = 'MKTownEditor-1.2.3/'
            info = plistlib.loads(archive.read(prefix + 'MKTownEditor.app/Contents/Info.plist'))
            self.assertEqual(info['CFBundleShortVersionString'], '1.2.3')
            self.assertEqual(info['CFBundleVersion'], '42')
            self.assertEqual(archive.read(prefix + 'MKTownEditor.app/Contents/stapled-ticket'), b'ticket')
            self.assertIn(prefix + 'LICENSE.txt', archive.namelist())
            self.assertIn(prefix + 'ThirdPartyLicenses.md', archive.namelist())
            self.assertEqual(archive.read(prefix + 'SwiftMath-LICENSE.txt'), b'MIT license fixture for SwiftMath')
        self.assertEqual((self.project / 'Support/Info.plist').read_bytes(), original)
        checksum = subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS.txt'], cwd=self.output,
                                  capture_output=True, text=True)
        self.assertEqual(checksum.returncode, 0, checksum.stderr)
        build = next(call for call in self.calls() if call[0] == 'xcodebuild')
        for setting in ('ARCHS=arm64 x86_64', 'ONLY_ACTIVE_ARCH=NO', 'ENABLE_HARDENED_RUNTIME=YES',
                        'CODE_SIGN_STYLE=Manual', 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO',
                        'OTHER_CODE_SIGN_FLAGS=--timestamp', '-onlyUsePackageVersionsFromResolvedFile'):
            self.assertIn(setting, build)
        self.assertNotIn('fake p12 password', result.stdout + result.stderr)
        self.assertNotIn('fake notary password', result.stdout + result.stderr)
        self.assert_cleaned_up()

    def test_invalid_metadata_stops_before_accessing_keychain(self):
        for key, value in [('RELEASE_TAG', 'v1.2'), ('RELEASE_TAG', 'v01.2.3'),
                           ('RELEASE_TAG', 'v1.2.3; echo bad'), ('RELEASE_BUILD_NUMBER', '0'),
                           ('RELEASE_OUTPUT_DIR', 'relative'), ('APPLE_TEAM_ID', 'invalid')]:
            with self.subTest(key=key, value=value):
                original = self.environment[key]
                self.environment[key] = value
                self.assertNotEqual(self.run_script().returncode, 0)
                self.assertEqual(self.calls(), [])
                self.environment[key] = original

    def test_universal_verification_with_system_lipo_and_rejection_of_missing_slice(self):
        lipo = self.root / 'bin/lipo'
        lipo.unlink()
        lipo.symlink_to('/usr/bin/lipo')
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        shutil.rmtree(self.output)
        self.log.unlink()
        self.environment['THIN_ARCHIVE'] = '1'
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertFalse(any(call[0] == 'xcrun' for call in self.calls()))
        self.assertFalse(self.asset().exists())
        self.assert_cleaned_up()

    def test_each_missing_secret_fails_before_building(self):
        for name in ('APPLE_CERTIFICATE_P12_BASE64', 'APPLE_CERTIFICATE_PASSWORD', 'APPLE_TEAM_ID',
                     'APPLE_ID', 'APPLE_APP_SPECIFIC_PASSWORD'):
            with self.subTest(name=name):
                value = self.environment.pop(name)
                result = self.run_script()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
                self.assertEqual(self.calls(), [])
                self.environment[name] = value

    def test_nonempty_output_is_rejected(self):
        self.output.mkdir()
        previous = self.output / 'previous.zip'
        previous.write_bytes(b'previous')
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual(previous.read_bytes(), b'previous')
        self.assertEqual(self.calls(), [])

    def test_invalid_certificate_encoding_never_imports_a_key(self):
        self.environment['APPLE_CERTIFICATE_P12_BASE64'] = 'not base64!'
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertFalse(any(call[:2] == ['security', 'import'] for call in self.calls()))
        self.assert_cleaned_up()

    def test_archive_version_mismatch_prevents_notarization(self):
        self.environment['ARCHIVE_VERSION'] = '9.9.9'
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('version', result.stderr)
        self.assertFalse(any(call[0] == 'xcrun' for call in self.calls()))
        self.assert_cleaned_up()

    def test_wrong_certificate_kind_or_team_never_builds(self):
        for key, value in [('IDENTITY_KIND', 'Apple Development'), ('IDENTITY_TEAM', 'WRONG12345')]:
            with self.subTest(key=key):
                self.environment[key] = value
                result = self.run_script()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[0] == 'xcodebuild' for call in self.calls()))
                self.assert_cleaned_up()
                self.environment.pop(key)
                self.log.unlink()

    def test_failure_at_each_stage_prevents_release_zip_and_cleans_up(self):
        for stage in ('security:import', 'xcodebuild', 'lipo', 'codesign:--verify',
                      'xcrun:notarytool:store-credentials', 'xcrun:notarytool:submit',
                      'xcrun:stapler:staple', 'xcrun:stapler:validate', 'spctl'):
            with self.subTest(stage=stage):
                self.environment['FAIL_STAGE'] = stage
                result = self.run_script()
                self.assertEqual(result.returncode, 23, result.stderr)
                self.assertFalse(self.asset().exists())
                self.assert_cleaned_up()
                shutil.rmtree(self.output)
                self.log.unlink()

    def test_invalid_or_pending_notarization_keeps_diagnostics_and_does_not_staple(self):
        for status in ('Invalid', 'In Progress'):
            with self.subTest(status=status):
                self.environment['NOTARY_STATUS'] = status
                self.assertNotEqual(self.run_script().returncode, 0)
                self.assertTrue((self.output / 'notarization-log.json').exists())
                self.assertFalse(any(call[:2] == ['xcrun', 'stapler'] for call in self.calls()))
                self.assertFalse(self.asset().exists())
                self.assert_cleaned_up()
                shutil.rmtree(self.output)
                self.log.unlink()

    def test_missing_signature_protections_prevents_notarization(self):
        for field in ('Authority=', 'TeamIdentifier=', 'runtime', 'Timestamp='):
            with self.subTest(field=field):
                self.environment['OMIT_SIGNATURE'] = field
                self.assertNotEqual(self.run_script().returncode, 0)
                self.assertFalse(any(call[0] == 'xcrun' for call in self.calls()))
                self.assert_cleaned_up()
                shutil.rmtree(self.output)
                self.log.unlink()

    def prepare_upload(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.log.unlink()

    def test_new_release_is_draft_and_requires_existing_tag(self):
        self.prepare_upload()
        result = self.run_script('publish-release.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(call for call in self.calls() if call[:3] == ['gh', 'release', 'create'])
        self.assertIn('--draft', create)
        self.assertIn('--verify-tag', create)
        self.assertNotIn('--prerelease', create)
        self.assertIn(self.asset().name, create)

    def test_prerelease_uses_numeric_app_version_and_github_prerelease_flag(self):
        self.environment['RELEASE_TAG'] = 'v1.2.3-beta.1'
        self.prepare_upload()
        with zipfile.ZipFile(self.asset()) as archive:
            info = plistlib.loads(archive.read('MKTownEditor-1.2.3-beta.1/MKTownEditor.app/Contents/Info.plist'))
            self.assertEqual(info['CFBundleShortVersionString'], '1.2.3')
        self.assertEqual(self.run_script('publish-release.sh').returncode, 0)
        create = next(call for call in self.calls() if call[:3] == ['gh', 'release', 'create'])
        self.assertIn('--prerelease', create)

    def test_rerun_updates_only_a_draft_without_replacing_release_notes(self):
        self.prepare_upload()
        self.environment['EXISTING_RELEASE'] = 'draft'
        self.assertEqual(self.run_script('publish-release.sh').returncode, 0)
        self.assertEqual([call[:3] for call in self.calls()],
                         [['gh', 'release', 'view'], ['gh', 'release', 'upload']])

    def test_published_release_is_not_modified(self):
        self.prepare_upload()
        self.environment['EXISTING_RELEASE'] = 'published'
        result = self.run_script('publish-release.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('published release', result.stderr)
        self.assertEqual([call[:3] for call in self.calls()], [['gh', 'release', 'view']])

    def test_missing_or_corrupt_asset_never_contacts_github(self):
        self.prepare_upload()
        self.asset().write_bytes(b'corrupt')
        self.assertNotEqual(self.run_script('publish-release.sh').returncode, 0)
        self.assertEqual(self.calls(), [])
        self.asset().unlink()
        self.assertNotEqual(self.run_script('publish-release.sh').returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_upload_failure_fails_the_workflow(self):
        self.prepare_upload()
        self.environment['FAIL_STAGE'] = 'gh:release:create'
        self.assertEqual(self.run_script('publish-release.sh').returncode, 23)


if __name__ == '__main__':
    unittest.main()
